import AppKit

/// Text with no grammar of its own here: shell startup files, ignore lists,
/// `.conf`, and source in languages macOS has never heard of.
///
/// Deliberately shallow. It knows where comments start, what a quoted string
/// is, and for shell files `$variables`, `NAME=` assignments and a handful of
/// keywords. That is most of what you scan an rc file for, and every rule is
/// one a wrong guess cannot spread past the end of its line — except block
/// comments, which only the C-like syntax turns on.
enum PlainTextRenderer {

    struct Syntax {
        var lineComments: [String] = []
        var blockComment: (open: String, close: String)?
        var quotes: Set<Character> = []
        /// Vimscript: `"` opens a comment at the start of a line and a string
        /// anywhere else.
        var commentsOnlyAtLineStart = false
        var variables = false
        var assignments = false
        var keywords: Set<String> = []

        /// No colour at all, just the gutter. For text we know nothing about.
        static let plain = Syntax()

        /// `#` comments: ignore files, `.conf`, Ruby DSLs, Starlark, HCL-lite.
        static let hash = Syntax(lineComments: ["#"], quotes: ["\"", "'"], assignments: true)

        static let shell = Syntax(
            lineComments: ["#"], quotes: ["\"", "'", "`"], variables: true, assignments: true,
            keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
                       "case", "esac", "in", "function", "return", "export", "local", "readonly",
                       "declare", "typeset", "unset", "source", "alias", "unalias", "set",
                       "setopt", "unsetopt", "shopt", "autoload", "bindkey", "zstyle", "zmodload",
                       "eval", "exec", "trap"])

        static let cLike = Syntax(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"])

        /// Terraform, Nomad, Nix: `#` and `//` and `/* */` all appear.
        static let hcl = Syntax(lineComments: ["#", "//"], blockComment: ("/*", "*/"),
                                quotes: ["\""], assignments: true)

        static let dashes = Syntax(lineComments: ["--"], quotes: ["\"", "'"])

        static let semicolon = Syntax(lineComments: [";"], quotes: ["\""])

        static let vim = Syntax(lineComments: ["\""], quotes: ["'", "\""], commentsOnlyAtLineStart: true)
    }

