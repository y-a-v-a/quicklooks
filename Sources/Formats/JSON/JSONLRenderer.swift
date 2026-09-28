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

        return render(lines: lines(in: data, partial: partial), url: url,
                      totalBytes: totalBytes, partial: partial, maxRecords: maxRecords)
    }

    /// Second attempt for a `.json` file that did not parse as one document:
    /// log buffers and exports are often JSONL behind a .json extension. nil
    /// unless there are at least two records and every one parses, so a merely
    /// broken document keeps its line-and-column error.
    static func renderIfJSONL(data: Data, url: URL, totalBytes: Int?, partial: Bool,
                              maxRecords: Int = 300) -> NSAttributedString? {
        let lines = lines(in: data, partial: partial)
        let records = lines.filter { !$0.isEmpty }
        guard records.count >= 2,
              records.allSatisfy({ (try? JSONParser.parse(String(decoding: $0, as: UTF8.self))) != nil })
        else { return nil }

        return render(lines: lines, url: url, totalBytes: totalBytes, partial: partial,
                      maxRecords: maxRecords, note: "read as JSONL")
    }

    private static func lines(in data: Data, partial: Bool) -> [Data] {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if partial, !lines.isEmpty { lines.removeLast() } // trailing fragment
        return lines
    }

    private static func render(lines: [Data], url: URL, totalBytes: Int?, partial: Bool,
                               maxRecords: Int, note: String? = nil) -> NSAttributedString {
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
        if let note { header.t("  \u{2022}  \(note)", PreviewStyle.dim) }
        header.t(truncated ? "  \u{2022}  truncated\n\n" : "\n\n", PreviewStyle.dim)

        header.append(body)
        if truncated {
            header.t("\u{2026} remainder not shown\n", PreviewStyle.dim)
        }
        return header
    }
}
