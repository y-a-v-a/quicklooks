import AppKit

enum JSONLRenderer {

    enum Style {
        static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        static let key = NSColor.systemBlue
        static let string = NSColor.systemRed
        static let number = NSColor.systemPurple
        static let literal = NSColor.systemOrange
        static let punct = NSColor.secondaryLabelColor
        static let dim = NSColor.tertiaryLabelColor
        static let error = NSColor.systemRed
    }

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

            body.t("\u{2500}\u{2500} \(lineNo) ", Style.dim)
            body.t(String(repeating: "\u{2500}", count: 24) + "\n", Style.dim)

            if let object = try? JSONSerialization.jsonObject(with: Data(line), options: [.fragmentsAllowed]) {
                append(object, body, 0)
            } else {
                body.t("invalid JSON: ", Style.error)
                body.t(String(decoding: line.prefix(400), as: UTF8.self), Style.dim)
            }
            body.t("\n\n", Style.punct)
        }

        let header = NSMutableAttributedString()
        header.t(url.lastPathComponent, Style.punct)
        header.t("  \u{2022}  \(records) record\(records == 1 ? "" : "s")", Style.dim)
        if let totalBytes {
            header.t("  \u{2022}  \(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))", Style.dim)
        }
        header.t(truncated ? "  \u{2022}  truncated\n\n" : "\n\n", Style.dim)

        header.append(body)
        if truncated {
            header.t("\u{2026} remainder not shown\n", Style.dim)
        }
        return header
    }

    private static func append(_ value: Any, _ out: NSMutableAttributedString, _ depth: Int) {
        let pad = String(repeating: "  ", count: depth + 1)
        let close = String(repeating: "  ", count: depth)

        switch value {
        case let dict as [String: Any]:
            guard !dict.isEmpty else { out.t("{}", Style.punct); return }
            out.t("{\n", Style.punct)
            let keys = dict.keys.sorted()
            for (i, k) in keys.enumerated() {
                out.t(pad, Style.punct)
                out.t(quoted(k), Style.key)
                out.t(": ", Style.punct)
                append(dict[k] as Any, out, depth + 1)
                out.t(i == keys.count - 1 ? "\n" : ",\n", Style.punct)
            }
            out.t(close + "}", Style.punct)

        case let array as [Any]:
            guard !array.isEmpty else { out.t("[]", Style.punct); return }
            out.t("[\n", Style.punct)
            for (i, v) in array.enumerated() {
                out.t(pad, Style.punct)
                append(v, out, depth + 1)
                out.t(i == array.count - 1 ? "\n" : ",\n", Style.punct)
            }
            out.t(close + "]", Style.punct)

        case let s as String:
            out.t(quoted(s), Style.string)

        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                out.t(n.boolValue ? "true" : "false", Style.literal)
            } else {
                out.t(n.stringValue, Style.number)
            }

        case is NSNull:
            out.t("null", Style.literal)

        default:
            out.t("\(value)", Style.dim)
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

extension NSMutableAttributedString {
    func t(_ s: String, _ color: NSColor) {
        append(NSAttributedString(string: s, attributes: [
            .font: JSONLRenderer.Style.mono,
            .foregroundColor: color
        ]))
    }
}
