import Foundation

/// Line breaks for minified C-like code, the way XMLHighlighter.reflow does
/// it for XML: one line of megabytes takes a text view seconds to lay out,
/// and none of it is readable anyway.
///
/// Breaks after `;` (not inside a `for (…)` header), after `{` and around
/// `}`, indented by brace depth. Strings, template literals, comments and
/// regex literals are copied untouched, so nothing inside them moves. Stops
/// one line past `maxLines`, so the caller marks the result truncated.
enum CodeReflow {

    /// True when some line is longer than `limit` characters.
    static func isMinified(_ text: String, limit: Int = 5000) -> Bool {
        var current = 0
        for s in text.unicodeScalars {
            if s == "\n" { current = 0 } else { current += 1; if current > limit { return true } }
        }
        return false
    }

    /// Words after which a `/` starts a regex rather than a division.
    private static let regexAfterWords: Set<String> = ["return", "typeof", "case", "do", "else", "in",
                                                       "of", "new", "delete", "void", "throw", "yield",
                                                       "await"]

    static func reflow(_ text: String, maxLines: Int) -> String {
        let c = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(c.count + c.count / 8)
        var lines = 1, depth = 0, parens = 0, i = 0
        // Parens are counted per brace level: a function body inside a call's
        // arguments, as in `(function(){…})()`, still breaks after `;`.
        var outerParens: [Int] = []
        var atLineStart = true
        var lastSignificant: Unicode.Scalar = "\n"      // last non-blank character outside literals
        var lastWord = ""                               // set while the last token was a word

        /// Starts a new line, or re-indents the current one if it is still
        /// empty, as when two `}` follow each other.
        func newline() {
            if atLineStart {
                while out.last == " " { out.removeLast() }
            } else {
                out.append("\n")
                lines += 1
            }
            out.append(contentsOf: repeatElement(" ", count: depth * 2))
            atLineStart = true
        }
        func emit(_ from: Int, _ to: Int) {
            out.append(contentsOf: c[from..<to])
            atLineStart = false
        }
        func next(after j: Int) -> Unicode.Scalar? {
            var k = j
            while k < c.count, c[k] == " " || c[k] == "\t" { k += 1 }
            return k < c.count ? c[k] : nil
        }

        while i < c.count, lines <= maxLines {
            let ch = c[i]
            if ch == "\n" { newline(); i += 1; continue }
            if atLineStart, ch == " " || ch == "\t" || ch == "\r" { i += 1; continue }

            var end = i + 1
            switch ch {
            case "\"", "'":
                end = endOfString(c, from: i)
            case "`":
                end = endOfTemplate(c, from: i)
            case "/" where i + 1 < c.count && c[i + 1] == "/":
                end = c[i...].firstIndex(of: "\n") ?? c.count
            case "/" where i + 1 < c.count && c[i + 1] == "*":
                end = endOfBlockComment(c, from: i)
                emit(i, end)                            // keeps its own line breaks
                i = end
                continue
            case "/" where "(,=:[!&|?{};+-*%<>~^\n".unicodeScalars.contains(lastSignificant)
                            || regexAfterWords.contains(lastWord):
                end = endOfRegex(c, from: i) ?? i + 1
            case "(":
                parens += 1
            case ")":
                parens = max(parens - 1, 0)
            case "{":
                if next(after: i + 1) == "}" {          // `{}` stays together
                    emit(i, i + 1); i += 1
                    while c[i] != "}" { i += 1 }
                    emit(i, i + 1); i += 1
                    lastSignificant = "}"; lastWord = ""
                    continue
                }
                emit(i, i + 1); i += 1
                depth += 1
                outerParens.append(parens); parens = 0
                newline()
                lastSignificant = "{"; lastWord = ""
                continue
            case "}":
                depth = max(depth - 1, 0)
                parens = outerParens.popLast() ?? 0
                newline()
                emit(i, i + 1); i += 1
                if let n = next(after: i), !"),;.]".unicodeScalars.contains(n) { newline() }
                lastSignificant = "}"; lastWord = ""
                continue
            case ";":
                emit(i, i + 1); i += 1
                if parens == 0, next(after: i) != "}" { newline() }
                lastSignificant = ";"; lastWord = ""
                continue
            default:
                if ch.properties.isAlphabetic || ch == "_" || ch == "$" {
                    while end < c.count, c[end].properties.isAlphabetic || c[end].properties.numericType != nil
                            || c[end] == "_" || c[end] == "$" { end += 1 }
                    emit(i, end)
                    lastWord = String(String.UnicodeScalarView(c[i..<end]))
                    lastSignificant = c[end - 1]
                    i = end
                    continue
                }
            }
            emit(i, end)
            if ch != " ", ch != "\t" { lastSignificant = c[end - 1]; lastWord = "" }
            i = end
        }
        return String(out)
    }

    // MARK: literals: each returns the index just past its end

    private static func endOfString(_ c: [Unicode.Scalar], from start: Int) -> Int {
        var j = start + 1
        while j < c.count, c[j] != "\n" {
            if c[j] == "\\" { j += 2; continue }
            if c[j] == c[start] { return j + 1 }
            j += 1
        }
        return min(j, c.count)
    }

    /// `` `…${ expr }…` ``: braces inside `${}` are counted, not reflowed.
    private static func endOfTemplate(_ c: [Unicode.Scalar], from start: Int) -> Int {
        var j = start + 1
        while j < c.count {
            if c[j] == "\\" { j += 2; continue }
            if c[j] == "`" { return j + 1 }
            if c[j] == "$", j + 1 < c.count, c[j + 1] == "{" {
                var level = 1
                j += 2
                while j < c.count, level > 0 {
                    if c[j] == "{" { level += 1 } else if c[j] == "}" { level -= 1 }
                    j += 1
                }
                continue
            }
            j += 1
        }
        return c.count
    }

    private static func endOfBlockComment(_ c: [Unicode.Scalar], from start: Int) -> Int {
        var j = start + 2
        while j + 1 < c.count {
            if c[j] == "*", c[j + 1] == "/" { return j + 2 }
            j += 1
        }
        return c.count
    }

    /// `/…/flags`, with `/` allowed inside a `[…]` class. Nil when the line
    /// ends first: then it was a division after all.
    private static func endOfRegex(_ c: [Unicode.Scalar], from start: Int) -> Int? {
        var j = start + 1, inClass = false
        while j < c.count, c[j] != "\n" {
            switch c[j] {
            case "\\": j += 2; continue
            case "[": inClass = true
            case "]": inClass = false
            case "/" where !inClass:
                j += 1
                while j < c.count, c[j].properties.isAlphabetic { j += 1 }
                return j
            default: break
            }
            j += 1
        }
        return nil
    }
}