    /// Reads at most `maxBytes` and renders at most `maxLines` lines.
    static func render(url: URL, syntax: Syntax, maxBytes: Int = 4 << 20,
                       maxLines: Int = 5000) throws -> NSAttributedString {
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
        var inBlock = false

        for (offset, line) in lines.enumerated() {
            body.t(String(format: "%\(gutter)d  ", offset + 1), PreviewStyle.dim)
            let c = Array(line.hasSuffix("\r") ? String(line.dropLast()) : line)
            inBlock = scanLine(c, syntax, inBlock: inBlock, into: body)
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

    /// Colours one line and returns whether a block comment is still open.
    private static func scanLine(_ c: [Character], _ syntax: Syntax, inBlock: Bool,
                                 into out: NSMutableAttributedString) -> Bool {
        var i = 0
        if inBlock, let block = syntax.blockComment {
            guard let close = find(block.close, in: c, from: 0) else {
                out.t(String(c), PreviewStyle.comment)
                return true
            }
            i = close + block.close.count
            out.t(String(c[..<i]), PreviewStyle.comment)
        }

        let indent = i + c[i...].prefix { $0 == " " || $0 == "\t" }.count
        out.t(String(c[i..<indent]), PreviewStyle.punct)
        i = indent

        // `export PATH=…`, `FOO=bar`, `key = value`. Shell forbids the spaces
        // around `=`; config files allow them.
        if syntax.assignments {
            var j = i
            if syntax.variables, c.count - j > 7, String(c[j..<j + 7]) == "export " {
                out.t("export", PreviewStyle.literal)
                out.t(" ", PreviewStyle.punct)
                j += 7
                i = j
            }
            while j < c.count, c[j].isLetter || c[j].isNumber || "_.-".contains(c[j]) { j += 1 }
            var eq = j
            if !syntax.variables { while eq < c.count, c[eq] == " " || c[eq] == "\t" { eq += 1 } }
            if j > i, eq < c.count, c[eq] == "=", c[i] != "-" {
                out.t(String(c[i..<j]), PreviewStyle.key)
                out.t(String(c[j...eq]), PreviewStyle.punct)
                i = eq + 1
            }
        }

        var plain = ""
        func flush() {
            if !plain.isEmpty { out.t(plain, PreviewStyle.plain); plain = "" }
        }

        while i < c.count {
            let ch = c[i]

            if syntax.lineComments.contains(where: { startsComment($0, c, at: i, indent, syntax) }) {
                flush()
                out.t(String(c[i...]), PreviewStyle.comment)
                return false
            }
            if let block = syntax.blockComment, matches(block.open, c, at: i) {
                flush()
                guard let close = find(block.close, in: c, from: i + block.open.count) else {
                    out.t(String(c[i...]), PreviewStyle.comment)
                    return true
                }
                let end = close + block.close.count
                out.t(String(c[i..<end]), PreviewStyle.comment)
                i = end
                continue
            }
            if syntax.quotes.contains(ch), opensString(c, at: i), let end = endOfQuoted(c, from: i) {
                flush()
                out.t(String(c[i..<end]), PreviewStyle.string)
                i = end
                continue
            }
            if syntax.variables, ch == "$", let end = endOfVariable(c, from: i) {
                flush()
                out.t(String(c[i..<end]), PreviewStyle.tag)
                i = end
                continue
            }
            if ch.isLetter || ch.isNumber || ch == "_" {
                var j = i + 1
                while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
                let word = String(c[i..<j])
                let boundary = i == 0 || !(c[i - 1].isLetter || c[i - 1].isNumber || "_-.".contains(c[i - 1]))
                let after = j == c.count || c[j] != "-"              // `set-option` is not `set`
                if boundary, after, syntax.keywords.contains(word) {
                    flush()
                    out.t(word, PreviewStyle.literal)
                } else if boundary, !syntax.lineComments.isEmpty, word.allSatisfy(\.isNumber) {
                    flush()
                    out.t(word, PreviewStyle.number)
                } else {
                    plain += word
                }
                i = j
                continue
            }
            plain.append(ch)
            i += 1
        }
        flush()
        return false
    }

    /// `#` only starts a comment at a word boundary, as in the shell, so
    /// `url#anchor` and `$#` stay what they are. `//` has to dodge `https://`.
    private static func startsComment(_ prefix: String, _ c: [Character], at i: Int,
                                      _ lineStart: Int, _ syntax: Syntax) -> Bool {
        guard matches(prefix, c, at: i) else { return false }
        if syntax.commentsOnlyAtLineStart { return i == lineStart }
        guard i > 0 else { return true }
        let before = c[i - 1]
        if prefix == "//" { return before != ":" }
        return before == " " || before == "\t" || before == ";" || before == "("
    }

    /// A quote opens a string only where a word could start, so the
    /// apostrophe in `don't` in a comment-less `.gitignore` stays plain.
    private static func opensString(_ c: [Character], at i: Int) -> Bool {
        i == 0 || !(c[i - 1].isLetter || c[i - 1].isNumber)
    }

    /// Index just past the closing quote, or nil if the line never closes it —
    /// then the quote is shown plain rather than colouring the rest red.
    private static func endOfQuoted(_ c: [Character], from start: Int) -> Int? {
        let quote = c[start]
        var i = start + 1
        while i < c.count {
            if quote != "'", c[i] == "\\" { i += 2; continue }
            if c[i] == quote { return i + 1 }
            i += 1
        }
        return nil
    }

    /// `$NAME`, `${NAME:-default}`, `$1`, `$?`, `$#`.
    private static func endOfVariable(_ c: [Character], from start: Int) -> Int? {
        let i = start + 1
        guard i < c.count else { return nil }
        if c[i] == "{" {
            guard let close = c[i...].firstIndex(of: "}") else { return nil }
            return close + 1
        }
        if "?#@*!$-0123456789".contains(c[i]) { return i + 1 }
        var j = i
        while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" { j += 1 }
        return j > i ? j : nil
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
