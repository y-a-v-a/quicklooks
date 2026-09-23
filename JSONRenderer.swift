import AppKit

/// Whole-document JSON, pretty-printed in the file's own key order. A file
/// that turns out to be one record per line is handed to `JSONLRenderer`, and
/// one with comments or trailing commas to `JSONCRenderer`.
enum JSONRenderer {

    /// Reads at most `maxBytes`. Unlike JSONL there is no per-record cap: a
    /// JSON document is one value, so it parses whole or not at all.
    static func render(url: URL, maxBytes: Int = 4 << 20) throws -> NSAttributedString {
        switch url.pathExtension.lowercased() {
        case "jsonc": return try JSONCRenderer.render(url: url, dialect: .jsonc, maxBytes: maxBytes)
        case "json5": return try JSONCRenderer.render(url: url, dialect: .json5, maxBytes: maxBytes)
        default: break
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let totalBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        let clipped = (totalBytes ?? 0) > data.count
        let text = String(decoding: data, as: UTF8.self)

        let body = NSMutableAttributedString()
        var summary = ""
        var truncated = clipped

        if clipped {
            if let lines = JSONLRenderer.renderIfJSONL(data: data, url: url, totalBytes: totalBytes, partial: true) {
                return lines
            }
            // A clipped document cannot parse, so show it as text rather than
            // claiming it is broken.
            body.t("file is larger than \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)), showing raw text\n\n", PreviewStyle.error)
            body.t(text, PreviewStyle.dim)
        } else {
            do {
                let value = try JSONParser.parse(text)
                summary = describe(value)
                var writer = JSONWriter(sortKeys: false)
                writer.write(value, into: body)
                body.t("\n", PreviewStyle.punct)
                truncated = writer.truncated
            } catch let strict as JSONParser.Failure {
                if let lines = JSONLRenderer.renderIfJSONL(data: data, url: url, totalBytes: totalBytes, partial: false) {
                    return lines
                }
                // tsconfig.json and VS Code settings are JSONC behind a .json
                // name. Shown as written, since the comments are the point.
                var failure = strict
                do {
                    _ = try JSONParser.parse(text, lenient: true)
                    return JSONCRenderer.render(text: text, url: url, totalBytes: totalBytes,
                                                clipped: false, note: "read as JSON with comments")
                } catch let lenient as JSONParser.Failure {
                    // Whichever reading got further is the one the author meant.
                    if lenient.index > strict.index { failure = lenient }
                }
                let at = JSONParser.position(of: failure.index, in: text)
                body.t("invalid JSON at line \(at.line), column \(at.column): ", PreviewStyle.error)
                body.t("\(failure.message)\n\n", PreviewStyle.error)
                body.t(text, PreviewStyle.dim)     // still show the file
            }
        }

        let header = NSMutableAttributedString()
        header.t(url.lastPathComponent, PreviewStyle.punct)
        if !summary.isEmpty { header.t("  \u{2022}  \(summary)", PreviewStyle.dim) }
        if let totalBytes {
            header.t("  \u{2022}  \(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))", PreviewStyle.dim)
        }
        header.t(truncated ? "  \u{2022}  truncated\n\n" : "\n\n", PreviewStyle.dim)

        header.append(body)
        return header
    }

    /// Top-level shape, so the header says something useful before you scroll.
    private static func describe(_ value: JSONValue) -> String {
        switch value {
        case .object(let members):
            return "object, \(members.count) key\(members.count == 1 ? "" : "s")"
        case .array(let elements):
            return "array, \(elements.count) item\(elements.count == 1 ? "" : "s")"
        default:
            return "single value"
        }
    }
}
