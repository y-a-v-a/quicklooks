import AppKit

/// Highlights INI and TOML.
///
/// macOS hands both to us through the same shape of file — `[section]`,
/// `key = value`, comment lines — so they share a lexer. They differ in one
/// place that matters for colouring: Windows INI has no inline comments, so in
/// `path = C:\tmp ; note` the value really is `C:\tmp ; note`, while TOML ends
/// the value at a `#`. Guessing wrong swallows part of a value, so the dialect
/// is chosen from the extension rather than sniffed.
enum INIRenderer {

    enum Dialect {
        case ini, toml

        /// Only `.toml` gets TOML rules. `.cfg`/`.config` resolve to
        /// `public.toml` on macOS but in practice hold configparser-style INI,
        /// and INI rules are the safer of the two to be wrong about.
        static func of(_ url: URL) -> Dialect {
            url.pathExtension.lowercased() == "toml" ? .toml : .ini
        }

        var inlineComments: Bool { self == .toml }
        var multilineStrings: Bool { self == .toml }
    }

    /// Reads at most `maxBytes` and renders at most `maxLines` lines. Pass
    /// `dialect` for files whose name says more than their extension, like
    /// `Pipfile` or `Cargo.lock`.
    static func render(url: URL, dialect: Dialect? = nil,
                       maxBytes: Int = 4 << 20, maxLines: Int = 5000) throws -> NSAttributedString {
        let dialect = dialect ?? Dialect.of(url)

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let totalBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        var truncated = (totalBytes ?? 0) > data.count

        var text = String(decoding: data, as: UTF8.self)
        if truncated, let cut = text.lastIndex(of: "\n") { text = String(text[..<cut]) }

        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            truncated = true
        }

        let body = NSMutableAttributedString()
        let gutter = String(max(lines.count, 1)).count
        var openMultiline: Character?

