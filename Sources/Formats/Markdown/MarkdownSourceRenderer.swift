import AppKit

/// The Markdown source, coloured, with line numbers: the Source side of the
/// Markdown previewer's switch. Same palette and layout as the other
/// previewers in this project.
///
/// Line by line, like the YAML previewer: block syntax is recognised at the
/// start of a line, inline syntax only within the line, so an unclosed `*`
/// or backtick can never colour the rest of the file. Only fences, front
/// matter and HTML comments span lines. Code inside a fence with a known
/// language tag gets that language's colours.
enum MarkdownSourceRenderer {

    static func render(url: URL, maxBytes: Int = 2 << 20, maxLines: Int = 5000) throws -> NSAttributedString {
        let size = fileSize(url) ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        let text = (String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")

        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let truncated = size > data.count || lines.count > maxLines
        lines = Array(lines.prefix(maxLines))

        var writer = LineWriter()
        let body = NSMutableAttributedString()
        let gutter = String(max(lines.count, 1)).count
        for (n, line) in lines.enumerated() {
            body.t(String(format: "%\(gutter)d  ", n + 1), PreviewStyle.dim)
            writer.write(Array(line), isFirst: n == 0, into: body)
            body.t("\n", PreviewStyle.punct)
        }

        var facts = ["\(lines.count.formatted()) line\(lines.count == 1 ? "" : "s")"]
        if truncated { facts.append("truncated") }
        let out = reportHeader(url, size: size, facts)
        out.append(body)
        if truncated { out.t("\u{2026} remainder not shown\n", PreviewStyle.dim) }
        return out
    }
}

/// Colours one line at a time and carries the few states that span lines.
private struct LineWriter {

    private var inFrontMatter = false
    private var fence: (marker: Character, length: Int, syntax: PlainTextRenderer.Syntax?)?
    private var inBlockComment = false            // a /* */ inside a fence
    private var inHTMLComment = false

    private static let mono = PreviewStyle.mono
    private static let bold = PreviewStyle.monoBold
    private static let italic = withTraits(PreviewStyle.mono, .italic)
    private static let boldItalic = withTraits(PreviewStyle.monoBold, .italic)

    private static func withTraits(_ font: NSFont, _ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: d, size: font.pointSize) ?? font
    }

    mutating func write(_ c: [Character], isFirst: Bool, into out: NSMutableAttributedString) {
        let line = String(c)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // --- front matter, only as the very first line ---
        if isFirst, line == "---" { inFrontMatter = true; out.t(line, PreviewStyle.punct); return }
        if inFrontMatter {
            if line == "---" || line == "..." { inFrontMatter = false; out.t(line, PreviewStyle.punct) }
            else { yaml(c, into: out) }
            return
        }

        // --- fenced code ---
        if let open = fence {
            let run = trimmed.prefix { $0 == open.marker }.count
            if run >= open.length, trimmed.dropFirst(run).allSatisfy(\.isWhitespace) {
                fence = nil
                out.t(line, PreviewStyle.punct)
            } else if let syntax = open.syntax {
                inBlockComment = PlainTextRenderer.scanLine(c, syntax, inBlock: inBlockComment, into: out)
            } else {
                out.t(line, PreviewStyle.string)
            }
            return
        }
        if let marker = trimmed.first, marker == "`" || marker == "~" {
            let run = trimmed.prefix { $0 == marker }.count
            if run >= 3 {
                let tag = trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces)
                let language = tag.split(separator: " ").first.map(String.init)
                fence = (marker, run, MarkdownCode.syntax(for: language))
                inBlockComment = false
                out.t(String(line.prefix(line.count - tag.count)), PreviewStyle.punct)
                out.t(tag, PreviewStyle.tag)
                return
            }
        }

        // --- block syntax at the start of the line ---
        var i = c.prefix { $0 == " " || $0 == "\t" }.count
        out.t(String(c[0..<i]), PreviewStyle.punct)

        if !inHTMLComment, i < c.count, c[i] == "#" {             // # Heading
            let hashes = c[i...].prefix { $0 == "#" }.count
            if hashes <= 6, i + hashes == c.count || c[i + hashes] == " " {
                out.t(String(c[i..<i + hashes]), PreviewStyle.punct)
                out.t(String(c[(i + hashes)...]), PreviewStyle.key, Self.bold)
                return
            }
        }
        if Self.isRule(trimmed) { out.t(String(c[i...]), PreviewStyle.punct); return }

