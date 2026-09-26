import AppKit

/// SAP Commerce (Hybris) ImpEx: semicolon-separated rows under header lines
/// like `INSERT_UPDATE Product;code[unique=true];name[lang=en]`.
///
/// A header and the data rows under it form a block. When a block is small
/// and its cells are short, its columns are padded to line up. A block with
/// long cells, multi-line quoted values or `\` continuations is only
/// highlighted, since padding it would make it wider without making it more
/// readable. The preview scrolls sideways instead of wrapping.
enum ImpexRenderer {

    private enum Kind { case blank, comment, directive, macro, header, data, continuation }

    private static let modes: Set<String> = ["INSERT", "UPDATE", "INSERT_UPDATE", "REMOVE"]

    static func render(url: URL, maxBytes: Int = 4 << 20, maxLines: Int = 5000,
                       maxAlignedRows: Int = 1000, maxCellWidth: Int = 48) throws -> NSAttributedString {
        let totalBytes = fileSize(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: maxBytes) ?? Data()
        if prefix.prefix(8192).contains(0) { throw XMLRenderer.NotText() }

        let source = XMLHighlighter.decode(prefix, truncated: (totalBytes ?? 0) > prefix.count, maxLines: maxLines)
        let lines = source.lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let (kinds, quoted) = classify(lines)
        let widths = alignment(lines, kinds, maxRows: maxAlignedRows, maxCell: maxCellWidth)

        let body = NSMutableAttributedString()
        let gutter = String(max(lines.count, 1)).count
        for (n, line) in lines.enumerated() {
            body.t(String(format: "%\(gutter)d  ", n + 1), PreviewStyle.dim)
            switch kinds[n] {
            case .blank: break
            case .comment: body.t(line, PreviewStyle.comment)
            case .directive: writeDirective(line, into: body)
            case .macro: writeMacro(line, into: body)
            case .continuation: writeContinuation(line, insideQuote: quoted[n], into: body)
            case .header, .data: writeRow(line, header: kinds[n] == .header, widths: widths[n], into: body)
            }
            body.t("\n", PreviewStyle.punct)
        }

        let headers = kinds.filter { $0 == .header }.count
        var facts = ["\(lines.count) line\(lines.count == 1 ? "" : "s")"]
        if let totalBytes { facts.append(formatBytes(totalBytes)) }
        facts.append("\(headers) header\(headers == 1 ? "" : "s")")
        if let note = source.note { facts.append(note) }
        if source.truncated { facts.append("truncated") }
        let out = reportHeader(url, size: nil, facts)
        out.append(body)
        if source.truncated { out.t("\n\u{2026} remainder not shown\n", PreviewStyle.dim) }
        return out
    }

    // MARK: - structure

    /// Each line's kind, and whether it starts inside a quoted value.
    private static func classify(_ lines: [String]) -> ([Kind], [Bool]) {
        var kinds: [Kind] = []
        var quoted: [Bool] = []
        var inQuote = false
        var continuing = false
        for line in lines {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            let kind: Kind
            if inQuote || continuing { kind = .continuation }
            else if trimmed.isEmpty { kind = .blank }
            else if trimmed.hasPrefix("#%") || trimmed.hasPrefix("\"#%") { kind = .directive }
            else if trimmed.hasPrefix("#") { kind = .comment }
            else if trimmed.hasPrefix("$"), trimmed.contains("=") { kind = .macro }
            else if let word = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ";" }).first,
                    modes.contains(word.uppercased()) { kind = .header }
            else { kind = .data }
            kinds.append(kind)
            quoted.append(inQuote)

