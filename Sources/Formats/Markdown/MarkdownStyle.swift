import AppKit

/// Fonts, colours and block decorations for rendered Markdown. Proportional
/// body text, with code in the shared monospace face and green, so code reads
/// as code at a glance.
enum MarkdownStyle {

    static let bodySize: CGFloat = 16
    static let body = NSFont.systemFont(ofSize: bodySize)
    static let code = NSFont.monospacedSystemFont(ofSize: bodySize - 1, weight: .regular)
    static let codeBold = NSFont.monospacedSystemFont(ofSize: bodySize - 1, weight: .semibold)

    /// H1 to H6.
    static func heading(_ level: Int) -> NSFont {
        let sizes: [CGFloat] = [32, 26, 21, 18, 16, 15]
        return NSFont.systemFont(ofSize: sizes[min(max(level, 1), 6) - 1], weight: .bold)
    }

    static let text = NSColor.labelColor
    static let secondary = NSColor.secondaryLabelColor
    static let rule = NSColor.tertiaryLabelColor
    static let tableBorder = NSColor.separatorColor
    static let tableHeaderFill = NSColor.quaternaryLabelColor.withAlphaComponent(0.08)

    static let codeText = dynamic(light: (0.25, 0.45, 0.14), dark: (0.62, 0.86, 0.52))
    static let codeFill = dynamic(light: (0.85, 0.91, 0.80), dark: (0.16, 0.24, 0.15))
    static let frontMatterFill = dynamic(light: (0.93, 0.93, 0.93), dark: (0.18, 0.18, 0.18))

    /// Token colours inside a code block, chosen to read on `codeFill`.
    static let codeKeyword = dynamic(light: (0.55, 0.13, 0.55), dark: (0.88, 0.62, 0.96))
    static let codeString = dynamic(light: (0.70, 0.20, 0.13), dark: (0.98, 0.64, 0.52))
    static let codeComment = dynamic(light: (0.43, 0.49, 0.41), dark: (0.56, 0.63, 0.54))
    static let codeNumber = dynamic(light: (0.13, 0.30, 0.72), dark: (0.62, 0.76, 1.00))
    static let codeKey = dynamic(light: (0.07, 0.36, 0.60), dark: (0.56, 0.80, 1.00))
    static let codeVariable = dynamic(light: (0.00, 0.44, 0.48), dark: (0.46, 0.86, 0.86))

    /// Marks inline code, whose background MarkdownLayoutManager rounds.
    static let inlineCode = NSAttributedString.Key("MarkdownInlineCode")

    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }

    static func paragraph(indent: CGFloat = 0, hanging: CGFloat = 0, before: CGFloat = 0,
                          after: CGFloat = 14, lineSpacing: CGFloat = 5,
                          alignment: NSTextAlignment = .natural,
                          blocks: [NSTextBlock] = []) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = indent
        p.headIndent = indent + hanging
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        p.lineSpacing = lineSpacing
        p.alignment = alignment
        p.textBlocks = blocks
        if hanging > 0 { p.tabStops = [NSTextTab(textAlignment: .left, location: indent + hanging)] }
        return p
    }
}

/// A text block that draws its own background, since NSTextBlock only knows
/// square fills and solid borders: a rounded fill for code, a dotted rule
/// under H1 and H2, a solid bar left of a quote. Margins are left outside
/// the drawing, padding inside it.
final class MarkdownBlock: NSTextBlock {

    enum Decoration { case fill(NSColor), dottedRule, quoteBar }

    let decoration: Decoration

    init(_ decoration: Decoration, padding: CGFloat = 0, marginBelow: CGFloat = 0) {
        self.decoration = decoration
        super.init()
        // Without a width a bare NSTextBlock shrinks to nothing and stacks
        // its text one character per line.
        setValue(100, type: .percentageValueType, for: .width)
        if padding > 0 { setWidth(padding, type: .absoluteValueType, for: .padding) }
        if marginBelow > 0 { setWidth(marginBelow, type: .absoluteValueType, for: .margin, edge: .maxY) }
    }

    required init?(coder: NSCoder) { fatalError("not decoded") }

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView?,
                                 characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        // NSTextView is flipped, so maxY is the bottom edge.
        var r = frameRect
        r.size.height -= width(for: .margin, edge: .maxY)

        switch decoration {
        case .fill(let color):
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
        case .dottedRule:
            let path = NSBezierPath()
            path.move(to: NSPoint(x: r.minX, y: r.maxY - 1))
            path.line(to: NSPoint(x: r.maxX, y: r.maxY - 1))
            path.lineWidth = 2
            path.setLineDash([2, 3], count: 2, phase: 0)
            MarkdownStyle.rule.setStroke()
            path.stroke()
        case .quoteBar:
            MarkdownStyle.rule.setFill()
            NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY, width: 3, height: r.height),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

/// Draws the background of inline code as a rounded rectangle; AppKit only
/// fills square ones. Everything else, selection included, is left alone.
final class MarkdownLayoutManager: NSLayoutManager {

    /// A text view draws in strips and asks which glyphs fall inside each.
    /// A strip that only covers a block's padding has none of its glyphs, so
    /// the block's background was skipped there: cut-off corners and gaps.
    /// Looking this far past the strip always reaches a line of the block;
    /// it is more than any padding plus margin used here. Drawing is still
    /// clipped to the strip.
    private static let blockReach: CGFloat = 48

    override func glyphRange(forBoundingRect bounds: NSRect, in container: NSTextContainer) -> NSRange {
        super.glyphRange(forBoundingRect: bounds.insetBy(dx: 0, dy: -Self.blockReach), in: container)
    }

    override func glyphRange(forBoundingRectWithoutAdditionalLayout bounds: NSRect,
                             in container: NSTextContainer) -> NSRange {
        super.glyphRange(forBoundingRectWithoutAdditionalLayout: bounds.insetBy(dx: 0, dy: -Self.blockReach),
                         in: container)
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard let storage = textStorage, charRange.location < storage.length,
              storage.attribute(MarkdownStyle.inlineCode, at: charRange.location, effectiveRange: nil) != nil else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        // The line fragment includes the paragraph's line spacing below the
        // glyphs; leave it out so the text sits in the middle of the pill.
        let style = storage.attribute(.paragraphStyle, at: charRange.location, effectiveRange: nil) as? NSParagraphStyle
        let below = style?.lineSpacing ?? 0
        color.setFill()
        for i in 0..<rectCount {
            var r = rectArray[i]
            r.size.height -= below
            NSBezierPath(roundedRect: r.insetBy(dx: 0, dy: 0.5), xRadius: 5, yRadius: 5).fill()
        }
    }
}
