import AppKit

/// Fenced code blocks, coloured by their language tag.
///
/// The colouring is PlainTextRenderer's shallow scanner (comments, strings,
/// numbers, keywords), given a keyword list per language here. Its colours
/// are made for a plain background, so they are swapped for a palette that
/// reads on the green code fill. An unknown or missing tag stays plain green.
enum MarkdownCode {

    typealias Syntax = PlainTextRenderer.Syntax

    static func highlight(_ code: String, language: String?) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        guard let syntax = syntax(for: language) else {
            out.append(NSAttributedString(string: code, attributes: [
                .font: MarkdownStyle.code, .foregroundColor: MarkdownStyle.codeText
            ]))
            return out
        }
        var inBlock = false
        for (n, line) in code.components(separatedBy: "\n").enumerated() {
            if n > 0 { out.t("\n", PreviewStyle.plain) }
            inBlock = PlainTextRenderer.scanLine(Array(line), syntax, inBlock: inBlock, into: out)
        }
        let whole = NSRange(location: 0, length: out.length)
        out.addAttribute(.font, value: MarkdownStyle.code, range: whole)
        out.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            guard let color = value as? NSColor else { return }
            let token = palette.first { $0.0 == color }
            out.addAttribute(.foregroundColor, value: token?.1 ?? MarkdownStyle.codeText, range: range)
            if color == PreviewStyle.literal { out.addAttribute(.font, value: MarkdownStyle.codeBold, range: range) }
        }
        return out
    }

    /// The scanner settings for a fence's language tag, if it is one we know.
    static func syntax(for language: String?) -> Syntax? {
        language.flatMap { syntaxes[$0.lowercased()] }
    }

    /// PreviewStyle colour as the scanner writes it -> colour on the green fill.
    private static let palette: [(NSColor, NSColor)] = [
        (PreviewStyle.comment, MarkdownStyle.codeComment),
        (PreviewStyle.string, MarkdownStyle.codeString),
        (PreviewStyle.literal, MarkdownStyle.codeKeyword),
        (PreviewStyle.number, MarkdownStyle.codeNumber),
        (PreviewStyle.key, MarkdownStyle.codeKey),
        (PreviewStyle.tag, MarkdownStyle.codeVariable)
    ]

    private static func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

    private static let cKeywords = "if else for while do switch case default break continue return goto struct "
        + "union enum typedef sizeof static const extern void int char short long float double unsigned signed "
        + "bool true false NULL nullptr class public private protected virtual new delete this namespace using "
        + "template typename try catch throw include define"

    private static let syntaxes: [String: Syntax] = {
        var map: [String: Syntax] = [:]
        func add(_ names: String, _ syntax: Syntax) { for n in words(names) { map[n] = syntax } }
        let cLike = Syntax.cLike
        func c(_ keywords: Set<String>) -> Syntax { var s = cLike; s.keywords = keywords; return s }

        add("swift", c(words("let var func if else guard return for in while repeat switch case default break "
            + "continue struct class enum protocol extension import init deinit self Self throws throw rethrows try "
            + "catch do async await static private public internal fileprivate open final override mutating some "
            + "any where nil true false defer as is typealias associatedtype inout lazy weak unowned get set willSet didSet")))
        add("js javascript jsx mjs cjs ts typescript tsx", c(words("const let var function return if else for "
            + "while do switch case default break continue new class extends import export from as async await try "
            + "catch finally throw typeof instanceof in of this super null undefined true false interface type enum "
            + "implements public private protected readonly yield void delete static get set")))
        add("go golang", c(words("func package import var const type struct interface map chan go defer return "
            + "if else for range switch case default break continue select fallthrough goto nil true false")))
        add("rust rs", c(words("fn let mut pub use mod struct enum impl trait for in if else match loop while "
            + "return self Self crate super where as const static ref move async await dyn unsafe type true false "
            + "Some None Ok Err")))
        add("java kotlin kt scala groovy dart cs csharp", c(words("class interface extends implements public "
            + "private protected internal static final abstract void return if else for while do new try catch "
            + "finally throw throws import package this super null true false enum switch case default break "
            + "continue fun val var when object is in as override data sealed namespace using")))
        add("c h cpp c++ cc hpp objc objective-c php", c(words(cKeywords)))
        add("css scss less", Syntax(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'"]))
        add("json jsonc json5", Syntax(lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""],
                                       keywords: words("true false null")))
        add("python py", .python)
        add("ruby rb", Syntax(lineComments: ["#"], quotes: ["\"", "'"], keywords: words("def end class module "
            + "if elsif else unless while until do return yield require nil true false self begin rescue ensure "
            + "then case when")))
        add("sh bash zsh shell console fish", Syntax.shell)
        add("yaml yml toml ini cfg conf properties env dotenv", Syntax.hash)
        add("dockerfile docker containerfile", Syntax(lineComments: ["#"], quotes: ["\"", "'"],
            keywords: words("FROM RUN CMD COPY ADD ENV ARG WORKDIR EXPOSE ENTRYPOINT USER VOLUME LABEL "
                + "HEALTHCHECK SHELL ONBUILD STOPSIGNAL AS")))
        add("sql mysql postgresql postgres sqlite plsql", .sql)
        add("html xml svg xhtml plist", Syntax(blockComment: ("<!--", "-->"), quotes: ["\"", "'"]))
        add("lua", Syntax(lineComments: ["--"], quotes: ["\"", "'"], keywords: words("local function end if "
            + "then else elseif for in do while repeat until return nil true false and or not")))
        return map
    }()
}