            if kind == .comment || kind == .blank { continue }
            inQuote = endsInsideQuote(line, startingInside: inQuote)
            continuing = !inQuote && line.hasSuffix("\\")
        }
        return (kinds, quoted)
    }

    private static func endsInsideQuote(_ line: String, startingInside: Bool) -> Bool {
        var inside = startingInside
        for ch in line where ch == "\"" { inside.toggle() }            // `""` toggles twice
        return inside
    }

    /// Cells split on `;` outside double quotes; quotes are kept.
    private static func cells(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inside = false
        for ch in line {
            if ch == "\"" { inside.toggle() }
            if ch == ";", !inside {
                out.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        out.append(current)
        return out
    }

    /// Column widths per line, for lines in blocks that qualify; nil elsewhere.
    private static func alignment(_ lines: [String], _ kinds: [Kind], maxRows: Int, maxCell: Int) -> [[Int]?] {
        var result = [[Int]?](repeating: nil, count: lines.count)
        var i = 0
        while i < lines.count {
            guard kinds[i] == .header else { i += 1; continue }
            var j = i + 1
            while j < lines.count, [.data, .continuation, .comment, .directive].contains(kinds[j]) { j += 1 }
            let rows = (i..<j).filter { kinds[$0] == .header || kinds[$0] == .data }
            let split = rows.map { cells(lines[$0]) }
            let eligible = rows.count <= maxRows
                && !(i..<j).contains { kinds[$0] == .continuation }
                && split.allSatisfy { $0.allSatisfy { $0.count <= maxCell } }
            if eligible {
                var widths: [Int] = []
                for row in split {
                    for (c, cell) in row.enumerated() {
                        if c == widths.count { widths.append(0) }
                        widths[c] = max(widths[c], cell.count)
                    }
                }
                for n in rows { result[n] = widths }
            }
            i = j
        }
        return result
    }

    // MARK: - output

    private static func writeRow(_ line: String, header: Bool, widths: [Int]?, into out: NSMutableAttributedString) {
        let row = cells(line)
        for (c, cell) in row.enumerated() {
            if header {
                writeHeaderCell(cell, first: c == 0, into: out)
            } else {
                writeDataCell(cell, into: out)
            }
            if c < row.count - 1 {
                if let widths, c < widths.count, widths[c] > cell.count {
                    out.t(String(repeating: " ", count: widths[c] - cell.count), PreviewStyle.punct)
                }
                out.t(";", PreviewStyle.punct, PreviewStyle.monoBold)
            }
        }
    }

    /// `INSERT_UPDATE Product[processor=…]` or `catalogVersion(catalog(id),version)[unique=true]`.
    private static func writeHeaderCell(_ cell: String, first: Bool, into out: NSMutableAttributedString) {
        var c = Array(cell)
        if first {
            let lead = c.prefix { $0 == " " || $0 == "\t" }.count
            var end = lead
            while end < c.count, c[end] != " ", c[end] != "\t" { end += 1 }
            out.t(String(c[..<lead]), PreviewStyle.punct)
            out.t(String(c[lead..<end]), PreviewStyle.literal, PreviewStyle.monoBold)
            c = Array(c[end...])
            let gap = c.prefix { $0 == " " || $0 == "\t" }.count
            out.t(String(c[..<gap]), PreviewStyle.punct)
            c = Array(c[gap...])
        }
        var i = 0
        var depth = 0
        var isTypeName = first
        while i < c.count {
            let ch = c[i]
            if ch == "[" || ch == "]" {
                depth += ch == "[" ? 1 : -1
                out.t(String(ch), PreviewStyle.punct)
                i += 1
                isTypeName = false
            } else if ch == "$" {
                var j = i + 1
                while j < c.count, c[j].isLetter || c[j].isNumber || "_-.".contains(c[j]) { j += 1 }
                out.t(String(c[i..<j]), PreviewStyle.tag)
                i = j
            } else if "(),=:".contains(ch) {
                out.t(String(ch), PreviewStyle.punct)
                i += 1
            } else {
                var j = i
                while j < c.count, !"[]()$,=:".contains(c[j]) { j += 1 }
                let word = String(c[i..<j])
                if depth > 0 {
                    out.t(word, PreviewStyle.literal)
                } else if isTypeName {
                    out.t(word, PreviewStyle.tag, PreviewStyle.monoBold)
                } else {
                    out.t(word, PreviewStyle.key)
                }
                i = j
            }
        }
    }

    private static func writeDataCell(_ cell: String, into out: NSMutableAttributedString) {
        let value = cell.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\"") {
            out.t(cell, PreviewStyle.string)
        } else if value.hasPrefix("$") {
            out.t(cell, PreviewStyle.tag)
        } else if ["true", "false"].contains(value.lowercased()) {
            out.t(cell, PreviewStyle.literal)
        } else if !value.isEmpty, Double(value) != nil {
            out.t(cell, PreviewStyle.number)
        } else {
            out.t(cell, PreviewStyle.plain)
        }
    }

    /// The rest of a quoted value is string up to its closing quote.
    private static func writeContinuation(_ line: String, insideQuote: Bool, into out: NSMutableAttributedString) {
        guard insideQuote else { return writeText(line, into: out) }
        var inside = true
        var close = line.endIndex
        for i in line.indices where line[i] == "\"" {
            inside.toggle()
            let next = line.index(after: i)
            if !inside, next == line.endIndex || line[next] != "\"" {
                close = next
                break
            }
        }
        out.t(String(line[..<close]), PreviewStyle.string)
        if close < line.endIndex { writeRow(String(line[close...]), header: false, widths: nil, into: out) }
    }

    private static func writeMacro(_ line: String, into out: NSMutableAttributedString) {
        guard let eq = line.firstIndex(of: "=") else { return writeText(line, into: out) }
        out.t(String(line[..<eq]), PreviewStyle.key, PreviewStyle.monoBold)
        out.t("=", PreviewStyle.punct)
        writeText(String(line[line.index(after: eq)...]), into: out)
    }

    private static func writeDirective(_ line: String, into out: NSMutableAttributedString) {
        guard let mark = line.range(of: "#%") else { return writeText(line, into: out) }
        out.t(String(line[..<mark.upperBound]), PreviewStyle.literal, PreviewStyle.monoBold)
        out.t(String(line[mark.upperBound...]), PreviewStyle.plain)
    }

    /// Plain text with `$macro` references and quoted strings picked out.
    private static func writeText(_ text: String, into out: NSMutableAttributedString) {
        let c = Array(text)
        var i = 0
        var plain = ""
        func flush() { if !plain.isEmpty { out.t(plain, PreviewStyle.plain); plain = "" } }
        while i < c.count {
            if c[i] == "$" {
                var j = i + 1
                while j < c.count, c[j].isLetter || c[j].isNumber || "_-.".contains(c[j]) { j += 1 }
                if j > i + 1 {
                    flush()
                    out.t(String(c[i..<j]), PreviewStyle.tag)
                    i = j
                    continue
                }
            } else if c[i] == ";" {
                flush()
                out.t(";", PreviewStyle.punct, PreviewStyle.monoBold)
                i += 1
                continue
            }
            plain.append(c[i])
            i += 1
        }
        flush()
    }
}
