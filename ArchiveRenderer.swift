import AppKit
import Compression

/// Lists what is in a zip, jar, war, tar or tar.gz without unpacking it.
///
/// A zip keeps its table of contents, the central directory, at the end of the
/// file, so a listing costs one read however big the archive is. Entry data is
/// only touched for a jar's manifest and a few class-file headers.
///
/// A tar has no index: each member's header sits in front of its data. For a
/// plain tar the data is seeked past. Inside gzip it has to be decompressed
/// and thrown away, so a large .tar.gz is listed as far as `budget` allows,
/// and the header says the listing stopped, like SQLite's timed-out counts.
enum ArchiveRenderer {

    struct NotAnArchive: Error {}

    struct Entry {
        var path: String
        var size: UInt64
        var compressed: UInt64?
        var date: Date?
        var isDirectory = false
        var linkTarget: String?
        var encrypted = false
        var method = 0
        var dataOffset: UInt64 = 0
    }

    struct Listing {
        var format: String
        var entries: [Entry] = []
        var declaredCount: Int?
        var stopped: String?
        var comment: String?
    }

    static func render(url: URL, maxListed: Int = 1500, maxEntries: Int = 200_000,
                       budget: Double = 2.0) throws -> NSAttributedString {
        let deadline = CFAbsoluteTimeGetCurrent() + budget
        let size = fileSize(url) ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(at: 0, upTo: 512)

        if head.starts(with: [0x1F, 0x8B]) {
            return try renderGzip(url, handle, size: size, maxListed: maxListed,
                                  maxEntries: maxEntries, deadline: deadline)
        }
        if head.count == 512, Tar.isHeader(Array(head)) {
            var listing = Listing(format: "tar archive")
            Tar.list(FileSource(handle), into: &listing, maxEntries: maxEntries, deadline: deadline)
            return write(url, size: size, listing, maxListed: maxListed)
        }
        guard let listing = try Zip.list(handle, size: size, maxEntries: maxEntries, deadline: deadline) else {
            // Starts like a zip but has no table of contents: cut off mid-download.
            guard head.starts(with: [0x50, 0x4B, 3, 4]) else { throw NotAnArchive() }
            let out = reportHeader(url, size: size, ["zip archive", "incomplete"])
            out.t("The table of contents at the end of the file is missing, so the file is probably truncated.\n",
                  PreviewStyle.literal)
            return out
        }
        let java = ["jar", "war", "ear"].contains(url.pathExtension.lowercased())
            ? javaDetails(listing, handle) : nil
        return write(url, size: size, listing, maxListed: maxListed, java: java)
    }

    // MARK: - gzip

