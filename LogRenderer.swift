import AppKit

/// Log files, newest lines included.
///
/// A log grows at the end, so a file larger than `maxBytes` is read from the
/// tail: one seek, whatever its size. Lines are then numbered from the start
/// of what is shown, and the header says how much came before.
///
/// Colours levels, timestamps, exception names and stack frames. Binary
/// content under a `.log` name, like a database's write-ahead log, gets
/// metadata only.
enum LogRenderer {

    static func render(url: URL, maxBytes: Int = 1 << 20, maxLines: Int = 5000) throws -> NSAttributedString {
        let size = fileSize(url) ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let start = max(size - maxBytes, 0)
        var data = try handle.read(at: UInt64(start), upTo: maxBytes)

        if data.prefix(8192).filter({ $0 == 0 }).count > 16 {
            let out = reportHeader(url, size: size, ["binary content"])
            out.t("Not a text log, not shown.\n", PreviewStyle.dim)
            return out
        }

        var skippedBytes = start
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            skippedBytes += newline + 1 - data.startIndex
            data = data[(newline + 1)...]
        }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var droppedLines = 0
        if lines.count > maxLines {
            droppedLines = lines.count - maxLines
            lines = Array(lines.suffix(maxLines))
        }
        let tailed = skippedBytes > 0 || droppedLines > 0

        var facts: [String] = []
        facts.append(tailed ? "last \(lines.count.formatted()) lines" : "\(lines.count.formatted()) line\(lines.count == 1 ? "" : "s")")
        var counts: [Level: Int] = [:]
        let body = NSMutableAttributedString()
        let gutter = String(max(lines.count, 1)).count
        for (n, line) in lines.enumerated() {
            body.t(String(format: "%\(gutter)d  ", n + 1), PreviewStyle.dim)
            if let level = write(line, into: body) { counts[level, default: 0] += 1 }
            body.t("\n", PreviewStyle.punct)
        }
        if let e = counts[.error] { facts.append("\(e.formatted()) error\(e == 1 ? "" : "s")") }
        if let w = counts[.warning] { facts.append("\(w.formatted()) warning\(w == 1 ? "" : "s")") }

        let out = reportHeader(url, size: size, facts)
        if tailed {
            out.t("\u{2026} earlier lines not shown (\(formatBytes(skippedBytes)) before these)\n\n", PreviewStyle.dim)
        }
        out.append(body)
        return out
    }

    private enum Level { case error, warning, info, debug }

    private static let levels: [(Level, NSRegularExpression)] = ([
        (.error, #"\b(FATAL|CRITICAL|CRIT|SEVERE|ERROR|ERR|EMERG|ALERT|PANIC)\b"#),
        (.warning, #"\b(WARNING|WARN)\b"#),
        (.info, #"\b(INFO|NOTICE)\b"#),
        (.debug, #"\b(DEBUG|TRACE|FINE|FINER|FINEST|VERBOSE)\b"#)
    ] as [(Level, String)]).map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    private static let timestamp = try! NSRegularExpression(pattern:
        #"^\s*\[?(\d{4}[-/]\d{2}[-/]\d{2}[T ]\d{2}:\d{2}(:\d{2}([.,]\d+)?)?(Z|[+-]\d{2}:?\d{2}| ?[A-Z]{3,4})?|"#
        + #"[A-Z][a-z]{2} +\d{1,2} \d{2}:\d{2}:\d{2}|\d{2}:\d{2}:\d{2}([.,]\d+)?|"#
        + #"\d{2}/[A-Z][a-z]{2}/\d{4}:\d{2}:\d{2}:\d{2} [+-]\d{4})\]?"#)
    /// The Java Service Wrapper, which Hybris runs under, prefixes every line
    /// with its own `INFO   | jvm 1    | main    | 2026/09/22 15:49:53.318 | `,
    /// always INFO whatever the application logged after it.
    private static let wrapper = try! NSRegularExpression(pattern: #"^[A-Z]+\s*\| jvm \d+\s*\|[^|]*\|[^|]*\| ?"#)
    private static let exception = try! NSRegularExpression(pattern:
        #"\b([a-z_$][\w$]*\.)*[A-Z][\w$]*(Exception|Error|Throwable)\b"#)
    private static let frame = try! NSRegularExpression(pattern: #"^\s+(at |\.\.\. \d+ more)"#)
    private static let quoted = try! NSRegularExpression(pattern: #""[^"\n]{0,400}""#)

    /// Appends one coloured line; returns its level, if it names one.
    private static func write(_ line: String, into out: NSMutableAttributedString) -> Level? {
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let styled = NSMutableAttributedString(string: line, attributes: [
            .font: PreviewStyle.mono, .foregroundColor: PreviewStyle.plain
        ])
        func paint(_ r: NSRange, _ color: NSColor, bold: Bool = false) {
            styled.addAttribute(.foregroundColor, value: color, range: r)
            if bold { styled.addAttribute(.font, value: PreviewStyle.monoBold, range: r) }
        }

        let unwrapped = wrapper.firstMatch(in: line, range: whole).map {
            NSRange(location: $0.range.length, length: ns.length - $0.range.length)
        } ?? whole
        if frame.firstMatch(in: line, range: unwrapped) != nil {
            paint(whole, PreviewStyle.dim)
            paint(unwrapped, PreviewStyle.punct)
            out.append(styled)
            return nil
        }
        var rest = whole
        if let m = wrapper.firstMatch(in: line, range: whole) {
            paint(m.range, PreviewStyle.dim)
            rest = NSRange(location: m.range.length, length: ns.length - m.range.length)
        }
        quoted.enumerateMatches(in: line, range: whole) { m, _, _ in if let m { paint(m.range, PreviewStyle.string) } }
        exception.enumerateMatches(in: line, range: whole) { m, _, _ in if let m { paint(m.range, PreviewStyle.error) } }
        if let m = timestamp.firstMatch(in: line, range: rest) { paint(m.range, PreviewStyle.punct) }

        let head = NSRange(location: rest.location, length: min(rest.length, 200))
        let hit = levels
            .compactMap { level, regex in regex.firstMatch(in: line, range: head).map { (level, $0.range) } }
            .min { $0.1.location < $1.1.location }
        if let (level, range) = hit {
            switch level {
            case .error: paint(range, PreviewStyle.error, bold: true)
            case .warning: paint(range, PreviewStyle.literal, bold: true)
            case .info: paint(range, PreviewStyle.key)
            case .debug: paint(range, PreviewStyle.dim)
            }
        }
        out.append(styled)
        return hit?.0
    }
}
