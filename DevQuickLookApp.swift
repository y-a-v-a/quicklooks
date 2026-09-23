//
// Host app for the Quick Look preview extensions.
//
// It does nothing except exist: an app extension has to ship inside an app, and
// the UTI for .jsonl has to be declared by something the system knows about.
// Both of those are jobs for the bundle, not for this code.
//
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let text = NSTextField(wrappingLabelWithString: """
            Quick Look previewers installed.

            Select a .yaml, .toml, .json, .jsonl or Dockerfile in Finder and press space.

            This app has no other purpose — it hosts the preview extensions and \
            declares the JSON Lines file type. You can quit it now.
            """)
        text.font = .systemFont(ofSize: 13)
        text.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
        content.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            text.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            text.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])

        let window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dev Quick Look"
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