    private static func renderGzip(_ url: URL, _ handle: FileHandle, size: Int, maxListed: Int,
                                   maxEntries: Int, deadline: CFAbsoluteTime) throws -> NSAttributedString {
        guard let gz = try? GzipHeader(handle), let source = try? GzipSource(handle, from: gz.length) else {
            throw NotAnArchive()
        }
        let first = (try? source.read(512)) ?? Data()
        if first.count == 512, Tar.isHeader(Array(first)) {
            var listing = Listing(format: "tar.gz archive")
            source.unread(first)
            Tar.list(source, into: &listing, maxEntries: maxEntries, deadline: deadline)
            if listing.stopped != nil {
                listing.stopped! += ", after \(formatBytes(source.consumed)) of \(formatBytes(size)) compressed"
            }
            return write(url, size: size, listing, maxListed: maxListed)
        }

        // A single gzipped file: metadata, and its opening lines if it is text.
        let trailer = try handle.read(at: UInt64(max(size - 4, 0)), upTo: 4)
        var r = ByteReader(trailer, bigEndian: false)
        let isize = (try? r.u32()) ?? 0
        var sample = first
        if let more = try? source.read(64 << 10) { sample += more }
        var facts = ["gzip"]
        if let name = gz.originalName { facts.append("of \(name)") }
        // The trailer stores the size modulo 4 GiB, and deflate cannot shrink
        // data more than about 1032 to 1, so a bigger claim is garbage.
        if source.failed {
            facts.append("damaged or truncated")
        } else if size <= Int(UInt32.max), isize <= size * 1032 {
            facts.append("\(formatBytes(isize)) uncompressed")
        }
        let out = reportHeader(url, size: size, facts)
        if let date = gz.modified {
            out.t("compressed from a file dated \(date.formatted(date: .abbreviated, time: .shortened))\n\n",
                  PreviewStyle.dim)
        }
        if source.failed {
            out.t("The compressed data is damaged or cut off.\n", PreviewStyle.literal)
        } else if !sample.isEmpty, !sample.contains(0), let text = decodeText(sample) {
            section("CONTENT", into: out)
            var lines = text.components(separatedBy: "\n")
            let cut = lines.count > 200 || sample.count >= 64 << 10
            lines = Array(lines.prefix(200))
            if cut, lines.count > 1 { lines.removeLast() }
            let width = String(lines.count).count
            for (n, line) in lines.enumerated() {
                out.t(String(format: "%\(width)d  ", n + 1), PreviewStyle.dim)
                out.t(line.hasSuffix("\r") ? String(line.dropLast()) : line, PreviewStyle.plain)
                out.t("\n", PreviewStyle.punct)
            }
            if cut { out.t("\u{2026} remainder not shown\n", PreviewStyle.dim) }
        } else if !sample.isEmpty {
            out.t("binary content, not shown\n", PreviewStyle.dim)
        }
        return out
    }

    private static func decodeText(_ data: Data) -> String? {
        for cut in 0...min(3, data.count) {
            if let s = String(data: data.dropLast(cut), encoding: .utf8) { return s }
        }
        return nil
    }

    // MARK: - jar

    struct JavaDetails {
        var manifest: [(String, String)] = []
        var classVersion: (major: Int, sampled: Int)?
    }

    /// The manifest, and the newest class-file version among a handful of
    /// classes. Classes under META-INF/versions are skipped: a multi-release
    /// jar puts newer bytecode there on purpose.
    private static func javaDetails(_ listing: Listing, _ handle: FileHandle) -> JavaDetails {
        var details = JavaDetails()
        if let entry = listing.entries.first(where: { $0.path.uppercased() == "META-INF/MANIFEST.MF" }),
           let data = Zip.extract(entry, handle, maxBytes: 64 << 10) {
            details.manifest = parseManifest(String(decoding: data, as: UTF8.self))
        }
        let classes = listing.entries.lazy.filter {
            $0.path.hasSuffix(".class") && !$0.path.hasPrefix("META-INF/") && !$0.path.hasSuffix("module-info.class")
        }.prefix(5)
        var majors: [Int] = []
        for entry in classes {
            guard let data = Zip.extract(entry, handle, maxBytes: 1 << 20), data.count >= 8 else { continue }
            var r = ByteReader(data, bigEndian: true)
            guard (try? r.u32()) == 0xCAFEBABE, (try? r.u16()) != nil, let major = try? r.u16() else { continue }
            majors.append(major)
        }
        if let newest = majors.max() { details.classVersion = (newest, majors.count) }
        return details
    }

