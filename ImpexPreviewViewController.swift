import Cocoa

@MainActor
final class PreviewViewController: TextPreviewController {
    override class func render(url: URL) throws -> NSAttributedString {
        try ImpexRenderer.render(url: url)
    }

    override class func wrapsLines(for url: URL) -> Bool { false }
}
