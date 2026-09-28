import AppKit

/// Highlights property lists.
///
/// XML plists are shown as written. Binary (`bplist00`) and OpenStep plists
/// have no readable source, so they are decoded and re-encoded as XML first;
/// the header says so. Re-encoding does not keep the author's key order.
///
/// Text inside `<key>` is blue and inside `<string>` red, by the element it
/// sits in, which is what the plist flavor of `XMLHighlighter` adds.
enum PlistRenderer {

    struct UnreadablePlist: Error {}

    private static let flavor = XMLHighlighter(
        textColor: { element in
            switch element {
            case "key": return PreviewStyle.key
            case "string": return PreviewStyle.string
            case "integer", "real": return PreviewStyle.number
            case "date": return PreviewStyle.literal
            case "data": return PreviewStyle.dim
            default: return PreviewStyle.plain
            }
        },
        nameStyle: { name in
            name == "true" || name == "false"
                ? (PreviewStyle.literal, PreviewStyle.monoBold) : (PreviewStyle.tag, PreviewStyle.mono)
        },
        attributeColor: PreviewStyle.plain)

    /// Reads at most `maxBytes` of XML and renders at most `maxLines` lines.
    /// Binary and OpenStep plists must be decoded whole, up to `maxDecodeBytes`.
    static func render(url: URL, maxBytes: Int = 4 << 20, maxLines: Int = 5000,
                       maxDecodeBytes: Int = 16 << 20) throws -> NSAttributedString {
        let totalBytes = fileSize(url)

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: maxBytes) ?? Data()

        if !prefix.starts(with: Array("bplist".utf8)), looksLikeXML(prefix) {
            let source = XMLHighlighter.decode(prefix, truncated: (totalBytes ?? 0) > prefix.count, maxLines: maxLines)
            return flavor.document(url, source, totalBytes: totalBytes)
        }

        if let totalBytes, totalBytes > maxDecodeBytes {
            let out = reportHeader(url, size: totalBytes, [])
            out.t("Not an XML plist, and larger than \(formatBytes(maxDecodeBytes)), so not decoded.\n", PreviewStyle.dim)
            return out
        }
        try handle.seek(toOffset: 0)
        let whole = try handle.readToEnd() ?? Data()
        guard let (xml, format) = reencode(whole) else { throw UnreadablePlist() }
        let note: String
        switch format {
        case .binary: note = "binary, shown as XML"
        case .openStep: note = "OpenStep, shown as XML"
        default: note = "not UTF-8, re-encoded"
        }
        let source = XMLHighlighter.split(xml, truncated: false, maxLines: maxLines, note: note)
        return flavor.document(url, source, totalBytes: totalBytes)
    }

    /// UTF-8 XML starts with `<` after an optional BOM and whitespace. UTF-16
    /// XML does not, and goes through the decoder instead.
    private static func looksLikeXML(_ data: Data) -> Bool {
        var bytes = data.prefix(1024)[...]
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        return bytes.first { ![0x20, 0x09, 0x0A, 0x0D].contains($0) } == UInt8(ascii: "<")
    }

    private static func reencode(_ data: Data) -> (String, PropertyListSerialization.PropertyListFormat)? {
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let value = try? PropertyListSerialization.propertyList(from: data, format: &format),
              let xml = try? PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        else { return nil }
        return (String(decoding: xml, as: UTF8.self), format)
    }
}
