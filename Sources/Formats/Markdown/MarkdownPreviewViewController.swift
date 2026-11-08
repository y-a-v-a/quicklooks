import Cocoa

/// Rendered Markdown, with a Preview/Source switch in the top-right corner.
/// Every file opens in Preview.
@MainActor
final class PreviewViewController: TextPreviewController {

    private enum Mode: Int { case preview, source }

    private let toggle = NSSegmentedControl(labels: ["Preview", "Source"], trackingMode: .selectOne,
                                            target: nil, action: nil)
    private var url: URL?
    private var rendered: [Mode: NSAttributedString] = [:]

    override class func render(url: URL) throws -> NSAttributedString {
        try MarkdownRenderer.render(url: url)
    }

    override class func makeLayoutManager() -> NSLayoutManager? { MarkdownLayoutManager() }

    override func loadView() {
        super.loadView()
        toggle.controlSize = .small
        toggle.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        toggle.selectedSegment = Mode.preview.rawValue
        toggle.target = self
        toggle.action = #selector(switchMode)
        toggle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toggle)
        NSLayoutConstraint.activate([
            toggle.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            toggle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)
        ])
    }

    override func preparePreviewOfFile(at url: URL) async throws {
        self.url = url
        display(try text(for: .preview))
    }

    @objc private func switchMode() {
        guard let chosen = Mode(rawValue: toggle.selectedSegment) else { return }
        do {
            display(try text(for: chosen))
        } catch {
            // Never a blank pane: say what went wrong where the text would be.
            let message = NSMutableAttributedString()
            message.t("Could not show \(chosen == .source ? "the source" : "the preview"): "
                      + error.localizedDescription + "\n", PreviewStyle.error)
            display(message)
        }
    }

    /// Each view is made once per file, on first use.
    private func text(for mode: Mode) throws -> NSAttributedString {
        if let cached = rendered[mode] { return cached }
        guard let url else { return NSAttributedString() }
        let text = mode == .preview
            ? try MarkdownRenderer.render(url: url)
            : try MarkdownSourceRenderer.render(url: url)
        rendered[mode] = text
        return text
    }
}