    /// `Key: value` lines; a line starting with one space continues the last.
    private static func parseManifest(_ text: String) -> [(String, String)] {
        var pairs: [(String, String)] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if raw.hasPrefix(" "), !pairs.isEmpty {
                pairs[pairs.count - 1].1 += raw.dropFirst()
            } else if let colon = raw.firstIndex(of: ":") {
                pairs.append((String(raw[..<colon]), raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
            }
            if pairs.count >= 60 { break }
        }
        return pairs
    }

    // MARK: - output

    private static func section(_ title: String, into out: NSMutableAttributedString) {
        out.t(title + "\n", PreviewStyle.punct, PreviewStyle.monoBold)
    }

    private static func write(_ url: URL, size: Int, _ listing: Listing, maxListed: Int,
                              java: JavaDetails? = nil) -> NSAttributedString {
        let files = listing.entries.filter { !$0.isDirectory }
        let folders = listing.entries.count - files.count
        let total = files.reduce(UInt64(0)) { $0 &+ $1.size }
        var facts = [listing.format, "\(files.count.formatted()) file\(files.count == 1 ? "" : "s")"]
        if folders > 0 { facts.append("\(folders.formatted()) folder\(folders == 1 ? "" : "s")") }
        facts.append("\(formatBytes(total)) unpacked")
        if listing.stopped != nil { facts.append("incomplete") }
        let out = reportHeader(url, size: size, facts)

        if let stopped = listing.stopped {
            out.t("Listing stopped: \(stopped).\n\n", PreviewStyle.literal)
        }
        if let java { writeJava(java, into: out) }
        writeTopLevel(listing.entries, into: out)
        writeEntries(listing.entries, maxListed: maxListed, into: out)
        if let comment = listing.comment, !comment.isEmpty {
            out.t("\n", PreviewStyle.punct)
            section("COMMENT", into: out)
            out.t(comment + "\n", PreviewStyle.comment)
        }
        return out
    }

    private static func writeJava(_ java: JavaDetails, into out: NSMutableAttributedString) {
        if let (major, sampled) = java.classVersion {
            section("BYTECODE", into: out)
            out.t("  \(ClassFileRenderer.javaVersion(major: major))", PreviewStyle.key)
            out.t("  newest of \(sampled) sampled class\(sampled == 1 ? "" : "es")\n\n", PreviewStyle.dim)
        }
        guard !java.manifest.isEmpty else { return }
        section("MANIFEST", into: out)
        let width = min(java.manifest.map(\.0.count).max() ?? 0, 32)
        for (key, value) in java.manifest {
            out.t("  " + key, PreviewStyle.key)
            out.t(String(repeating: " ", count: max(width - key.count, 0) + 2), PreviewStyle.punct)
            out.t((value.count > 300 ? String(value.prefix(300)) + "\u{2026}" : value) + "\n", PreviewStyle.plain)
        }
        out.t("\n", PreviewStyle.punct)
    }

    /// Where the bytes are, largest first. Only worth showing when the full
    /// listing is long enough to hide that.
    private static func writeTopLevel(_ entries: [Entry], into out: NSMutableAttributedString) {
        guard entries.count > 40 else { return }
        var groups: [String: (count: Int, size: UInt64)] = [:]
        for e in entries where !e.isDirectory {
            let parts = e.path.split(separator: "/", maxSplits: 1)
            let key = parts.count > 1 ? String(parts[0]) + "/" : String(parts.first ?? "")
            groups[key, default: (0, 0)].count += 1
            groups[key, default: (0, 0)].size &+= e.size
        }
        guard groups.count > 1 else { return }
        section("BY TOP-LEVEL ENTRY", into: out)
        let sorted = groups.sorted { $0.value.size > $1.value.size }
        for (name, g) in sorted.prefix(25) {
            let size = formatBytes(g.size)
            out.t(String(repeating: " ", count: max(12 - size.count, 0)) + size, PreviewStyle.number)
            let count = g.count.formatted()
            out.t(String(repeating: " ", count: max(10 - count.count, 2)) + count + "  ", PreviewStyle.dim)
            out.t(name + "\n", name.hasSuffix("/") ? PreviewStyle.tag : PreviewStyle.plain)
        }
        if sorted.count > 25 { out.t("  \u{2026} \(sorted.count - 25) more\n", PreviewStyle.dim) }
        out.t("\n", PreviewStyle.punct)
    }

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static func writeEntries(_ entries: [Entry], maxListed: Int, into out: NSMutableAttributedString) {
        guard !entries.isEmpty else {
            out.t("empty archive\n", PreviewStyle.dim)
            return
        }
        section("ENTRIES", into: out)
        let sorted = entries.sorted { $0.path < $1.path }
        for e in sorted.prefix(maxListed) {
            let size = e.isDirectory ? "" : formatBytes(e.size)
            out.t(String(repeating: " ", count: max(12 - size.count, 0)) + size, PreviewStyle.number)
            out.t("  " + (e.date.map { dateFormat.string(from: $0) } ?? String(repeating: " ", count: 16)) + "  ",
                  PreviewStyle.punct)
            out.t(e.path, e.isDirectory ? PreviewStyle.tag : PreviewStyle.plain)
            if let target = e.linkTarget { out.t(" \u{2192} " + target, PreviewStyle.dim) }
            if e.encrypted { out.t("  encrypted", PreviewStyle.literal) }
            out.t("\n", PreviewStyle.punct)
        }
        if sorted.count > maxListed {
            out.t("\u{2026} \((sorted.count - maxListed).formatted()) more not listed\n", PreviewStyle.dim)
        }
    }
}

// MARK: - zip

private enum Zip {

