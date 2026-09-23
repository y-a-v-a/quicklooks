import AppKit

/// Highlights Dockerfiles, and Podman's Containerfiles, which are the same
/// language under another name.
///
/// Line-oriented like the YAML and INI renderers. The two things that carry
/// across lines are backslash continuations, where the next line is still
/// arguments and not a new instruction, and BuildKit heredocs
/// (`RUN <<EOF` … `EOF`), whose bodies are literal text.
enum DockerfileRenderer {

    struct NotADockerfile: Error {}

    /// The appex also claims `public.data`, because a bare `Dockerfile` has no
    /// extension to hang a type on. That routes every extensionless file here,
    /// so the name decides whether this is ours:
    /// `Dockerfile`, `.Dockerfile`, `Dockerfile.prod`, `app.Dockerfile`.
    static func handles(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        return ["dockerfile", "containerfile"].contains { base in
            name == base || name == "." + base || name.hasPrefix(base + ".") || ext == base
        }
    }

    private static let instructions: Set<String> = [
        "ADD", "ARG", "CMD", "COPY", "ENTRYPOINT", "ENV", "EXPOSE", "FROM",
        "HEALTHCHECK", "LABEL", "MAINTAINER", "ONBUILD", "RUN", "SHELL",
        "STOPSIGNAL", "USER", "VOLUME", "WORKDIR"
    ]

