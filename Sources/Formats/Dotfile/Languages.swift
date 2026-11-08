import Foundation

/// Language presets for PlainTextRenderer, beyond the generic ones it
/// defines itself. Shared by the dotfile previewer (whole files) and the
/// Markdown previewer (fenced code blocks).
extension PlainTextRenderer.Syntax {

    /// `"""` docstrings are taken as a block, so one spanning lines is
    /// coloured as a unit; `'''` ones are rare and stay per line.
    static let python = Self(
        lineComments: ["#"], blockComment: ("\"\"\"", "\"\"\""), quotes: ["\"", "'"],
        keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not",
                   "and", "or", "is", "import", "from", "as", "with", "try", "except", "finally",
                   "raise", "lambda", "yield", "pass", "break", "continue", "global", "nonlocal",
                   "None", "True", "False", "async", "await", "assert", "del", "match", "case",
                   "self", "cls"],
        stringPrefixes: ["f", "r", "b", "u", "F", "R", "B", "U"])

    /// Also covers the TypeScript words, for fenced `ts` blocks in Markdown.
    static let javascript = Self(
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"],
        keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while",
                   "do", "switch", "case", "default", "break", "continue", "new", "class",
                   "extends", "import", "export", "from", "as", "async", "await", "try", "catch",
                   "finally", "throw", "typeof", "instanceof", "in", "of", "this", "super",
                   "null", "undefined", "true", "false", "interface", "type", "enum",
                   "implements", "public", "private", "protected", "readonly", "yield", "void",
                   "delete", "static", "get", "set"],
        reflowsMinified: true)

    /// `$variables` use the shell rule; `#` comments only after a space,
    /// as everywhere here.
    static let php = Self(
        lineComments: ["//", "#"], blockComment: ("/*", "*/"), quotes: ["\"", "'", "`"],
        variables: true,
        keywords: ["function", "fn", "return", "if", "else", "elseif", "foreach", "for", "while",
                   "do", "switch", "case", "default", "break", "continue", "match", "new", "class",
                   "interface", "trait", "enum", "extends", "implements", "namespace", "use", "as",
                   "public", "private", "protected", "static", "final", "abstract", "readonly",
                   "const", "try", "catch", "finally", "throw", "echo", "print", "require",
                   "require_once", "include", "include_once", "array", "isset", "unset", "empty",
                   "null", "true", "false", "NULL", "TRUE", "FALSE", "instanceof", "yield",
                   "declare", "global", "list", "and", "or", "xor", "insteadof"])

    /// Keywords in upper and lower case, the two ways SQL is written.
    static let sql: Self = {
        let words = ["select", "from", "where", "and", "or", "not", "insert", "into", "values",
                     "update", "set", "delete", "create", "table", "drop", "alter", "add", "index",
                     "primary", "key", "foreign", "references", "join", "left", "right", "inner",
                     "outer", "on", "as", "group", "by", "order", "having", "limit", "offset",
                     "distinct", "null", "is", "in", "like", "between", "case", "when", "then",
                     "else", "end", "union", "all", "exists", "default", "unique", "view", "begin",
                     "commit", "rollback", "pragma", "with", "without", "rowid", "integer", "text",
                     "real", "blob", "check", "constraint", "virtual", "using", "trigger",
                     "if", "replace", "returning", "generated", "always", "stored", "autoincrement"]
        return Self(lineComments: ["--"], blockComment: ("/*", "*/"), quotes: ["'", "\""],
                      keywords: Set(words + words.map { $0.uppercased() }))
    }()
}
