import AppKit
import CoreText

/// A WOFF or WOFF2 web font drawn in its own typeface: its name, the alphabet,
/// a size waterfall, every character it maps with its code point, and the
/// strings from its name table.
///
/// CoreText unpacks both formats itself and the font is never registered, so
/// it is only visible to this preview. Only characters the font maps are drawn
/// in it; anything else would be filled in from a system font, and a subset or
/// icon font would look more complete than it is.
enum FontRenderer {

    struct NotAWebFont: Error {}

    private static let alphabet = [
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
        "abcdefghijklmnopqrstuvwxyz",
        "0123456789",
        "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
    ]
    private static let pangram = "The quick brown fox jumps over the lazy dog"
    private static let waterfall: [CGFloat] = [12, 18, 24, 36, 48, 72]

    private static let names: [(String, CFString)] = [
        ("Copyright", kCTFontCopyrightNameKey),
        ("Trademark", kCTFontTrademarkNameKey),
        ("Version", kCTFontVersionNameKey),
        ("Designer", kCTFontDesignerNameKey),
        ("Manufacturer", kCTFontManufacturerNameKey),
        ("Description", kCTFontDescriptionNameKey),
        ("Designer URL", kCTFontDesignerURLNameKey),
        ("Vendor URL", kCTFontVendorURLNameKey),
        ("License", kCTFontLicenseNameKey),
        ("License URL", kCTFontLicenseURLNameKey),
        ("PostScript", kCTFontPostScriptNameKey)
    ]

    static func render(url: URL, maxBytes: Int = 64 << 20, maxListed: Int = 2000,
                       maxStyles: Int = 40) throws -> NSAttributedString {
        let size = fileSize(url) ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes) ?? Data()

        // WOFF and WOFF2 share the first 20 bytes: signature, sfnt flavor,
        // length, table count, reserved, and the unpacked sfnt size.
        var r = ByteReader(data, bigEndian: true)
        var facts: [String]
        switch try? r.u32() {
        case 0x774F_4632: facts = ["WOFF2"]
        case 0x774F_4646: facts = ["WOFF"]
        default: throw NotAWebFont()
        }
        let flavor = (try? r.u32()) ?? 0
        switch flavor {
        case 0x0001_0000, 0x7472_7565: facts.append("TrueType outlines")
        case 0x4F54_544F: facts.append("CFF outlines")
        case 0x7474_6366: facts.append("font collection")
        default: break
        }
        if (try? r.skip(8)) != nil, let unpacked = try? r.u32() { facts.append("\(formatBytes(unpacked)) unpacked") }

