import Cocoa
import Quartz

/// Scrolling monospace text view, shared by the previewers. Subclasses only
/// have to say how a file turns into an attributed string.
///
/// The view is built in `loadView()`, so no nib and no NSExtensionMainStoryboard
/// key in the extension's Info.plist.
@MainActor
class TextPreviewController: NSViewController, QLPreviewingController {

    private lazy var textView: NSTextView = {
        guard let layoutManager = type(of: self).makeLayoutManager() else { return NSTextView() }
        // A TextKit 1 stack built by hand. The text view does not retain
        // its storage, so the controller keeps it.
        let unbounded = CGFloat.greatestFiniteMagnitude
        let container = NSTextContainer(size: NSSize(width: 820, height: unbounded))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        customStorage.addLayoutManager(layoutManager)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 820, height: 620), textContainer: container)
        view.minSize = .zero
        view.maxSize = NSSize(width: unbounded, height: unbounded)
        return view
    }()
    private let customStorage = NSTextStorage()
    private let scrollView = NSScrollView()

    /// Override to draw with your own layout manager, like the Markdown
    /// previewer's rounded code backgrounds. Nil keeps the default view.
    class func makeLayoutManager() -> NSLayoutManager? { nil }

    /// Override. Runs off whatever thread Quick Look calls us on.
    class func render(url: URL) throws -> NSAttributedString {
        fatalError("subclass must override render(url:)")
    }

    /// Override to return false for output laid out in columns, like the
    /// SQLite row grids, which scroll sideways instead of wrapping.
    class func wrapsLines(for url: URL) -> Bool { true }

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
        display(try Self.render(url: url), wraps: Self.wrapsLines(for: url))
    }

    /// Shows `rendered` from the top. Subclasses can call it again to swap
    /// what is shown, like the Markdown previewer's Preview/Source switch.
    func display(_ rendered: NSAttributedString, wraps: Bool = true) {
        if !wraps {
            let unbounded = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.maxSize = unbounded
            textView.isHorizontallyResizable = true
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = unbounded
            scrollView.hasHorizontalScroller = true
        }
        textView.textStorage?.setAttributedString(rendered)
        textView.scroll(.zero)
    }
}
