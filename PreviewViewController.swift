import Cocoa
import Quartz

@MainActor
final class PreviewViewController: NSViewController, QLPreviewingController {

    private let textView = NSTextView()
    private let scrollView = NSScrollView()

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 620))

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        view = container
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let rendered = try JSONLRenderer.render(url: url)
        textView.textStorage?.setAttributedString(rendered)
        textView.scroll(.zero)
    }
}
