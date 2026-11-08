import Cocoa
import Quartz

/// A folder at a glance, like Finder's list view: icon, name and totals on
/// top, the contents in columns with each subfolder shown open one level
/// deep, the path at the bottom (click a folder in it to copy its path).
/// Not text, so it builds its own view instead of using TextPreviewController.
@MainActor
final class PreviewViewController: NSViewController, QLPreviewingController {

    private var table: FolderTable?
    private let list = NSTableView()
    private let subtitle = NSTextField(labelWithString: "")
    private var pending: [Int: FolderItem] = [:]   // opened, not yet shown
    private var done = false                        // every subfolder has been read
    private let hiddenToggle = PressCheckbox(checkboxWithTitle: "Show hidden files", target: nil, action: nil)

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 620))
        preferredContentSize = view.frame.size
    }

    /// The folder itself is read before the panel shows; its subfolders are
    /// read in the background and fill in as they arrive. On a cold iCloud
    /// folder that can take many seconds, which the panel should not wait for.
    func preparePreviewOfFile(at url: URL) async throws {
        let items = try FolderItem.contents(of: url)   // unreadable: Quick Look shows the error
        let table = FolderTable(items: items)
        self.table = table
        build(url, table)
        done = !items.contains { $0.isFolder }
        showSummary()
        openSubfolders(items)
    }

    private func openSubfolders(_ items: [FolderItem]) {
        let folders = items.indices.filter { items[$0].isFolder }
        guard !folders.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            DispatchQueue.concurrentPerform(iterations: folders.count) { n in
                let opened = items[folders[n]].opened()
                DispatchQueue.main.async { self?.arrived(opened, at: folders[n]) }
            }
            DispatchQueue.main.async { self?.done = true; self?.flush() }
        }
    }

    /// Collects arrivals and redraws at most five times a second.
    private func arrived(_ item: FolderItem, at index: Int) {
        let first = pending.isEmpty
        pending[index] = item
        if first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.flush() }
        }
    }

    private func flush() {
        if !pending.isEmpty {
            table?.update(pending)
            pending = [:]
            list.reloadData()
        }
        showSummary()
    }

    /// "23.86 GB · 115 items": the sizes the list shows, so one level deep,
    /// and every item in the folder, hidden ones included.
    private func showSummary() {
        let items = table?.items ?? []
        let total = FolderTable.format(items.reduce(Int64(0)) { $0 + ($1.size ?? 0) })
        let count = "\(items.count.formatted()) item\(items.count == 1 ? "" : "s")"
        subtitle.stringValue = done ? "\(total) \u{00B7} \(count)" : "\(count) \u{00B7} reading subfolders\u{2026}"
    }

    private func build(_ url: URL, _ table: FolderTable) {
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
        icon.imageScaling = .scaleProportionallyUpOrDown

        let title = NSTextField(labelWithString: url.lastPathComponent)
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor

        hiddenToggle.target = self
        hiddenToggle.action = #selector(toggleHidden)

        for column in FolderTable.Column.allCases {
            let c = NSTableColumn(identifier: .init(column.rawValue))
            c.title = column.title
            c.width = column.width
            c.minWidth = 50
            if column == .size { c.headerCell.alignment = .right }
            list.addTableColumn(c)
        }
        list.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        list.style = .inset
        list.usesAlternatingRowBackgroundColors = true
        list.selectionHighlightStyle = .none
        list.allowsColumnReordering = false
        list.rowHeight = 26
        list.dataSource = table
        list.delegate = table

        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let path = FolderPathBar(url: url)

        let views: [NSView] = [icon, title, subtitle, hiddenToggle, scroll, path]
        views.forEach { $0.translatesAutoresizingMaskIntoConstraints = false; view.addSubview($0) }
        let margin: CGFloat = 16
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: view.topAnchor, constant: margin),
            icon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.bottomAnchor.constraint(equalTo: icon.centerYAnchor, constant: 2),
            title.trailingAnchor.constraint(lessThanOrEqualTo: hiddenToggle.leadingAnchor, constant: -12),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: icon.centerYAnchor, constant: 4),

            hiddenToggle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            hiddenToggle.centerYAnchor.constraint(equalTo: icon.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: path.topAnchor, constant: -6),

            path.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            path.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            path.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10)
        ])
        list.reloadData()
    }

    @objc private func toggleHidden() {
        table?.showHidden = hiddenToggle.state == .on
        list.reloadData()
    }
}

/// A checkbox that switches on mouse down. Quick Look forwards a click's
/// mouse up to the extension only when the next event arrives, so a normal
/// NSButton, which waits for the mouse up, stayed pressed until the next
/// click and every second click seemed to do nothing.
final class PressCheckbox: NSButton {
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        setNextState()
        sendAction(action, to: target)
    }
}
