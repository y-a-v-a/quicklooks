import AppKit

/// A parsed JSON document that remembers the order its keys were written in
/// and the exact text of its numbers.
///
/// `JSONSerialization` hands back an unordered dictionary and `NSNumber`s.
/// That is fine for JSONL, whose records get sorted on purpose so two previews
/// can be diffed by eye, but reordering the keys of a `package.json` is the
/// kind of help nobody asked for — and round-tripping through `NSNumber` turns
/// `1.0` into `1` and `1e3` into `1000`.
enum JSONValue {
    case object([(key: String, value: JSONValue)])
    case array([JSONValue])
    case string(String)     // raw source text, quotes included
    case number(String)     // raw source text
    case bool(Bool)
    case null
}

struct JSONParser {

    enum Failure: Error {
        case syntax(index: Int, message: String)

        var index: Int {
            switch self { case .syntax(let i, _): return i }
        }
        var message: String {
            switch self { case .syntax(_, let m): return m }
        }
    }

    private let c: [Character]
    private var i = 0
    private let maxDepth: Int
    private let lenient: Bool

    private init(_ text: String, maxDepth: Int, lenient: Bool) {
        self.c = Array(text)
        self.maxDepth = maxDepth
        self.lenient = lenient
    }

    /// Fragments are allowed at the top level, so a JSONL line holding a bare
    /// `123` or `"str"` parses.
    ///
    /// `lenient` accepts JSONC, the dialect of `tsconfig.json` and VS Code's
    /// settings: `//` and `/* */` comments, and a trailing comma before `}`
    /// or `]`. Nothing else is relaxed — JSON5's unquoted keys and single
    /// quotes still fail.
    static func parse(_ text: String, maxDepth: Int = 128, lenient: Bool = false) throws -> JSONValue {
        var p = JSONParser(text, maxDepth: maxDepth, lenient: lenient)
        p.skipWhitespace()
        let value = try p.parseValue(depth: 0)
        p.skipWhitespace()
        guard p.i == p.c.count else {
            throw Failure.syntax(index: p.i, message: "unexpected trailing content")
        }
        return value
    }

    /// 1-based line and column for an index, for error messages.
    static func position(of index: Int, in text: String) -> (line: Int, column: Int) {
        var line = 1, column = 1
        for (n, ch) in text.enumerated() {
            if n >= index { break }
            if ch.isNewline { line += 1; column = 1 } else { column += 1 }
        }
        return (line, column)
    }

    // MARK: - scanning

    /// Comments count as whitespace in lenient mode. An unterminated `/*`
    /// runs to the end, where the caller then reports what is missing.
    private mutating func skipWhitespace() {
        while i < c.count {
            // "\r\n" is a single Character, equal to neither "\r" nor "\n".
            if c[i] == " " || c[i] == "\t" || c[i] == "\n" || c[i] == "\r" || c[i] == "\r\n" { i += 1; continue }
            guard lenient, c[i] == "/", i + 1 < c.count else { return }
            if c[i + 1] == "/" {
                while i < c.count, !c[i].isNewline { i += 1 }
            } else if c[i + 1] == "*" {
                i += 2
                while i < c.count, !(c[i] == "*" && i + 1 < c.count && c[i + 1] == "/") { i += 1 }
                i = min(i + 2, c.count)
            } else {
                return
            }
        }
    }

    private mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth <= maxDepth else {
            throw Failure.syntax(index: i, message: "nested more than \(maxDepth) deep")
        }
        guard i < c.count else { throw Failure.syntax(index: i, message: "unexpected end of input") }

