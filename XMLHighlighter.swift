import AppKit

/// XML highlighting shared by the plist and XML previewers.
///
/// Highlights rather than parses, so a malformed or truncated document still
/// shows. The one piece of structure it tracks is the stack of open elements,
/// which a flavor can use to colour text by the element it sits in.
struct XMLHighlighter {

    /// Colour for character data inside `element` (nil at the top level).
    var textColor: (String?) -> NSColor = { _ in PreviewStyle.plain }
    /// Colour and font for an element name.
    var nameStyle: (String) -> (NSColor, NSFont) = { _ in (PreviewStyle.tag, PreviewStyle.mono) }
    var attributeColor = PreviewStyle.key

    /// Decoded, line-split text ready to highlight.
    struct Source {
        var lines: [String]
        var truncated: Bool
        var note: String?
    }

    /// The first `maxBytes`, decoded by BOM, then UTF-8, then Windows-1252 so
    /// a Latin-1 document shows its accents instead of replacement marks.
    static func decode(_ prefix: Data, truncated: Bool, maxLines: Int) -> Source {
        var note: String?
        var text: String
        if prefix.starts(with: [0xFF, 0xFE]) || prefix.starts(with: [0xFE, 0xFF]) {
            text = String(data: prefix.prefix(prefix.count & ~1), encoding: .utf16) ?? ""
            note = "UTF-16"
        } else if let utf8 = (0...min(3, prefix.count)).lazy
                    .compactMap({ String(data: prefix.dropLast($0), encoding: .utf8) }).first {
            text = utf8
        } else {
            text = String(data: prefix, encoding: .windowsCP1252) ?? String(decoding: prefix, as: UTF8.self)
            note = "not UTF-8, read as Latin-1"
        }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if truncated, let cut = text.lastIndex(of: "\n") { text = String(text[..<cut]) }
        return split(text, truncated: truncated, maxLines: maxLines, note: note)
    }

    static func split(_ text: String, truncated: Bool, maxLines: Int, note: String?) -> Source {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n")
        var note = note
        if longestLine(text) > 5000 {
            text = reflow(text, maxLines: maxLines)
            note = [note, "minified, line breaks added"].compactMap { $0 }.joined(separator: ", ")
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var cut = truncated
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            cut = true
        }
        return Source(lines: lines, truncated: cut, note: note)
    }

    private static func longestLine(_ text: String) -> Int {
        var longest = 0, current = 0
        for s in text.unicodeScalars {
            if s == "\n" { longest = max(longest, current); current = 0 } else { current += 1 }
        }
        return max(longest, current)
    }

    /// Breaks a minified document between adjacent tags, indented by depth.
    /// Text between an opening and closing tag stays on one line, and
    /// comments, CDATA and quoted attribute values are copied untouched.
    /// Stops one line past `maxLines`, so the caller marks it truncated.
    static func reflow(_ text: String, maxLines: Int) -> String {
        let c = Array(text.unicodeScalars)
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(c.count + c.count / 8)
        var lines = 1
        var depth = 0
        var i = 0
        var lastSignificant: Unicode.Scalar = "\n"

        func copy(until terminator: [Unicode.Scalar]) {
            while i < c.count {
                if c[i] == terminator[0], i + terminator.count <= c.count,
                   c[i..<i + terminator.count].elementsEqual(terminator) {
                    out.append(contentsOf: terminator)
                    i += terminator.count
                    return
                }
                out.append(c[i])
                i += 1
            }
        }
        func newline() {
            lines += 1
            out.append("\n")
            out.append(contentsOf: String(repeating: "  ", count: min(depth, 40)).unicodeScalars)
        }

        let space: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r"]
        while i < c.count, lines <= maxLines {
            let ch = c[i]
            guard ch == "<" else {
                if space.contains(ch), lastSignificant == ">" {
                    var j = i
                    while j < c.count, space.contains(c[j]) { j += 1 }
                    if j == c.count || c[j] == "<" {               // whitespace between tags
                        i = j
                        continue
                    }
                }
                out.append(ch)
                lastSignificant = ch
                i += 1
                continue
            }
            let next = i + 1 < c.count ? c[i + 1] : " "
            if next == "/" { depth = max(depth - 1, 0) }
            if lastSignificant == ">" { newline() }

            if c[i...].starts(with: "<!--".unicodeScalars) {
                copy(until: Array("-->".unicodeScalars))
            } else if c[i...].starts(with: "<![CDATA[".unicodeScalars) {
                copy(until: Array("]]>".unicodeScalars))
            } else {
                var quote: Unicode.Scalar?
                var selfClosing = false
                while i < c.count {
                    let t = c[i]
                    out.append(t)
                    i += 1
                    if let q = quote { if t == q { quote = nil }; continue }
                    if t == "\"" || t == "'" { quote = t; continue }
                    if t == ">" { selfClosing = c[max(i - 2, 0)] == "/"; break }
                }
                if next != "/", next != "?", next != "!", !selfClosing { depth += 1 }
            }
            lastSignificant = ">"
        }
        return String(String.UnicodeScalarView(out))
    }

    /// Header, gutter and highlighted body.
    func document(_ url: URL, _ source: Source, totalBytes: Int?, extraNote: String? = nil) -> NSAttributedString {
        var out = Emitter(lineCount: source.lines.count)
        if source.lines.isEmpty {
            out.body.setAttributedString(NSAttributedString())
        } else {
            highlight(Array(source.lines.joined(separator: "\n").unicodeScalars), into: &out)
            out.body.t("\n", PreviewStyle.punct)
        }

        let count = source.lines.count
        var facts = ["\(count) line\(count == 1 ? "" : "s")"]
        if let totalBytes { facts.append(formatBytes(totalBytes)) }
        if let note = source.note { facts.append(note) }
        if let extraNote { facts.append(extraNote) }
        if source.truncated { facts.append("truncated") }
        let header = reportHeader(url, size: nil, facts)
        header.append(out.body)
        if source.truncated { header.t("\n\u{2026} remainder not shown\n", PreviewStyle.dim) }
        return header
    }

