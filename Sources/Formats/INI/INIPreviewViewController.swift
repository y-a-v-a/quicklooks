import Cocoa

@MainActor
final class PreviewViewController: TextPreviewController {
    override class func render(url: URL) throws -> NSAttributedString {
        try startsWithTag(url) ? XMLRenderer.render(url: url) : INIRenderer.render(url: url)
    }

    /// `.config` resolves to `public.toml`, but .NET's `web.config` and
    /// `app.config` are XML. An INI or TOML file never starts with `<`, so
    /// the first character after any byte order mark and whitespace decides.
    private static func startsWithTag(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 512) ?? Data()
        let isUTF16 = head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF])
        let text = isUTF16 ? (String(data: head, encoding: .utf16) ?? "") : String(decoding: head, as: UTF8.self)
        let first = text.first { !$0.isWhitespace && $0 != "\u{FEFF}" }
        return first == "<"
    }
}