    static func list(_ handle: FileHandle, size: Int, maxEntries: Int,
                     deadline: CFAbsoluteTime) throws -> ArchiveRenderer.Listing? {
        guard size >= 22 else { return nil }
        let tailLength = min(size, 22 + 0xFFFF + 20)
        let tailStart = size - tailLength
        let tail = Array(try handle.read(at: UInt64(tailStart), upTo: tailLength))

        var at = tail.count - 22
        while at >= 0, !(tail[at] == 0x50 && tail[at + 1] == 0x4B && tail[at + 2] == 5 && tail[at + 3] == 6) {
            at -= 1
        }
        guard at >= 0 else { return nil }

        var r = ByteReader(Data(tail), at: at + 10, bigEndian: false)
        var count = UInt64(try r.u16())
        var cdSize = UInt64(try r.u32())
        var cdOffset = UInt64(try r.u32())
        let commentLength = try r.u16()
        let comment = (try? r.bytes(min(commentLength, r.remaining))).map { decodeName($0, utf8: false) }
        let eocd = UInt64(tailStart + at)

        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF, at >= 20 {
            var loc = ByteReader(Data(tail), at: at - 20, bigEndian: false)
            if try loc.u32() == 0x0706_4B50 {
                try loc.skip(4)
                let z64 = try handle.read(at: try loc.u64(), upTo: 56)
                var z = ByteReader(z64, bigEndian: false)
                if try z.u32() == 0x0606_4B50 {
                    try z.skip(28)
                    count = try z.u64()
                    cdSize = try z.u64()
                    cdOffset = try z.u64()
                }
            }
        }

        // Self-extracting archives and zips glued behind something else keep
        // offsets relative to where the zip started, not the file.
        if cdSize <= eocd, (try handle.read(at: cdOffset, upTo: 4)) != Data([0x50, 0x4B, 1, 2]) {
            cdOffset = eocd - cdSize
        }

        var listing = ArchiveRenderer.Listing(format: "zip archive")
        listing.declaredCount = Int(clamping: count)
        listing.comment = comment
        let cap: UInt64 = 64 << 20
        let directory = try handle.read(at: cdOffset, upTo: Int(min(cdSize, cap)))
        if cdSize > cap { listing.stopped = "central directory larger than \(formatBytes(cap))" }

        var d = ByteReader(directory, bigEndian: false)
        while listing.entries.count < Int(clamping: count) {
            if listing.entries.count >= maxEntries {
                listing.stopped = "more than \(maxEntries.formatted()) entries"
                break
            }
            if listing.entries.count % 1024 == 1023, CFAbsoluteTimeGetCurrent() > deadline {
                listing.stopped = "time limit reached"
                break
            }
            guard let entry = try? entry(&d) else {
                if listing.stopped == nil { listing.stopped = "central directory damaged" }
                break
            }
            listing.entries.append(entry)
        }
        return listing
    }

