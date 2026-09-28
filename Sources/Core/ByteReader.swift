import AppKit

/// Reads fixed-width integers out of untrusted bytes. Every read is bounds
/// checked and throws `OutOfBounds` rather than trapping, so a truncated or
/// hostile file costs a preview, never the extension process.
struct ByteReader {

    struct OutOfBounds: Error {}

    let data: Data
    var offset: Int
    let bigEndian: Bool

    init(_ data: Data, at offset: Int = 0, bigEndian: Bool) {
        self.data = data
        self.offset = offset
        self.bigEndian = bigEndian
    }

    var remaining: Int { data.count - offset }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset >= 0, count <= data.count - offset else { throw OutOfBounds() }
        let start = data.startIndex + offset
        offset += count
        return data[start..<start + count]
    }

    mutating func skip(_ count: Int) throws { _ = try bytes(count) }

    mutating func u8() throws -> UInt8 { try bytes(1).first! }
    mutating func u16() throws -> Int { Int(try uint(2)) }
    mutating func u32() throws -> Int { Int(try uint(4)) }
    mutating func u64() throws -> UInt64 { try uint(8) }

    private mutating func uint(_ width: Int) throws -> UInt64 {
        let b = try bytes(width)
        let ordered = bigEndian ? Array(b) : b.reversed()
        return ordered.reduce(0) { $0 << 8 | UInt64($1) }
    }
}

extension FileHandle {
    /// At most `count` bytes from `offset`; fewer at the end of the file.
    func read(at offset: UInt64, upTo count: Int) throws -> Data {
        try seek(toOffset: offset)
        return try read(upToCount: count) ?? Data()
    }
}

/// Header line shared by the report-style previewers: name, size, and
/// whatever else they found out, separated by bullets.
func reportHeader(_ url: URL, size: Int?, _ facts: [String]) -> NSMutableAttributedString {
    let out = NSMutableAttributedString()
    out.t(url.lastPathComponent, PreviewStyle.punct)
    var all = facts
    if let size { all.insert(formatBytes(size), at: 0) }
    for fact in all where !fact.isEmpty { out.t("  \u{2022}  \(fact)", PreviewStyle.dim) }
    out.t("\n\n", PreviewStyle.dim)
    return out
}

func formatBytes<N: BinaryInteger>(_ n: N) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .file)
}

func fileSize(_ url: URL) -> Int? {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
}
