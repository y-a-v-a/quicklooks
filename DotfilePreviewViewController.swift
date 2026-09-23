import Cocoa

@MainActor
final class PreviewViewController: TextPreviewController {
    override class func render(url: URL) throws -> NSAttributedString {
        try DotfileRenderer.render(url: url)
    }

    /// Extensionless SQLite files, like Chrome's `History`, land here too.
    override class func wrapsLines(for url: URL) -> Bool { !SQLiteRenderer.isSQLite(url) }
}