    /// Appends text with a line-number gutter, so the tokenizer can run over
    /// the whole document without caring where lines break.
    private struct Emitter {
        let body = NSMutableAttributedString()
        private let width: Int
        private var line = 1

        init(lineCount: Int) {
            width = String(max(lineCount, 1)).count
            body.t(String(format: "%\(width)d  ", line), PreviewStyle.dim)
        }

        mutating func emit(_ s: ArraySlice<Unicode.Scalar>, _ color: NSColor, _ font: NSFont = PreviewStyle.mono) {
            var first = true
            for piece in s.split(separator: "\n", omittingEmptySubsequences: false) {
                if !first {
                    line += 1
                    body.t("\n", PreviewStyle.punct)
                    body.t(String(format: "%\(width)d  ", line), PreviewStyle.dim)
                }
                first = false
                if !piece.isEmpty { body.t(String(String.UnicodeScalarView(piece)), color, font) }
            }
        }
    }

    private func highlight(_ c: [Unicode.Scalar], into out: inout Emitter) {
        var open: [String] = []
        var i = 0

        func starts(_ s: String, at k: Int) -> Bool {
            c[k...].starts(with: s.unicodeScalars)
        }
        /// Index just past `terminator`, or the end of input if it never comes.
        func past(_ terminator: String, from k: Int) -> Int {
            var j = k
            while j < c.count, !starts(terminator, at: j) { j += 1 }
            return min(j + terminator.unicodeScalars.count, c.count)
        }

        while i < c.count {
            if starts("<!--", at: i) {
                let end = past("-->", from: i + 4)
                out.emit(c[i..<end], PreviewStyle.comment)
                i = end
            } else if starts("<![CDATA[", at: i) {
                out.emit(c[i..<i + 9], PreviewStyle.punct)
                var j = i + 9
                while j < c.count, !starts("]]>", at: j) { j += 1 }
                out.emit(c[(i + 9)..<j], textColor(open.last))
                out.emit(c[j..<min(j + 3, c.count)], PreviewStyle.punct)
                i = min(j + 3, c.count)
            } else if starts("<!", at: i) {
                let end = past(">", from: i + 2)
                out.emit(c[i..<end], PreviewStyle.dim)
                i = end
            } else if c[i] == "<" {
                i = tag(c, from: i, open: &open, into: &out)
            } else if c[i] == "&" {
                var j = i + 1
                while j < c.count, j - i < 12, c[j] != ";", c[j] != "<", c[j] != "&",
                      !c[j].properties.isWhitespace { j += 1 }
                let end = j < c.count && c[j] == ";" ? j + 1 : i + 1
                out.emit(c[i..<end], end > i + 1 ? PreviewStyle.tag : textColor(open.last))
                i = end
            } else {
                var j = i
                while j < c.count, c[j] != "<", c[j] != "&" { j += 1 }
                out.emit(c[i..<j], textColor(open.last))
                i = j
            }
        }
    }

    /// Colours one `<name attr="v">`, `</name>`, `<name/>` or `<?xml … ?>`,
    /// updates the open-element stack, and returns the index just past it.
    private func tag(_ c: [Unicode.Scalar], from start: Int, open: inout [String],
                     into out: inout Emitter) -> Int {
        var i = start + 1
        let closing = i < c.count && c[i] == "/"
        let instruction = i < c.count && c[i] == "?"
        if closing || instruction { i += 1 }
        out.emit(c[start..<i], PreviewStyle.punct)

        let isNameChar = { (s: Unicode.Scalar) in
            s.properties.isAlphabetic || s.properties.numericType != nil || "-_.:".unicodeScalars.contains(s)
        }
        let nameStart = i
        while i < c.count, isNameChar(c[i]) { i += 1 }
        let name = String(String.UnicodeScalarView(c[nameStart..<i]))
        let (color, font) = instruction ? (PreviewStyle.tag, PreviewStyle.mono) : nameStyle(name)
        out.emit(c[nameStart..<i], color, font)

        var selfClosing = false
        while i < c.count, c[i] != ">" {
            if c[i] == "\"" || c[i] == "'" {
                var j = i + 1
                while j < c.count, c[j] != c[i] { j += 1 }
                j = min(j + 1, c.count)
                out.emit(c[i..<j], PreviewStyle.string)
                i = j
            } else if c[i] == "<" {
                // An unclosed tag; let the caller start over on the next one.
                break
            } else if isNameChar(c[i]) {
                var j = i
                while j < c.count, isNameChar(c[j]) { j += 1 }
                out.emit(c[i..<j], attributeColor)
                i = j
            } else {
                selfClosing = c[i] == "/" || (instruction && c[i] == "?")
                out.emit(c[i..<i + 1], PreviewStyle.punct)
                i += 1
            }
        }
        if i < c.count, c[i] == ">" {
            out.emit(c[i..<i + 1], PreviewStyle.punct)
            i += 1
        }

        if name.isEmpty || instruction || selfClosing { return i }
        if closing {
            if let match = open.lastIndex(of: name) { open.removeSubrange(match...) }
        } else {
            open.append(name)
        }
        return i
    }
}