        for (offset, line) in lines.enumerated() {
            body.t(String(format: "%\(gutter)d  ", offset + 1), PreviewStyle.dim)
            let c = Array(line)

            // Inside a TOML """ or ''' string nothing is markup.
            if let quote = openMultiline {
                body.t(line, PreviewStyle.string)
                body.t("\n", PreviewStyle.punct)
                if line.contains(String(repeating: quote, count: 3)) { openMultiline = nil }
                continue
            }

            let indent = c.prefix { $0 == " " || $0 == "\t" }.count
            body.t(String(c[0..<indent]), PreviewStyle.punct)
            let i = indent

            if i == c.count {
                body.t("\n", PreviewStyle.punct)
                continue
            }
            if c[i] == ";" || c[i] == "#" {
                body.t(String(c[i...]), PreviewStyle.comment)
                body.t("\n", PreviewStyle.punct)
                continue
            }

            if c[i] == "[", let section = sectionEnd(c, from: i) {
                // Bold, brackets included, so the header reads as one unit.
                // Sections are what you scan a config file for, and hue alone
                // did not separate them from keys at this size.
                body.t(String(c[i..<section.nameStart]), PreviewStyle.punct, PreviewStyle.monoBold)
                body.t(String(c[section.nameStart..<section.nameEnd]), PreviewStyle.tag, PreviewStyle.monoBold)
                body.t(String(c[section.nameEnd...section.close]), PreviewStyle.punct, PreviewStyle.monoBold)
                openMultiline = scanValue(c, from: section.close + 1, into: body, dialect)
            } else if let (delimiter, at) = keyDelimiter(c, from: i, dialect) {
                body.t(String(c[i..<at]), PreviewStyle.key)
                body.t(String(delimiter), PreviewStyle.punct)
                openMultiline = scanValue(c, from: at + 1, into: body, dialect)
            } else {
                openMultiline = scanValue(c, from: i, into: body, dialect)
            }

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

    /// Spans of `[section]` and TOML's `[[array of tables]]`. Anchored on the
    /// *first* `]`, not the last, so a `# note ]` after the header does not
    /// swallow the line.
    private static func sectionEnd(_ c: [Character], from start: Int)
        -> (nameStart: Int, nameEnd: Int, close: Int)? {
        var nameStart = start
        while nameStart < c.count, c[nameStart] == "[" { nameStart += 1 }
        guard let firstClose = (nameStart..<c.count).first(where: { c[$0] == "]" }) else { return nil }
        var close = firstClose
        while close + 1 < c.count, c[close + 1] == "]" { close += 1 }
        return (nameStart, firstClose, close)
    }

    /// First `=`, or a `:` followed by whitespace. Requiring the space keeps
    /// `path = C:\tmp` and `url = http://host` from splitting on their colons.
    private static func keyDelimiter(_ c: [Character], from start: Int, _ dialect: Dialect)
        -> (Character, Int)? {
        var i = start
        while i < c.count {
            let ch = c[i]
            if ch == "\"" || ch == "'" { i = endOfQuoted(c, from: i); continue }
            if dialect.inlineComments, ch == "#", i > start, c[i - 1] == " " || c[i - 1] == "\t" {
                return nil
            }
            if ch == "=" { return ("=", i) }
            if ch == ":", i + 1 == c.count || c[i + 1] == " " || c[i + 1] == "\t" { return (":", i) }
            i += 1
        }
        return nil
    }

    /// Returns the quote character of a multi-line string left open at the end
    /// of the line, so the caller can hold the following lines as literal.
    private static func scanValue(_ c: [Character], from start: Int,
                                  into out: NSMutableAttributedString, _ dialect: Dialect) -> Character? {
        var i = start
        while i < c.count {
            let ch = c[i]

            if ch == " " || ch == "\t" {
                out.t(String(ch), PreviewStyle.punct)
                i += 1
                continue
            }
            if dialect.inlineComments, ch == "#", i == 0 || c[i - 1] == " " || c[i - 1] == "\t" {
                out.t(String(c[i...]), PreviewStyle.comment)
                return nil
            }
            if ch == "\"" || ch == "'" {
                if dialect.multilineStrings, isTriple(c, at: i) {
                    if let end = endOfTriple(c, from: i) {
                        out.t(String(c[i..<end]), PreviewStyle.string)
                        i = end
                        continue
                    }
                    out.t(String(c[i...]), PreviewStyle.string)
                    return ch
                }
                let end = endOfQuoted(c, from: i)
                out.t(String(c[i..<end]), PreviewStyle.string)
                i = end
                continue
            }
            if "[]{},=".contains(ch) {                       // arrays, inline tables
                out.t(String(ch), PreviewStyle.punct)
                i += 1
                continue
            }

            var j = i
            while j < c.count, !" \t[]{},=".contains(c[j]), c[j] != "\"", c[j] != "'" { j += 1 }

            // A token followed by `=` is a key in an inline table. Top-level
            // keys never reach here — keyDelimiter took them first.
            var ahead = j
            while ahead < c.count, c[ahead] == " " || c[ahead] == "\t" { ahead += 1 }
            let token = String(c[i..<j])
            out.t(token, ahead < c.count && c[ahead] == "=" ? PreviewStyle.key : color(for: token))
            i = j
        }
        return nil
    }

    private static func isTriple(_ c: [Character], at i: Int) -> Bool {
        i + 2 < c.count && c[i + 1] == c[i] && c[i + 2] == c[i]
    }

    private static func endOfTriple(_ c: [Character], from start: Int) -> Int? {
        let quote = c[start]
        var i = start + 3
        while i + 2 < c.count {
            if c[i] == quote, c[i + 1] == quote, c[i + 2] == quote { return i + 3 }
            i += 1
        }
        return nil
    }

    /// Index just past the closing quote, or end of line if it never closes.
    /// TOML's single-quoted strings are literal — no backslash escapes — which
    /// is why only the double-quoted branch skips them.
    private static func endOfQuoted(_ c: [Character], from start: Int) -> Int {
        let quote = c[start]
        var i = start + 1
        while i < c.count {
            if quote == "\"", c[i] == "\\" { i += 2; continue }
            if c[i] == quote { return i + 1 }
            i += 1
        }
        return c.count
    }

    private static func color(for token: String) -> NSColor {
        guard !token.isEmpty else { return PreviewStyle.string }

        let lower = token.lowercased()
        if ["true", "false", "yes", "no", "on", "off", "none", "null"].contains(lower) {
            return PreviewStyle.literal
        }

        // TOML dates and times: 1979-05-27T07:32:00Z, 07:32:00.
        if token.count >= 8, token.first!.isNumber,
           token.allSatisfy({ $0.isNumber || "-:.+TZz".contains($0) }) {
            return PreviewStyle.number
        }

        let digits = lower.replacingOccurrences(of: "_", with: "")   // TOML 1_000_000
        let unsigned = digits.hasPrefix("-") || digits.hasPrefix("+") ? String(digits.dropFirst()) : digits
        if Int(unsigned) != nil || Double(unsigned) != nil, unsigned.contains(where: \.isNumber) {
            return PreviewStyle.number
        }
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where unsigned.hasPrefix(prefix) {
            if Int(unsigned.dropFirst(2), radix: radix) != nil { return PreviewStyle.number }
        }

        return PreviewStyle.string
    }
}
