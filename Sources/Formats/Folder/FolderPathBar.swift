import AppKit

/// The path along the bottom. Clicking a folder in it copies that folder's
/// path, escaped for the shell as when a folder is dragged into Terminal,
/// and shows "Copied" next to it for a moment.
@MainActor
final class FolderPathBar: NSView {
    private let path = CopyPathControl()
    private let note = NSTextField(labelWithString: "Copied")

    init(url: URL) {
        super.init(frame: .zero)
        path.url = url
        path.pathStyle = .standard
        path.isEditable = false
        path.font = .systemFont(ofSize: 12)
        path.onCopy = { [weak self] in self?.flashNote() }
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.wantsLayer = true
        note.layer?.opacity = 0

        [path, note].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            path.leadingAnchor.constraint(equalTo: leadingAnchor),
            path.topAnchor.constraint(equalTo: topAnchor),
            path.bottomAnchor.constraint(equalTo: bottomAnchor),
            note.leadingAnchor.constraint(equalTo: path.trailingAnchor, constant: 8),
            note.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            note.centerYAnchor.constraint(equalTo: path.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Appears at once, stays a moment, fades out; a click in the meantime
    /// starts over. A Core Animation fade, because it runs in the render
    /// server: AppKit's animator() fade never showed in the Quick Look panel.
    private func flashNote() {
        guard let layer = note.layer else { return }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.6, 1]
        fade.duration = 2
        layer.removeAllAnimations()
        layer.opacity = 0                   // where it ends up when the fade is done
        layer.add(fade, forKey: "flash")
    }
}

/// Copies on mouse down: Quick Look delivers a click's mouse up late, so
/// the control's own click handling would act one click behind.
final class CopyPathControl: NSPathControl {
    var onCopy: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let cell = cell as? NSPathCell,
              let item = cell.pathComponentCell(at: point, withFrame: bounds, in: self),
              let url = item.url else { return }
        onCopy()                            // first: the pasteboard is a round trip to another process
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.shellEscaped(url.path), forType: .string)
    }

    /// `/Users/me/My Files` becomes `/Users/me/My\ Files`, as Terminal does
    /// for a dropped folder: every character outside a safe set gets a `\`.
    static func shellEscaped(_ path: String) -> String {
        let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+,:@%=")
        var out = ""
        for c in path {
            if !safe.contains(c) && c.isASCII { out.append("\\") }
            out.append(c)
        }
        return out
    }
}
