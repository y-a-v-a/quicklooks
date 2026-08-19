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

            if let object = try? JSONSerialization.jsonObject(with: Data(line), options: [.fragmentsAllowed]) {
                append(object, body, 0)
            } else {
                body.t("invalid JSON: ", PreviewStyle.error)
                body.t(String(decoding: line.prefix(400), as: UTF8.self), PreviewStyle.dim)
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

    private static func append(_ value: Any, _ out: NSMutableAttributedString, _ depth: Int) {
        let pad = String(repeating: "  ", count: depth + 1)
        let close = String(repeating: "  ", count: depth)

        switch value {
        case let dict as [String: Any]:
            guard !dict.isEmpty else { out.t("{}", PreviewStyle.punct); return }
            out.t("{\n", PreviewStyle.punct)
            let keys = dict.keys.sorted()
            for (i, k) in keys.enumerated() {
                out.t(pad, PreviewStyle.punct)
                out.t(quoted(k), PreviewStyle.key)
                out.t(": ", PreviewStyle.punct)
                append(dict[k] as Any, out, depth + 1)
                out.t(i == keys.count - 1 ? "\n" : ",\n", PreviewStyle.punct)
            }
            out.t(close + "}", PreviewStyle.punct)

        case let array as [Any]:
            guard !array.isEmpty else { out.t("[]", PreviewStyle.punct); return }
            out.t("[\n", PreviewStyle.punct)
            for (i, v) in array.enumerated() {
                out.t(pad, PreviewStyle.punct)
                append(v, out, depth + 1)
                out.t(i == array.count - 1 ? "\n" : ",\n", PreviewStyle.punct)
            }
            out.t(close + "]", PreviewStyle.punct)

        case let s as String:
            out.t(quoted(s), PreviewStyle.string)

        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                out.t(n.boolValue ? "true" : "false", PreviewStyle.literal)
            } else {
                out.t(n.stringValue, PreviewStyle.number)
            }

        case is NSNull:
            out.t("null", PreviewStyle.literal)

        default:
            out.t("\(value)", PreviewStyle.dim)
        }
    }

    private static func quoted(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(c)
            }
        }
        return out + "\""
    }
}