    private static func entry(_ d: inout ByteReader) throws -> ArchiveRenderer.Entry {
        guard try d.u32() == 0x0201_4B50 else { throw ByteReader.OutOfBounds() }
        let madeBy = try d.u16()
        try d.skip(2)
        let flags = try d.u16()
        let method = try d.u16()
        let time = try d.u16()
        let date = try d.u16()
        try d.skip(4)
        var compressed = UInt64(try d.u32())
        var size = UInt64(try d.u32())
        let nameLength = try d.u16()
        let extraLength = try d.u16()
        let commentLength = try d.u16()
        try d.skip(4)
        let external = try d.u32()
        var offset = UInt64(try d.u32())
        let path = decodeName(try d.bytes(nameLength), utf8: flags & 0x800 != 0)

        var extra = ByteReader(try d.bytes(extraLength), bigEndian: false)
        while extra.remaining >= 4 {
            let id = try extra.u16()
            let length = try extra.u16()
            var field = ByteReader(try extra.bytes(length), bigEndian: false)
            guard id == 0x0001 else { continue }
            if size == 0xFFFF_FFFF { size = try field.u64() }
            if compressed == 0xFFFF_FFFF { compressed = try field.u64() }
            if offset == 0xFFFF_FFFF { offset = try field.u64() }
        }
        try d.skip(commentLength)

        let unixMode = madeBy >> 8 == 3 ? external >> 16 : 0
        return ArchiveRenderer.Entry(
            path: path, size: size, compressed: compressed, date: dosDate(date, time),
            isDirectory: path.hasSuffix("/"),
            linkTarget: unixMode & 0xF000 == 0xA000 ? "symlink" : nil,
            encrypted: flags & 1 != 0, method: method, dataOffset: offset)
    }

    /// Names without the UTF-8 flag are officially code page 437. In practice
    /// many tools write UTF-8 without setting the flag, so that is tried first.
    static func decodeName(_ bytes: Data, utf8: Bool) -> String {
        if let s = String(data: bytes, encoding: .utf8) { return s }
        let cp437 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))
        return String(data: bytes, encoding: String.Encoding(rawValue: cp437)) ?? String(decoding: bytes, as: UTF8.self)
    }

    private static func dosDate(_ date: Int, _ time: Int) -> Date? {
        var c = DateComponents()
        c.year = (date >> 9) + 1980
        c.month = (date >> 5) & 0xF
        c.day = date & 0x1F
        c.hour = time >> 11
        c.minute = (time >> 5) & 0x3F
        c.second = (time & 0x1F) * 2
        guard (1...12).contains(c.month!), (1...31).contains(c.day!) else { return nil }
        return Calendar.current.date(from: c)
    }

    /// One entry's bytes, stored or deflated, if they are small enough.
    static func extract(_ e: ArchiveRenderer.Entry, _ handle: FileHandle, maxBytes: Int) -> Data? {
        guard !e.encrypted, let compressed = e.compressed, compressed <= 4 << 20,
              e.size <= UInt64(maxBytes), e.method == 0 || e.method == 8,
              let local = try? handle.read(at: e.dataOffset, upTo: 30), local.count == 30 else { return nil }
        var r = ByteReader(local, bigEndian: false)
        guard (try? r.u32()) == 0x0403_4B50, (try? r.skip(22)) != nil,
              let nameLength = try? r.u16(), let extraLength = try? r.u16(),
              let data = try? handle.read(at: e.dataOffset + 30 + UInt64(nameLength + extraLength),
                                          upTo: Int(compressed)),
              data.count == Int(compressed) else { return nil }
        if e.method == 0 { return data }
        guard e.size > 0 else { return Data() }

        var out = Data(count: Int(e.size))
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, Int(e.size),
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        return written > 0 ? out.prefix(written) : nil
    }
}

// MARK: - tar

/// Sequential bytes. A tar member's data is skipped, not read: a seek for a
/// plain file, decompress-and-discard for gzip.
private protocol ByteSource: AnyObject {
    func read(_ count: Int) throws -> Data
    func skip(_ count: UInt64) throws
}

private final class FileSource: ByteSource {
    let handle: FileHandle
    init(_ handle: FileHandle) {
        self.handle = handle
        try? handle.seek(toOffset: 0)
    }
    func read(_ count: Int) throws -> Data { try handle.read(upToCount: count) ?? Data() }
    func skip(_ count: UInt64) throws { try handle.seek(toOffset: try handle.offset() + count) }
}

private enum Tar {