        let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor] ?? []
        // A variable font comes back as its default plus one descriptor per
        // named instance; the default is the one without variation values.
        let isDefault = { (d: CTFontDescriptor) in
            (CTFontDescriptorCopyAttribute(d, kCTFontVariationAttribute) as? [NSNumber: Any])?.isEmpty ?? true
        }
        guard let descriptor = descriptors.first(where: isDefault) ?? descriptors.first else {
            let out = reportHeader(url, size: size, facts)
            out.t(size > maxBytes ? "Larger than \(formatBytes(maxBytes)), not read.\n"
                                  : "macOS could not decode this font. It may be damaged or truncated.\n",
                  PreviewStyle.error)
            return out
        }
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        func sized(_ points: CGFloat) -> NSFont { CTFontCreateCopyWithAttributes(font, points, nil, nil) as NSFont }

        let charset = CTFontCopyCharacterSet(font) as CharacterSet
        var mapped = 0
        var shown: [Unicode.Scalar] = []
        for plane in 0...16 where charset.hasMember(inPlane: UInt8(plane)) {
            for value in plane << 16 ..< (plane + 1) << 16 {
                guard let s = Unicode.Scalar(value), charset.contains(s) else { continue }
                mapped += 1
                if isVisible(s) { shown.append(s) }
            }
        }
        func covers(_ text: String) -> Bool {
            text.unicodeScalars.allSatisfy { $0 == " " || charset.contains($0) }
        }

        if let version = name(font, kCTFontVersionNameKey) {
            facts.append(String(version.prefix { $0 != ";" }))
        }
        facts.append("\(CTFontGetGlyphCount(font).formatted()) glyphs")
        facts.append("\(mapped.formatted()) characters")
        let axes = variationAxes(font)
        if !axes.isEmpty {
            facts.append("variable: " + axes.map { "\($0.tag) \(plain($0.low))\u{2013}\(plain($0.high))" }.joined(separator: ", "))
        }
        if descriptors.count > 1 { facts.append("\(descriptors.count) \(flavor == 0x7474_6366 ? "fonts" : "styles")") }

        let out = reportHeader(url, size: size, facts)

        let title = name(font, kCTFontFullNameKey) ?? url.deletingPathExtension().lastPathComponent
        out.t(title + "\n", PreviewStyle.plain, covers(title) ? sized(32) : PreviewStyle.monoBold)
        out.t("\n", PreviewStyle.dim)

        var wroteAlphabet = false
        for row in alphabet {
            let present = String(row.unicodeScalars.filter(charset.contains).map(Character.init))
            guard !present.isEmpty else { continue }
            out.t(present, PreviewStyle.plain, sized(36))
            let missing = row.unicodeScalars.filter { !charset.contains($0) }
            if !missing.isEmpty {
                out.t("   missing " + missing.map(String.init).joined(separator: " "), PreviewStyle.dim)
            }
            out.t("\n", PreviewStyle.plain, sized(36))
            wroteAlphabet = true
        }
        if wroteAlphabet { out.t("\n", PreviewStyle.dim) }

        let sample = covers(pangram)
            ? pangram
            : shown.prefix(16).map(String.init).joined(separator: " ")
        if !sample.isEmpty {
            let start = out.length
            for points in waterfall {
                out.t("\(Int(points))\t", PreviewStyle.dim)
                out.t(sample + "\n", PreviewStyle.plain, sized(points))
            }
            out.addAttribute(.paragraphStyle, value: hanging(at: 36), range: NSRange(location: start, length: out.length - start))
            out.t("\n", PreviewStyle.dim)
        }

        if descriptors.count > 1 {
            out.t("Styles", PreviewStyle.punct, PreviewStyle.monoBold)
            out.t(descriptors.count > maxStyles
                  ? "  first \(maxStyles) of \(descriptors.count)\n"
                  : "  \(descriptors.count)\n", PreviewStyle.dim)
            for style in descriptors.prefix(maxStyles) {
                let face = CTFontCreateWithFontDescriptor(style, 24, nil)
                let faceSet = CTFontCopyCharacterSet(face) as CharacterSet
                let label = name(face, kCTFontFullNameKey) ?? "unnamed"
                let drawable = label.unicodeScalars.allSatisfy { $0 == " " || faceSet.contains($0) }
                out.t(label, PreviewStyle.plain, drawable ? face as NSFont : PreviewStyle.mono)
                let set = CTFontCopyVariation(face) as? [NSNumber: NSNumber] ?? [:]
                var values = axes.map { "\($0.tag) \(plain(set[NSNumber(value: $0.id)]?.doubleValue ?? $0.standard))" }
                if isDefault(style) { values.append("default") }
                out.t("   " + values.joined(separator: ", ") + "\n", PreviewStyle.dim)
            }
            out.t("\n", PreviewStyle.dim)
        }

        out.t("Characters", PreviewStyle.punct, PreviewStyle.monoBold)
        let listed = shown.prefix(maxListed)
        let hidden = mapped - shown.count
        var counts = shown.count > listed.count
            ? "  first \(listed.count.formatted()) of \(shown.count.formatted())"
            : "  \(shown.count.formatted())"
        if hidden > 0 { counts += ", and \(hidden.formatted()) invisible ones not shown" }
        out.t(counts + "\n", PreviewStyle.dim)
        let grid = NSMutableAttributedString()
        let glyphFont = sized(24)
        let dottedCircle = charset.contains("\u{25CC}")
        for s in listed {
            let category = s.properties.generalCategory
            let isMark = category == .nonspacingMark || category == .enclosingMark
            grid.t((isMark && dottedCircle ? "\u{25CC}" : "") + String(s), PreviewStyle.plain, glyphFont)
            // A word joiner keeps glyph and label together, and a zero-width
            // space after the tab lets every cell wrap, even one starting with
            // `.` or `)`, which line breaking would otherwise glue to the last.
            grid.t("\u{2060}\u{00A0}" + String(format: "U+%04X", s.value) + "\t\u{200B}", PreviewStyle.dim)
        }
        let cells = NSMutableParagraphStyle()
        cells.tabStops = []
        cells.defaultTabInterval = 104
        cells.lineSpacing = 6
        cells.baseWritingDirection = .leftToRight
        grid.addAttribute(.paragraphStyle, value: cells, range: NSRange(location: 0, length: grid.length))
        out.append(grid)
        out.t("\n\n", PreviewStyle.dim)

        let found = names.compactMap { label, key in name(font, key).map { (label, $0) } }
        if !found.isEmpty {
            out.t("Names\n", PreviewStyle.punct, PreviewStyle.monoBold)
            let start = out.length
            for (label, value) in found {
                out.t(label + "\t", PreviewStyle.punct)
                out.t(value + "\n", PreviewStyle.plain)
            }
            out.addAttribute(.paragraphStyle, value: hanging(at: 110), range: NSRange(location: start, length: out.length - start))
        }
        return out
    }

    private static func isVisible(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator: return false
        default: return true
        }
    }

    private static func name(_ font: CTFont, _ key: CFString) -> String? {
        guard let value = CTFontCopyName(font, key) as String? else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct Axis {
        let id: UInt32
        let low, high, standard: Double
        var tag: String { String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: id >> $0) }, encoding: .ascii) ?? "?" }
    }

    /// The variation axes in the font's own order; empty for a static font.
    private static func variationAxes(_ font: CTFont) -> [Axis] {
        let list = CTFontCopyVariationAxes(font) as? [[String: Any]] ?? []
        return list.map { axis in
            func value(_ key: CFString) -> NSNumber? { axis[key as String] as? NSNumber }
            return Axis(id: value(kCTFontVariationAxisIdentifierKey)?.uint32Value ?? 0,
                        low: value(kCTFontVariationAxisMinimumValueKey)?.doubleValue ?? 0,
                        high: value(kCTFontVariationAxisMaximumValueKey)?.doubleValue ?? 0,
                        standard: value(kCTFontVariationAxisDefaultValueKey)?.doubleValue ?? 0)
        }
    }

    /// Axis values without digit grouping, so a weight of 1000 never reads as `1.000`.
    private static func plain(_ value: Double) -> String {
        value.formatted(.number.grouping(.never))
    }

    /// A label, a tab to `indent`, and wrapped lines that stay under the text.
    private static func hanging(at indent: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        style.headIndent = indent
        return style
    }
}
