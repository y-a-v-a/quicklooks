import AppKit

/// Highlights YAML without parsing it.
///
/// A parser has to either succeed or fail, and Quick Look gets pointed at
/// half-written config files constantly. A line-oriented lexer degrades one
/// line at a time instead, and it keeps the file's own layout — with YAML the
/// indentation, comments and key order are what you came to look at, so
/// re-serializing the way the JSONL previewer does would lose the point.
enum YAMLRenderer {

    /// Reads at most `maxBytes` and renders at most `maxLines` lines.
    static func render(url: URL, maxBytes: Int = 4 << 20, maxLines: Int = 5000) throws -> NSAttributedString {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let totalBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        var truncated = (totalBytes ?? 0) > data.count

        var text = String(decoding: data, as: UTF8.self)
        if truncated, let cut = text.lastIndex(of: "\n") { text = String(text[..<cut]) }

        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }          // trailing newline
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            truncated = true
        }

        let body = NSMutableAttributedString()
        let gutter = String(max(lines.count, 1)).count
        var blockIndent: Int?

        for (offset, line) in lines.enumerated() {
            body.t(String(format: "%\(gutter)d  ", offset + 1), PreviewStyle.dim)

            let c = Array(line)
            let indent = c.prefix { $0 == " " || $0 == "\t" }.count

            // Inside a `|` or `>` scalar everything more-indented is literal
            // text, including things that look like keys or comments.
            if let open = blockIndent {
                if indent == c.count || indent > open {
                    body.t(line, PreviewStyle.string)
                    body.t("\n", PreviewStyle.punct)
                    continue
                }
                blockIndent = nil
            }

            body.t(String(c[0..<indent]), PreviewStyle.punct)
            var i = indent

            if i < c.count, c[i] == "#" {
                body.t(String(c[i...]), PreviewStyle.comment)
                body.t("\n", PreviewStyle.punct)
                continue
            }
            if i < c.count, c[i] == "%" {                    // %YAML, %TAG
                body.t(String(c[i...]), PreviewStyle.tag)
                body.t("\n", PreviewStyle.punct)
                continue
            }
            if c.count - i >= 3, String(c[i..<i + 3]) == "---" || String(c[i..<i + 3]) == "..." {
                body.t(String(c[i..<i + 3]), PreviewStyle.literal)
                i += 3
            }

            // Nested sequences put several dashes on one line: `- - a`.
            while i < c.count, c[i] == "-", i + 1 == c.count || c[i + 1] == " " {
                body.t("-", PreviewStyle.punct)
                i += 1
                while i < c.count, c[i] == " " {
                    body.t(" ", PreviewStyle.punct)
                    i += 1
                }
            }

            if let colon = keyColon(c, from: i) {
                body.t(String(c[i..<colon]), PreviewStyle.key)
                body.t(":", PreviewStyle.punct)
                i = colon + 1
            }

            if scanValue(c, from: i, into: body) { blockIndent = indent }
            body.t("\n", PreviewStyle.punct)
        }

        let header = NSMutableAttributedString()
        header.t(url.lastPathComponent, PreviewStyle.punct)
        header.t("  \u{2022}  \(lines.count) line\(lines.count == 1 ? "" : "s")", PreviewStyle.dim)
        if let totalBytes {
            header.t("  \u{2022}  \(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))", PreviewStyle.dim)
        }
        header.t(truncated ? "  \u{2022}  truncated\n\n" : "\n\n", PreviewStyle.dim)

        header.append(body)
        if truncated {
            header.t("\n\u{2026} remainder not shown\n", PreviewStyle.dim)
        }
        return header
    }

    /// Index of the `:` that separates a key from its value, or nil if this
    /// line does not start with a key. A flow collection is not a key, and
    /// `http://host` is not one either — the colon has to be followed by
    /// whitespace or end of line.
    private static func keyColon(_ c: [Character], from start: Int) -> Int? {
        guard start < c.count, c[start] != "[", c[start] != "{" else { return nil }
        var i = start
        while i < c.count {
            let ch = c[i]
            if ch == "\"" || ch == "'" { i = endOfQuoted(c, from: i); continue }
            if ch == "#", i > start, c[i - 1] == " " || c[i - 1] == "\t" { return nil }
            if ch == ":", isSeparator(c, after: i) { return i }
            i += 1
        }
        return nil
    }

    private static func isSeparator(_ c: [Character], after i: Int) -> Bool {
        guard i + 1 < c.count else { return true }
        return " \t,]}".contains(c[i + 1])
    }

    /// Colors everything after the key. Returns true if the value opens a
    /// block scalar, so the caller can hold the following lines as literal.
    private static func scanValue(_ c: [Character], from start: Int, into out: NSMutableAttributedString) -> Bool {
        var i = start
        var opensBlock = false

        while i < c.count {
            let ch = c[i]

            if ch == " " || ch == "\t" {
                out.t(String(ch), PreviewStyle.punct)
                i += 1
                continue
            }
            if ch == "#", i == 0 || c[i - 1] == " " || c[i - 1] == "\t" {
                out.t(String(c[i...]), PreviewStyle.comment)
                return opensBlock
            }
            if ch == "\"" || ch == "'" {
                let end = endOfQuoted(c, from: i)
                out.t(String(c[i..<end]), PreviewStyle.string)
                i = end
                continue
            }
            if "[]{},".contains(ch) {
                out.t(String(ch), PreviewStyle.punct)
                i += 1
                continue
            }

            var j = i
            var keySep = -1
            while j < c.count {
                let t = c[j]
                if t == " " || t == "\t" || "[]{},".contains(t) { break }
                if t == ":", isSeparator(c, after: j) { keySep = j; break }
                j += 1
            }
            let token = String(c[i..<j])

            if keySep >= 0 {                                 // key inside a flow mapping
                out.t(token, PreviewStyle.key)
                out.t(":", PreviewStyle.punct)
                i = keySep + 1
            } else {
                if isBlockIndicator(token) {
                    opensBlock = true
                    out.t(token, PreviewStyle.literal)
                } else {
                    out.t(token, color(for: token))
                }
                i = j
            }
        }
        return opensBlock
    }

    /// Index just past the closing quote, or end of line if it never closes.
    private static func endOfQuoted(_ c: [Character], from start: Int) -> Int {
        let quote = c[start]
        var i = start + 1
        while i < c.count {
            if quote == "\"", c[i] == "\\" { i += 2; continue }
            if c[i] == quote {
                if quote == "'", i + 1 < c.count, c[i + 1] == "'" { i += 2; continue }
                return i + 1
            }
            i += 1
        }
        return c.count
    }

    /// `|`, `>`, and their chomping / explicit-indent variants: `|-`, `>+`, `|2`.
    private static func isBlockIndicator(_ token: String) -> Bool {
        var rest = Substring(token)
        guard let head = rest.popFirst(), head == "|" || head == ">" else { return false }
        if let next = rest.first, next == "-" || next == "+" { rest = rest.dropFirst() }
        return rest.allSatisfy(\.isNumber)
    }

    private static func color(for token: String) -> NSColor {
        guard let first = token.first else { return PreviewStyle.string }
        if first == "&" || first == "*" || first == "!" { return PreviewStyle.tag }

        let lower = token.lowercased()
        if ["true", "false", "yes", "no", "on", "off", "null", "~"].contains(lower) {
            return PreviewStyle.literal
        }
        if Int(token) != nil { return PreviewStyle.number }
        if lower.hasPrefix("0x"), Int(lower.dropFirst(2), radix: 16) != nil { return PreviewStyle.number }
        if lower.hasPrefix("0o"), Int(lower.dropFirst(2), radix: 8) != nil { return PreviewStyle.number }
        // Double() accepts "infinity" and "nan"; YAML spells those .inf / .nan.
        if token.contains(where: \.isNumber), Double(token) != nil { return PreviewStyle.number }
        if lower == ".inf" || lower == "-.inf" || lower == ".nan" { return PreviewStyle.number }

        return PreviewStyle.string
    }
}
