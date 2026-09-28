import AppKit

/// JSON with comments, shown as written.
///
/// `tsconfig.json`, `.vscode/settings.json` and `devcontainer.json` are JSONC
/// behind a plain `.json` name, and the comments are usually the reason to
/// look: why a flag is off, which option was tried. Pretty-printing through
/// `JSONWriter` would drop them, so this highlights the source instead and
/// keeps its layout.
///
/// The lexer is JSON5-tolerant — single quotes, unquoted keys, `Infinity` —
/// so `.json5` files get the same treatment, unvalidated.
enum JSONCRenderer {

    enum Dialect {
        case jsonc, json5

        var label: String { self == .jsonc ? "JSON with comments" : "JSON5" }
    }

    /// Reads at most `maxBytes` and renders at most `maxLines` lines. JSONC is
    /// validated, so a broken file says where; JSON5 is only highlighted.
    static func render(url: URL, dialect: Dialect, maxBytes: Int = 4 << 20) throws -> NSAttributedString {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let totalBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        let clipped = (totalBytes ?? 0) > data.count
        let text = String(decoding: data, as: UTF8.self)

        var problem: String?
        if dialect == .jsonc, !clipped {
            do {
                _ = try JSONParser.parse(text, lenient: true)
            } catch let failure as JSONParser.Failure {
                let at = JSONParser.position(of: failure.index, in: text)
                problem = "invalid JSONC at line \(at.line), column \(at.column): \(failure.message)"
            }
        }
        return render(text: text, url: url, totalBytes: totalBytes, clipped: clipped,
                      note: dialect.label, problem: problem)
    }

    /// For a `.json` file the strict parser rejected and the lenient one
    /// accepted, so the text is already in hand.
    static func render(text: String, url: URL, totalBytes: Int?, clipped: Bool,
                       note: String, problem: String? = nil, maxLines: Int = 5000) -> NSAttributedString {
        var text = text
        if clipped, let cut = text.lastIndex(where: \.isNewline) { text = String(text[..<cut]) }
        if text.last?.isNewline == true { text.removeLast() }

        var c = Array(text)
        var truncated = clipped
        var lineCount = c.reduce(1) { $1.isNewline ? $0 + 1 : $0 }
        if lineCount > maxLines, let cut = nthNewline(c, maxLines) {
            c = Array(c[..<cut])
            lineCount = maxLines
            truncated = true
        }

        let body = NSMutableAttributedString()
        let gutter = String(lineCount).count
        var line = 1
        body.t(String(format: "%\(gutter)d  ", line), PreviewStyle.dim)

        // Tokens can span lines (block comments), so newlines inside any run
        // get their line number here rather than in a per-line loop.
        func emit(_ run: ArraySlice<Character>, _ color: NSColor) {
            var start = run.startIndex
            for n in run.indices where run[n].isNewline {
                if n > start { body.t(String(run[start..<n]), color) }
                line += 1
                body.t("\n", PreviewStyle.punct)
                body.t(String(format: "%\(gutter)d  ", line), PreviewStyle.dim)
                start = n + 1
            }
            if start < run.endIndex { body.t(String(run[start...]), color) }
        }

        var i = 0
        while i < c.count {
            let ch = c[i]
            var j = i + 1

            if ch.isWhitespace {
                while j < c.count, c[j].isWhitespace { j += 1 }
                emit(c[i..<j], PreviewStyle.punct)
            } else if let end = endOfComment(c, from: i) {
                j = end
                emit(c[i..<j], PreviewStyle.comment)
            } else if ch == "\"" || ch == "'" {
                j = endOfQuoted(c, from: i)
                emit(c[i..<j], isKey(c, after: j) ? PreviewStyle.key : PreviewStyle.string)
            } else if ch.isLetter || ch == "_" || ch == "$" {
                while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" || c[j] == "$" { j += 1 }
                let word = String(c[i..<j])
                let color = isKey(c, after: j) ? PreviewStyle.key
                    : ["true", "false", "null", "Infinity", "NaN"].contains(word) ? PreviewStyle.literal
                    : PreviewStyle.plain
                emit(c[i..<j], color)
            } else if ch.isNumber || "-+.".contains(ch) {
                // 1e-3, 0xFF, -Infinity: letters are consumed so hex and
                // JSON5's named numbers stay one token.
                while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "."
                        || ("+-".contains(c[j]) && "eE".contains(c[j - 1])) { j += 1 }
                let word = c[i..<j]
                emit(word, word.contains(where: \.isNumber) ? PreviewStyle.number
                     : word.contains(where: \.isLetter) ? PreviewStyle.literal : PreviewStyle.plain)
            } else {
                emit(c[i..<j], "{}[],:".contains(ch) ? PreviewStyle.punct : PreviewStyle.plain)
            }
            i = j
        }
        body.t("\n", PreviewStyle.punct)

        let header = NSMutableAttributedString()
        header.t(url.lastPathComponent, PreviewStyle.punct)
        header.t("  \u{2022}  \(lineCount) line\(lineCount == 1 ? "" : "s")", PreviewStyle.dim)
        if let totalBytes {
            header.t("  \u{2022}  \(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))", PreviewStyle.dim)
        }
        header.t("  \u{2022}  \(note)", PreviewStyle.dim)
        header.t(truncated ? "  \u{2022}  truncated\n\n" : "\n\n", PreviewStyle.dim)
        if let problem { header.t(problem + "\n\n", PreviewStyle.error) }

        header.append(body)
        if truncated {
            header.t("\n\u{2026} remainder not shown\n", PreviewStyle.dim)
        }
        return header
    }

    /// Index just past a `//` or `/* */` comment starting at `start`, or nil
    /// if none does. An unclosed block comment runs to the end.
    private static func endOfComment(_ c: [Character], from start: Int) -> Int? {
        guard c[start] == "/", start + 1 < c.count else { return nil }
        var i = start + 2
        if c[start + 1] == "/" {
            while i < c.count, !c[i].isNewline { i += 1 }
            return i
        }
        guard c[start + 1] == "*" else { return nil }
        while i + 1 < c.count {
            if c[i] == "*", c[i + 1] == "/" { return i + 2 }
            i += 1
        }
        return c.count
    }

    /// A string or bare word is a key when the next thing that is not
    /// whitespace or a comment is a colon.
    private static func isKey(_ c: [Character], after end: Int) -> Bool {
        var i = end
        while i < c.count {
            if c[i].isWhitespace { i += 1; continue }
            if let next = endOfComment(c, from: i) { i = next; continue }
            return c[i] == ":"
        }
        return false
    }

    /// Index just past the closing quote, or the end of the line if it never
    /// closes, so one bad string does not colour the rest of the file.
    private static func endOfQuoted(_ c: [Character], from start: Int) -> Int {
        let quote = c[start]
        var i = start + 1
        while i < c.count {
            if c[i] == "\\" { i += 2; continue }
            if c[i] == quote { return i + 1 }
            if c[i].isNewline { return i }
            i += 1
        }
        return c.count
    }

    private static func nthNewline(_ c: [Character], _ n: Int) -> Int? {
        var seen = 0
        for (i, ch) in c.enumerated() where ch.isNewline {
            seen += 1
            if seen == n { return i }
        }
        return nil
    }
}
