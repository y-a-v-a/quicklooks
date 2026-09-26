import Cocoa

@MainActor
final class PreviewViewController: TextPreviewController {
    override class func render(url: URL) throws -> NSAttributedString {
        try PlistRenderer.render(url: url)
    }
}