    static func isHeader(_ b: [UInt8]) -> Bool {
        guard b.count >= 512, let stored = octal(b[148..<156]) else { return false }
        var sum: UInt64 = 0
        for (i, byte) in b.prefix(512).enumerated() { sum += (148..<156).contains(i) ? 32 : UInt64(byte) }
        return sum == stored && sum != 256
    }

    /// Octal text, or GNU's base-256 for sizes past 8 GB.
    static func octal(_ field: ArraySlice<UInt8>) -> UInt64? {
        if let first = field.first, first & 0x80 != 0 {
            return field.dropFirst().reduce(UInt64(first & 0x7F)) { $0 << 8 | UInt64($1) }
        }
        let digits = field.drop { $0 == 32 || $0 == 0 }.prefix { $0 >= 48 && $0 <= 55 }
        guard !digits.isEmpty else { return field.allSatisfy { $0 == 0 || $0 == 32 } ? 0 : nil }
        return digits.reduce(UInt64(0)) { $0 << 3 | UInt64($1 - 48) }
    }

    private static func string(_ field: ArraySlice<UInt8>) -> String {
        String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func list(_ source: ByteSource, into listing: inout ArchiveRenderer.Listing,
                     maxEntries: Int, deadline: CFAbsoluteTime) {
        var longName: String?
        var longLink: String?
        var paxPath: String?
        var paxLink: String?

        do {
            while true {
                if listing.entries.count >= maxEntries {
                    listing.stopped = "more than \(maxEntries.formatted()) entries"
                    return
                }
                if CFAbsoluteTimeGetCurrent() > deadline {
                    listing.stopped = "time limit reached"
                    return
                }
                let block = Array(try source.read(512))
                if block.isEmpty || block.allSatisfy({ $0 == 0 }) { return }
                guard block.count == 512, isHeader(block), let size = octal(block[124..<136]) else {
                    listing.stopped = "archive damaged or truncated"
                    return
                }
                let padded = (size + 511) / 512 * 512
                let type = block[156]

                switch type {
                case UInt8(ascii: "L"), UInt8(ascii: "K"), UInt8(ascii: "x"):
                    let body = try source.read(Int(min(size, 64 << 10)))
                    try source.skip(padded - UInt64(body.count))
                    let text = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
                    if type == UInt8(ascii: "L") { longName = text }
                    if type == UInt8(ascii: "K") { longLink = text }
                    if type == UInt8(ascii: "x") { (paxPath, paxLink) = pax(body) }
                    continue
                case UInt8(ascii: "g"):
                    try source.skip(padded)
                    continue
                default: break
                }

                var path = string(block[0..<100])
                if Array(block[257..<262]) == Array("ustar".utf8) {
                    let prefix = string(block[345..<500])
                    if !prefix.isEmpty { path = prefix + "/" + path }
                }
                path = paxPath ?? longName ?? path
                if path.hasPrefix("./") { path.removeFirst(2) }
                let isLink = type == UInt8(ascii: "1") || type == UInt8(ascii: "2")
                let target = isLink ? (paxLink ?? longLink ?? string(block[157..<257])) : nil
                longName = nil; longLink = nil; paxPath = nil; paxLink = nil

                let isDirectory = type == UInt8(ascii: "5") || path.hasSuffix("/")
                if !path.isEmpty, path != "." {
                    listing.entries.append(ArchiveRenderer.Entry(
                        path: path, size: isDirectory || isLink ? 0 : size,
                        date: octal(block[136..<148]).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                        isDirectory: isDirectory, linkTarget: target))
                }
                // Hard links and directories carry no data, whatever size says.
                if type != UInt8(ascii: "1"), type != UInt8(ascii: "2"), type != UInt8(ascii: "5") {
                    try source.skip(padded)
                }
            }
        } catch {
            listing.stopped = "archive damaged or truncated"
        }
    }

    /// `<length> path=<value>\n` records.
    private static func pax(_ body: Data) -> (String?, String?) {
        var path: String?
        var link: String?
        for record in String(decoding: body, as: UTF8.self).split(separator: "\n") {
            guard let space = record.firstIndex(of: " ") else { continue }
            let kv = record[record.index(after: space)...]
            if kv.hasPrefix("path=") { path = String(kv.dropFirst(5)) }
            if kv.hasPrefix("linkpath=") { link = String(kv.dropFirst(9)) }
        }
        return (path, link)
    }
}

// MARK: - gzip

private struct GzipHeader {
    let length: Int
    let originalName: String?
    let modified: Date?

