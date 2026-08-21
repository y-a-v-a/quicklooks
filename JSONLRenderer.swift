import AppKit

enum JSONLRenderer {

    /// Reads at most `maxBytes` and renders at most `maxRecords` records.
    /// Both caps matter: quicklookd kills previews that take too long.
    static func render(url: URL, maxBytes: Int = 4 << 20, maxRecords: Int = 300) throws -> NSAttributedString {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let totalBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        let partial = (totalBytes ?? 0) > data.count

        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if partial, !lines.isEmpty { lines.removeLast() } // trailing fragment

        let body = NSMutableAttributedString()
        var lineNo = 0
        var records = 0
        var truncated = partial

        for line in lines {
            lineNo += 1
            guard !line.isEmpty else { continue }
            if records >= maxRecords { truncated = true; break }
            records += 1

            body.t("\u{2500}\u{2500} \(lineNo) ", PreviewStyle.dim)
            body.t(String(repeating: "\u{2500}", count: 24) + "\n", PreviewStyle.dim)

            let text = String(decoding: line, as: UTF8.self)
            if let value = try? JSONParser.parse(text) {
                // Sorted, so diffing two previews by eye actually works. A
                // .json document keeps its own order instead — there the
                // author's ordering is the thing you recognise.
                var writer = JSONWriter(sortKeys: true)
                writer.write(value, into: body)
            } else {
                body.t("invalid JSON: ", PreviewStyle.error)
                body.t(String(text.prefix(400)), PreviewStyle.dim)
            }
            body.t("\n\n", PreviewStyle.punct)
        }

        let header = NSMutableAttributedString()
        header.t(url.lastPathComponent, PreviewStyle.punct)
        header.t("  \u{2022}  \(records) record\(records == 1 ? "" : "s")", PreviewStyle.dim)
        if let totalBytes {
            header.t("  \u{2022}  \(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))", PreviewStyle.dim)
        }
        header.t(truncated ? "  \u{2022}  truncated\n\n" : "\n\n", PreviewStyle.dim)

        header.append(body)
        if truncated {
            header.t("\u{2026} remainder not shown\n", PreviewStyle.dim)
        }
        return header
    }
}