    /// Reads at most `maxBytes` and renders at most `maxLines` lines.
    static func render(url: URL, maxBytes: Int = 4 << 20, maxLines: Int = 5000) throws -> NSAttributedString {
        guard handles(url) else { throw NotADockerfile() }

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

        var escape: Character = "\\"         // `# escape=`` ` switches it, for Windows paths
        var inDirectives = true              // parser directives only count before anything else
        var instruction = ""                 // carried across continuation lines
        var continuing = false
        var heredocs: [(tag: String, stripTabs: Bool)] = []
        var inHeredoc = false

        for (offset, line) in lines.enumerated() {
            body.t(String(format: "%\(gutter)d  ", offset + 1), PreviewStyle.dim)
            let c = Array(line.hasSuffix("\r") ? String(line.dropLast()) : line)

            if inHeredoc, let open = heredocs.first {
                let candidate = open.stripTabs ? String(c.drop { $0 == "\t" }) : String(c)
                if candidate == open.tag {
                    body.t(String(c), PreviewStyle.tag)
                    heredocs.removeFirst()
                    inHeredoc = !heredocs.isEmpty
                } else {
                    body.t(String(c), PreviewStyle.string)
                }
                body.t("\n", PreviewStyle.punct)
                continue
            }

            let indent = c.prefix { $0 == " " || $0 == "\t" }.count
            body.t(String(c[0..<indent]), PreviewStyle.punct)
            var i = indent

            if i == c.count {
                body.t("\n", PreviewStyle.punct)
                continue
            }

            // Comment lines are stripped before continuations are joined, so
            // one in the middle of a RUN leaves `continuing` as it was.
            if c[i] == "#" {
                let comment = String(c[i...])
                if inDirectives, let value = directive(comment, named: "escape"), value.count == 1 {
                    escape = value.first!
                }
                body.t(comment, PreviewStyle.comment)
                body.t("\n", PreviewStyle.punct)
                continue
            }
            inDirectives = false

            if !continuing {
                instruction = ""
                // ONBUILD takes another instruction as its argument.
                repeat {
                    var j = i
                    while j < c.count, c[j] != " ", c[j] != "\t" { j += 1 }
                    let word = String(c[i..<j])
                    instruction = word.uppercased()
                    body.t(word, PreviewStyle.key, PreviewStyle.monoBold)
                    i = j
                    while i < c.count, c[i] == " " || c[i] == "\t" {
                        body.t(String(c[i]), PreviewStyle.punct)
                        i += 1
                    }
                } while instruction == "ONBUILD" && i < c.count
            }

            // A trailing escape joins the next line onto this instruction.
            var end = c.count
            while end > i, c[end - 1] == " " || c[end - 1] == "\t" { end -= 1 }
            continuing = end > i && c[end - 1] == escape
            if continuing { end -= 1 }

            heredocs += scanArguments(c, from: i, to: end, instruction, into: body)
            body.t(String(c[end...]), PreviewStyle.punct)
            body.t("\n", PreviewStyle.punct)
            if !continuing, !heredocs.isEmpty { inHeredoc = true }
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

    /// `# escape=`` ` → "`". Directive names are case-insensitive.
    private static func directive(_ comment: String, named name: String) -> String? {
        let parts = comment.dropFirst().split(separator: "=", maxSplits: 1)
        guard parts.count == 2,
              parts[0].trimmingCharacters(in: .whitespaces).lowercased() == name else { return nil }
        return parts[1].trimmingCharacters(in: .whitespaces)
    }

    /// Colours `c[start..<end]` and returns the heredocs it opened, in order.
    private static func scanArguments(_ c: [Character], from start: Int, to end: Int, _ instruction: String,
                                      into out: NSMutableAttributedString) -> [(tag: String, stripTabs: Bool)] {
        var opened: [(tag: String, stripTabs: Bool)] = []
        let takesHeredocs = ["RUN", "COPY", "ADD"].contains(instruction)
        let takesAssignments = ["ENV", "LABEL", "ARG"].contains(instruction)
        var i = start

        while i < end {
            let ch = c[i]

            if ch == " " || ch == "\t" {
                out.t(String(ch), PreviewStyle.punct)
                i += 1
                continue
            }
            if ch == "\"" || ch == "'" {
                let close = min(endOfQuoted(c, from: i), end)
                out.t(String(c[i..<close]), PreviewStyle.string)
                i = close
                continue
            }
            if ch == "$", let close = endOfVariable(c, from: i, to: end) {
                out.t(String(c[i..<close]), PreviewStyle.tag)
                i = close
                continue
            }
            if takesHeredocs, ch == "<", let (tag, strip, close) = heredoc(c, from: i, to: end) {
                out.t(String(c[i..<close]), PreviewStyle.tag)
                opened.append((tag, strip))
                i = close
                continue
            }
            // `--mount=type=cache`, `--from=build`: the flag name, then its value.
            if ch == "-", i + 1 < end, c[i + 1] == "-", i == start || c[i - 1] == " " || c[i - 1] == "\t" {
                var j = i + 2
                while j < end, c[j].isLetter || c[j].isNumber || c[j] == "-" { j += 1 }
                out.t(String(c[i..<j]), PreviewStyle.literal)
                i = j
                continue
            }
            if "[],=;|&".contains(ch) {                      // exec form, flag values, shell chains
                out.t(String(ch), PreviewStyle.punct)
                i += 1
                continue
            }

            var j = i
            while j < end, !" \t\"'$[],=;|&".contains(c[j]) { j += 1 }
            if j == i { j += 1 }                             // a lone `$` or `<`
            let word = String(c[i..<j])
            let wordStart = i == start || c[i - 1] == " " || c[i - 1] == "\t"
            out.t(word, color(for: word, instruction,
                              isKey: takesAssignments && wordStart && j < end && c[j] == "="))
            i = j
        }
        return opened
    }

    private static func color(for word: String, _ instruction: String, isKey: Bool) -> NSColor {
        if isKey { return PreviewStyle.key }
        if instruction == "FROM", word.uppercased() == "AS" { return PreviewStyle.literal }
        if instruction == "HEALTHCHECK", ["CMD", "NONE"].contains(word.uppercased()) { return PreviewStyle.key }
        // EXPOSE 8080/tcp, STOPSIGNAL 9, HEALTHCHECK --retries=3
        let port = word.split(separator: "/", maxSplits: 1)
        if let number = port.first, number.allSatisfy(\.isNumber),
           port.count == 1 || ["tcp", "udp"].contains(port[1].lowercased()) {
            return PreviewStyle.number
        }
        return PreviewStyle.plain
    }

    /// `$NAME` or `${NAME:-default}`; nil for a `$` that starts neither.
    private static func endOfVariable(_ c: [Character], from start: Int, to end: Int) -> Int? {
        var i = start + 1
        if i < end, c[i] == "{" {
            while i < end, c[i] != "}" { i += 1 }
            return min(i + 1, end)
        }
        while i < end, c[i].isLetter || c[i].isNumber || c[i] == "_" { i += 1 }
        return i > start + 1 ? i : nil
    }

    /// `<<EOF`, `<<-EOF`, `<<"EOF"`. Quoting only turns off expansion inside
    /// the body, which is shown as literal text either way.
    private static func heredoc(_ c: [Character], from start: Int, to end: Int)
        -> (tag: String, stripTabs: Bool, close: Int)? {
        guard start + 2 < end, c[start + 1] == "<" else { return nil }
        var i = start + 2
        let strip = c[i] == "-"
        if strip { i += 1 }
        let quote: Character? = i < end && (c[i] == "\"" || c[i] == "'") ? c[i] : nil
        if quote != nil { i += 1 }
        let tagStart = i
        while i < end, c[i].isLetter || c[i].isNumber || c[i] == "_" { i += 1 }
        guard i > tagStart else { return nil }
        let tag = String(c[tagStart..<i])
        if let quote {
            guard i < end, c[i] == quote else { return nil }
            i += 1
        }
        return (tag, strip, i)
    }

    /// Index just past the closing quote, or end of line if it never closes.
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
}