        switch c[i] {
        case "{": return try parseObject(depth: depth)
        case "[": return try parseArray(depth: depth)
        case "\"": return .string(try parseString())
        case "t": try expect("true"); return .bool(true)
        case "f": try expect("false"); return .bool(false)
        case "n": try expect("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    private mutating func parseObject(depth: Int) throws -> JSONValue {
        i += 1                                          // {
        var members: [(key: String, value: JSONValue)] = []
        skipWhitespace()
        if i < c.count, c[i] == "}" { i += 1; return .object(members) }

        while true {
            skipWhitespace()
            guard i < c.count, c[i] == "\"" else {
                throw Failure.syntax(index: i, message: "expected a quoted key")
            }
            let key = try parseString()
            skipWhitespace()
            guard i < c.count, c[i] == ":" else {
                throw Failure.syntax(index: i, message: "expected ':' after key")
            }
            i += 1
            skipWhitespace()
            members.append((key, try parseValue(depth: depth + 1)))
            skipWhitespace()

            guard i < c.count else { throw Failure.syntax(index: i, message: "unclosed object") }
            if c[i] == "," {
                i += 1
                skipWhitespace()
                if lenient, i < c.count, c[i] == "}" { i += 1; return .object(members) }
                continue
            }
            if c[i] == "}" { i += 1; return .object(members) }
            throw Failure.syntax(index: i, message: "expected ',' or '}'")
        }
    }

    private mutating func parseArray(depth: Int) throws -> JSONValue {
        i += 1                                          // [
        var elements: [JSONValue] = []
        skipWhitespace()
        if i < c.count, c[i] == "]" { i += 1; return .array(elements) }

        while true {
            skipWhitespace()
            elements.append(try parseValue(depth: depth + 1))
            skipWhitespace()

            guard i < c.count else { throw Failure.syntax(index: i, message: "unclosed array") }
            if c[i] == "," {
                i += 1
                skipWhitespace()
                if lenient, i < c.count, c[i] == "]" { i += 1; return .array(elements) }
                continue
            }
            if c[i] == "]" { i += 1; return .array(elements) }
            throw Failure.syntax(index: i, message: "expected ',' or ']'")
        }
    }

    /// Returns the raw source text including its quotes, so the preview shows
    /// the escapes the file actually contains rather than our re-encoding.
    private mutating func parseString() throws -> String {
        let start = i
        i += 1                                          // opening quote
        while i < c.count {
            let ch = c[i]
            if ch == "\\" {
                guard i + 1 < c.count else { break }
                let esc = c[i + 1]
                guard "\"\\/bfnrtu".contains(esc) else {
                    throw Failure.syntax(index: i, message: "invalid escape '\\\(esc)'")
                }
                if esc == "u" {
                    guard i + 5 < c.count, c[(i + 2)...(i + 5)].allSatisfy(\.isHexDigit) else {
                        throw Failure.syntax(index: i, message: "invalid \\u escape")
                    }
                    i += 6
                } else {
                    i += 2
                }
                continue
            }
            if ch == "\"" {
                i += 1
                return String(c[start..<i])
            }
            if ch.isNewline { throw Failure.syntax(index: i, message: "unterminated string") }
            i += 1
        }
        throw Failure.syntax(index: start, message: "unterminated string")
    }

    private mutating func parseNumber() throws -> String {
        let start = i
        if i < c.count, c[i] == "-" { i += 1 }
        while i < c.count, c[i].isNumber { i += 1 }
        if i < c.count, c[i] == "." {
            i += 1
            while i < c.count, c[i].isNumber { i += 1 }
        }
        if i < c.count, c[i] == "e" || c[i] == "E" {
            i += 1
            if i < c.count, c[i] == "+" || c[i] == "-" { i += 1 }
            while i < c.count, c[i].isNumber { i += 1 }
        }
        let text = String(c[start..<i])
        guard !text.isEmpty, Double(text) != nil else {
            throw Failure.syntax(index: start, message: "not a JSON value")
        }
        return text
    }

    private mutating func expect(_ word: String) throws {
        let end = i + word.count
        guard end <= c.count, String(c[i..<end]) == word else {
            throw Failure.syntax(index: i, message: "not a JSON value")
        }
        i = end
    }
}

/// Pretty-prints a parsed document. Shared by the JSON and JSONL previewers,
/// which differ only in `sortKeys`.
struct JSONWriter {

    let sortKeys: Bool
    let maxNodes: Int
    private(set) var truncated = false
    private var nodes = 0

    init(sortKeys: Bool, maxNodes: Int = 50_000) {
        self.sortKeys = sortKeys
        self.maxNodes = maxNodes
    }

    mutating func write(_ value: JSONValue, into out: NSMutableAttributedString, depth: Int = 0) {
        guard !truncated else { return }
        nodes += 1
        if nodes > maxNodes { truncated = true; out.t("\u{2026}", PreviewStyle.dim); return }

        let pad = String(repeating: "  ", count: depth + 1)
        let close = String(repeating: "  ", count: depth)

        switch value {
        case .object(let members):
            guard !members.isEmpty else { out.t("{}", PreviewStyle.punct); return }
            out.t("{\n", PreviewStyle.punct)
            let ordered = sortKeys ? members.sorted { $0.key < $1.key } : members
            for (n, member) in ordered.enumerated() {
                out.t(pad, PreviewStyle.punct)
                out.t(member.key, PreviewStyle.key)
                out.t(": ", PreviewStyle.punct)
                write(member.value, into: out, depth: depth + 1)
                out.t(n == ordered.count - 1 ? "\n" : ",\n", PreviewStyle.punct)
                if truncated { break }
            }
            out.t(close + "}", PreviewStyle.punct)

        case .array(let elements):
            guard !elements.isEmpty else { out.t("[]", PreviewStyle.punct); return }
            out.t("[\n", PreviewStyle.punct)
            for (n, element) in elements.enumerated() {
                out.t(pad, PreviewStyle.punct)
                write(element, into: out, depth: depth + 1)
                out.t(n == elements.count - 1 ? "\n" : ",\n", PreviewStyle.punct)
                if truncated { break }
            }
            out.t(close + "]", PreviewStyle.punct)

        case .string(let raw):  out.t(raw, PreviewStyle.string)
        case .number(let raw):  out.t(raw, PreviewStyle.number)
        case .bool(let flag):   out.t(flag ? "true" : "false", PreviewStyle.literal)
        case .null:             out.t("null", PreviewStyle.literal)
        }
    }
}
