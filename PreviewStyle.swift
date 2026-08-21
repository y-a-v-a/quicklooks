import AppKit

/// One palette for every previewer, so a .jsonl and a .yaml sitting next to
/// each other in Finder look like they came from the same tool.
enum PreviewStyle {
    static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let monoBold = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    static let key = NSColor.systemBlue
    static let string = NSColor.systemRed
    static let number = NSColor.systemPurple
    static let literal = NSColor.systemOrange
    static let tag = NSColor.systemTeal
    static let comment = NSColor.systemGreen
    static let punct = NSColor.secondaryLabelColor
    static let dim = NSColor.tertiaryLabelColor
    static let error = NSColor.systemRed
}

extension NSMutableAttributedString {
    func t(_ s: String, _ color: NSColor, _ font: NSFont = PreviewStyle.mono) {
        append(NSAttributedString(string: s, attributes: [
            .font: font,
            .foregroundColor: color
        ]))
    }
}
