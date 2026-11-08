import AppKit

/// Feeds the folder list. Read-only: no selection, no sorting, no folding,
/// because a Quick Look panel is for a glance.
@MainActor
final class FolderTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    enum Column: String, CaseIterable {
        case name, date, size, kind

        var title: String {
            switch self {
            case .name: "Name"
            case .date: "Date Modified"
            case .size: "Size"
            case .kind: "Kind"
            }
        }
        var width: CGFloat {
            switch self {
            case .name: 300
            case .date: 150
            case .size: 80
            case .kind: 150
            }
        }
    }

    private(set) var items: [FolderItem]
    private var rows: [FolderRow] = []

    var showHidden = false {
        didSet { rows = FolderRow.rows(items, showHidden: showHidden) }
    }

    private let dates: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    init(items: [FolderItem]) {
        self.items = items
        rows = FolderRow.rows(items, showHidden: false)
    }

    /// Puts in subfolders whose contents have been read since.
    func update(_ opened: [Int: FolderItem]) {
        for (index, item) in opened { items[index] = item }
        rows = FolderRow.rows(items, showHidden: showHidden)
    }

    /// "0 bytes" rather than ByteCountFormatter's "Zero KB", as in Finder.
    static func format(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: bytes)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, let column = Column(rawValue: id.rawValue) else { return nil }
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? FolderCell
            ?? FolderCell(id, withIcon: column == .name, alignRight: column == .size)

        guard case let .item(item, depth) = rows[row] else {
            if case let .more(count) = rows[row], column == .name {
                cell.show("\u{2026} \(count.formatted()) more item\(count == 1 ? "" : "s")",
                          color: .tertiaryLabelColor, icon: nil, indent: 1)
            } else {
                cell.show("", color: .labelColor, icon: nil, indent: 0)
            }
            return cell
        }

        let dim = item.isHidden                     // hidden files, when shown, are dimmed
        switch column {
        case .name:
            cell.show(item.name, color: dim ? .tertiaryLabelColor : .labelColor,
                      icon: icon(for: item), indent: depth)
        case .date:
            cell.show(item.date.map(dates.string(from:)) ?? "--",
                      color: dim ? .tertiaryLabelColor : .secondaryLabelColor, icon: nil, indent: 0)
        case .size:
            cell.show(item.size.map(Self.format) ?? "--",
                      color: dim ? .tertiaryLabelColor : .secondaryLabelColor, icon: nil, indent: 0)
        case .kind:
            if item.problem != nil {
                cell.show("No access", color: .systemRed, icon: nil, indent: 0)
            } else {
                cell.show(item.kind, color: dim ? .tertiaryLabelColor : .secondaryLabelColor,
                          icon: nil, indent: 0)
            }
        }
        cell.toolTip = item.problem
        return cell
    }

    /// Dimmed by drawing, not by the cell's alphaValue: a translucent cell
    /// leaves the lazily drawn Finder icon blank.
    private func icon(for item: FolderItem) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        guard item.isHidden else { return icon }
        return NSImage(size: icon.size, flipped: false) { rect in
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.45)
            return true
        }
    }
}

/// A cell with an optional icon, indented by depth.
final class FolderCell: NSTableCellView {
    private let field = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private var lead: NSLayoutConstraint!

    init(_ id: NSUserInterfaceItemIdentifier, withIcon: Bool, alignRight: Bool) {
        super.init(frame: .zero)
        identifier = id
        field.lineBreakMode = .byTruncatingMiddle
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.alignment = alignRight ? .right : .left
        [field, iconView].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        textField = field
        imageView = iconView
        iconView.isHidden = !withIcon
        let iconSize: CGFloat = withIcon ? 18 : 0
        lead = iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        NSLayoutConstraint.activate([
            lead,
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),
            field.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: withIcon ? 6 : 0),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(_ text: String, color: NSColor, icon: NSImage?, indent: Int) {
        field.stringValue = text
        field.textColor = color
        iconView.image = icon
        lead.constant = 4 + CGFloat(indent) * 22
    }
}
