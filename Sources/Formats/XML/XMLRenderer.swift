import AppKit

/// Highlights XML: Spring and Maven configs, Hybris `*-items.xml`, XSD, XSLT,
/// Jasper reports, IntelliJ `.iml`.
///
/// Anything with a NUL in its first 8 KB is not text, whatever its extension
/// says, and is thrown back for the icon view.
enum XMLRenderer {

    struct NotText: Error {}

    private static let flavor = XMLHighlighter()

    static func render(url: URL, maxBytes: Int = 4 << 20, maxLines: Int = 5000) throws -> NSAttributedString {
        let totalBytes = fileSize(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: maxBytes) ?? Data()

        let isUTF16 = prefix.starts(with: [0xFF, 0xFE]) || prefix.starts(with: [0xFE, 0xFF])
        if !isUTF16, prefix.prefix(8192).contains(0) { throw NotText() }

        let source = XMLHighlighter.decode(prefix, truncated: (totalBytes ?? 0) > prefix.count, maxLines: maxLines)
        return flavor.document(url, source, totalBytes: totalBytes)
    }
}