    init(_ handle: FileHandle) throws {
        var r = ByteReader(try handle.read(at: 0, upTo: 64 << 10), bigEndian: false)
        guard try r.u16() == 0x8B1F, try r.u8() == 8 else { throw ByteReader.OutOfBounds() }
        let flags = try r.u8()
        let mtime = try r.u32()
        try r.skip(2)
        if flags & 4 != 0 { try r.skip(try r.u16()) }
        func cString() throws -> String {
            var bytes: [UInt8] = []
            var b = try r.u8()
            while b != 0 {
                bytes.append(b)
                b = try r.u8()
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        originalName = flags & 8 != 0 ? try cString() : nil
        if flags & 16 != 0 { _ = try cString() }
        if flags & 2 != 0 { try r.skip(2) }
        length = r.offset
        modified = mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(mtime)) : nil
    }
}

/// Inflates a gzip member as a stream. `consumed` is how much of the
/// compressed file has been read, for saying how far a listing got.
private final class GzipSource: ByteSource {

    struct Failed: Error {}

    private let handle: FileHandle
    private let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    private let input = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 << 10)
    private let output = UnsafeMutablePointer<UInt8>.allocate(capacity: 256 << 10)
    private var pending: [UInt8] = []
    private var head = 0
    private var inputDone = false
    private var finished = false
    private(set) var failed = false
    private(set) var consumed: UInt64

    init(_ handle: FileHandle, from offset: Int) throws {
        self.handle = handle
        consumed = UInt64(offset)
        try handle.seek(toOffset: UInt64(offset))
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            stream.deallocate(); input.deallocate(); output.deallocate()
            throw Failed()
        }
        stream.pointee.src_size = 0
    }

    deinit {
        compression_stream_destroy(stream)
        stream.deallocate()
        input.deallocate()
        output.deallocate()
    }

    private var available: Int { pending.count - head }

    private func fill() throws {
        if stream.pointee.src_size == 0, !inputDone {
            let chunk = try handle.read(upToCount: 64 << 10) ?? Data()
            chunk.copyBytes(to: input, count: chunk.count)
            stream.pointee.src_ptr = UnsafePointer(input)
            stream.pointee.src_size = chunk.count
            consumed += UInt64(chunk.count)
            inputDone = chunk.isEmpty
        }
        stream.pointee.dst_ptr = output
        stream.pointee.dst_size = 256 << 10
        let status = compression_stream_process(stream, inputDone ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
        let produced = (256 << 10) - stream.pointee.dst_size
        if head > 1 << 20 {
            pending.removeFirst(head)
            head = 0
        }
        pending.append(contentsOf: UnsafeBufferPointer(start: output, count: produced))
        switch status {
        case COMPRESSION_STATUS_END: finished = true
        case COMPRESSION_STATUS_ERROR:
            failed = true
            throw Failed()
        default:
            if produced == 0, inputDone {                              // input ran out before the end marker
                finished = true
                failed = true
            }
        }
    }

    func read(_ count: Int) throws -> Data {
        while available < count, !finished { try fill() }
        let n = min(count, available)
        defer { head += n }
        return Data(pending[head..<head + n])
    }

    func skip(_ count: UInt64) throws {
        var left = count
        while left > 0 {
            if available == 0 {
                if finished { throw Failed() }
                try fill()
                continue
            }
            let n = Int(min(UInt64(available), left))
            head += n
            left -= UInt64(n)
        }
    }

    /// Puts back bytes just read, so the tar lister can start at the top.
    func unread(_ data: Data) {
        head -= data.count
    }
}