        while i < c.count, c[i] == ">" {                         // > quote, > > nested
            var j = i + 1
            if j < c.count, c[j] == " " { j += 1 }
            out.t(String(c[i..<j]), PreviewStyle.literal)
            i = j
        }
        if let end = Self.listMarker(c, at: i) {                 // - item, 1. item, - [ ] task
            out.t(String(c[i..<end]), PreviewStyle.literal)
            i = end
        }
        inline(c, from: i, table: trimmed.hasPrefix("|"), into: out)
    }

    // MARK: inline

    private mutating func inline(_ c: [Character], from start: Int, table: Bool,
                                 into out: NSMutableAttributedString) {
        var i = start
        var plain = ""
        func flush() { if !plain.isEmpty { out.t(plain, PreviewStyle.plain); plain = "" } }

        while i < c.count {
            if inHTMLComment {
                let close = Self.find("-->", in: c, from: i)
                let end = close.map { $0 + 3 } ?? c.count
                out.t(String(c[i..<end]), PreviewStyle.comment)
                if close != nil { inHTMLComment = false }
                i = end
                continue
            }
            let ch = c[i]
            if ch == "\\", i + 1 < c.count {                       // \* stays a star
                plain += String(c[i...i + 1]); i += 2; continue
            }
            if Self.matches("<!--", c, at: i) { flush(); inHTMLComment = true; continue }
            if ch == "`" {                                          // `code`, ``co`de``
                let run = c[i...].prefix { $0 == "`" }.count
                if let close = Self.find(String(repeating: "`", count: run), in: c, from: i + run) {
                    flush()
                    out.t(String(c[i..<close + run]), PreviewStyle.string)
                    i = close + run
                    continue
                }
            }
            if ch == "[" || (ch == "!" && i + 1 < c.count && c[i + 1] == "["),
               let link = Self.link(c, at: i) {                     // [text](url), ![alt](src)
                flush()
                out.t(String(c[i..<link.textStart]), PreviewStyle.punct)
                out.t(String(c[link.textStart..<link.textEnd]), PreviewStyle.tag)
                out.t("](", PreviewStyle.punct)
                out.t(String(c[(link.textEnd + 2)..<link.end - 1]), PreviewStyle.dim)
                out.t(")", PreviewStyle.punct)
                i = link.end
                continue
            }
            if ch == "<", let close = c[i...].firstIndex(of: ">"),
               i + 1 < c.count, c[i + 1].isLetter || c[i + 1] == "/" {  // <tag>, <https://…>
                flush()
                out.t(String(c[i...close]), PreviewStyle.dim)
                i = close + 1
                continue
            }
            if let span = Self.emphasis(c, at: i) {                 // **bold**, *it*, ~~gone~~
                flush()
                out.t(String(c[i..<i + span.marker]), PreviewStyle.punct)
                let inner = String(c[(i + span.marker)..<span.close])
                switch c[i] {
                case "~":
                    out.append(NSAttributedString(string: inner, attributes: [
                        .font: Self.mono, .foregroundColor: PreviewStyle.plain,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue]))
                default:
                    out.t(inner, PreviewStyle.plain, [Self.italic, Self.bold, Self.boldItalic][span.marker - 1])
                }
                out.t(String(c[span.close..<span.close + span.marker]), PreviewStyle.punct)
                i = span.close + span.marker
                continue
            }
            if table, ch == "|" { flush(); out.t("|", PreviewStyle.punct); i += 1; continue }
            plain.append(ch)
            i += 1
        }
        flush()
    }

    // MARK: recognisers

    /// `---`, `***`, `___` (spaces allowed), and setext `===` underlines.
    private static func isRule(_ s: String) -> Bool {
        let chars = s.filter { $0 != " " }
        guard let first = chars.first, "-*_=".contains(first), chars.count >= 3 else { return false }
        return chars.allSatisfy { $0 == first }
    }

    /// End of `- `, `* `, `+ `, `12. `, `3) `, plus a following `[ ] ` or `[x] `.
    private static func listMarker(_ c: [Character], at i: Int) -> Int? {
        guard i < c.count else { return nil }
        var j = i
        if "-*+".contains(c[j]) { j += 1 }
        else {
            while j < c.count, c[j].isNumber, j - i < 9 { j += 1 }
            guard j > i, j < c.count, c[j] == "." || c[j] == ")" else { return nil }
            j += 1
        }
        guard j < c.count, c[j] == " " else { return nil }
        j += 1
        if j + 3 < c.count, c[j] == "[", " xX".contains(c[j + 1]), c[j + 2] == "]", c[j + 3] == " " { j += 4 }
        return j
    }

    private static func link(_ c: [Character], at i: Int) -> (textStart: Int, textEnd: Int, end: Int)? {
        let textStart = c[i] == "!" ? i + 2 : i + 1
        guard let textEnd = find("](", in: c, from: textStart),
              let close = c[(textEnd + 2)...].firstIndex(of: ")") else { return nil }
        return (textStart, textEnd, close + 1)
    }

    /// `***x***`, `**x**`, `*x*` (or with `_`) and `~~x~~`, closed on the same line.
    /// An underscore inside a word (`snake_case`) is not emphasis.
    private static func emphasis(_ c: [Character], at i: Int) -> (marker: Int, close: Int)? {
        let ch = c[i]
        guard "*_~".contains(ch) else { return nil }
        if ch == "_", i > 0, c[i - 1].isLetter || c[i - 1].isNumber { return nil }
        let run = min(c[i...].prefix { $0 == ch }.count, ch == "~" ? 2 : 3)
        if ch == "~", run < 2 { return nil }
        let open = i + run
        guard open < c.count, c[open] != " ",
              let close = find(String(repeating: ch, count: run), in: c, from: open + 1),
              c[close - 1] != " " else { return nil }
        return (run, close)
    }

    /// `key: value` and `# comments` of YAML front matter.
    private func yaml(_ c: [Character], into out: NSMutableAttributedString) {
        let line = String(c)
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") { out.t(line, PreviewStyle.comment); return }
        guard let colon = c.firstIndex(of: ":") else { out.t(line, PreviewStyle.string); return }
        out.t(String(c[..<colon]), PreviewStyle.key)
        out.t(":", PreviewStyle.punct)
        let value = String(c[(colon + 1)...])
        let bare = value.trimmingCharacters(in: .whitespaces)
        let color: NSColor = ["true", "false", "null", "~", "yes", "no"].contains(bare.lowercased())
            ? PreviewStyle.literal
            : Double(bare) != nil ? PreviewStyle.number : PreviewStyle.string
        out.t(value, color)
    }

    private static func matches(_ token: String, _ c: [Character], at i: Int) -> Bool {
        let t = Array(token)
        return i + t.count <= c.count && Array(c[i..<i + t.count]) == t
    }

    private static func find(_ token: String, in c: [Character], from start: Int) -> Int? {
        var i = start
        while i < c.count {
            if matches(token, c, at: i) { return i }
            i += 1
        }
        return nil
    }
}
