import AppKit
import SQLite3

/// A SQLite database as a report: what wrote it, what is in it, and a few
/// rows of each table.
///
/// Everything here has to finish before quicklookd gives up on the preview,
/// and a `.sqlite` can be gigabytes. So the file header is read directly —
/// most of the metadata is in its first 100 bytes — and every query runs
/// under a deadline. A `count(*)` that runs out of time is reported as such,
/// not guessed.
enum SQLiteRenderer {

    struct NotSQLite: Error {}

    /// Detail for `maxDetailed` tables; the rest are named in the overview
    /// only. Row counts share `countBudget` seconds and everything shares
    /// `budget`, whatever the number of tables.
    static func render(url: URL, sampleRows: Int = 10, maxDetailed: Int = 20, maxColumns: Int = 24,
                       countBudget: Double = 1.0, budget: Double = 3.0) throws -> NSAttributedString {
        let start = CFAbsoluteTimeGetCurrent()
        func remaining(_ limit: Double) -> Double { limit - (CFAbsoluteTimeGetCurrent() - start) }

        let totalBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        // SQLite creates the file on open and writes nothing until the first
        // table, so a zero-byte .sqlite is a valid, empty database.
        if totalBytes == 0 {
            let out = NSMutableAttributedString()
            out.t(url.lastPathComponent, PreviewStyle.punct)
            out.t("  \u{2022}  empty database, no tables yet\n", PreviewStyle.dim)
            return out
        }
        guard let header = Header(url: url, fileSize: totalBytes) else { throw NotSQLite() }

        let out = NSMutableAttributedString()
        let body = NSMutableAttributedString()
        var summary = ""

        do {
            let db = try Connection(url: url)
            let schema = try db.schema()
            summary = describe(schema, shadows: shadowOwners(schema).count)

            let tables = schema.filter { $0.type == "table" && !$0.isInternal }
            let owners = shadowOwners(schema)
            let counts = tables.map { table -> Count in
                let left = remaining(countBudget)
                return left > 0 ? db.count(table.name, seconds: min(0.2, left)) : .skipped
            }

            writeOverview(tables, counts, owners: owners, into: body)
            let detailed = tables.indices.filter { owners[tables[$0].name] == nil }
            var shown = 0
            for n in detailed where shown < maxDetailed && remaining(budget) > 0 {
                writeTable(tables[n], count: counts[n], db: db, sampleRows: sampleRows,
                           maxColumns: maxColumns, seconds: min(0.25, remaining(budget)), into: body)
                shown += 1
            }
            if detailed.count > shown {
                let rest = detailed.count - shown
                body.t("\u{2026} \(rest) more table\(rest == 1 ? "" : "s") listed above, not shown in detail\n\n", PreviewStyle.dim)
            }
            writeSQL("VIEWS", schema.filter { $0.type == "view" }, into: body)
            writeSQL("TRIGGERS", schema.filter { $0.type == "trigger" }, into: body)
        } catch let failure as Connection.Failure {
            // Encrypted or damaged: the header still says something useful.
            body.t("cannot read the schema: \(failure.message)\n", PreviewStyle.error)
        }

        out.t(url.lastPathComponent, PreviewStyle.punct)
        if let totalBytes {
            out.t("  \u{2022}  \(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))", PreviewStyle.dim)
        }
        if !summary.isEmpty { out.t("  \u{2022}  \(summary)", PreviewStyle.dim) }
        out.t("\n\n", PreviewStyle.dim)
        header.write(into: out)
        out.t("\n", PreviewStyle.punct)
        out.append(body)
        return out
    }

    /// The first 16 bytes of every SQLite 3 database.
    static func isSQLite(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 16)) == Header.magic
    }

    // MARK: - header

    /// The 100-byte database header, read without SQLite. It is what the
    /// file says about itself, so it is shown even when the schema cannot be
    /// read — an encrypted database still has a page size.
    private struct Header {
        static let magic = Data("SQLite format 3\0".utf8)

        let pageSize: Int
        let pageCount: Int
        let freePages: Int
        let wal: Bool
        let encoding: String
        let userVersion: Int32
        let applicationID: UInt32
        let writtenBy: String?

        init?(url: URL, fileSize: Int?) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let d = try? handle.read(upToCount: 100), d.count == 100,
                  d.prefix(16) == Header.magic else { return nil }
            let b = [UInt8](d)

            func be16(_ o: Int) -> Int { Int(b[o]) << 8 | Int(b[o + 1]) }
            func be32(_ o: Int) -> UInt32 {
                UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])
            }

            pageSize = be16(16) == 1 ? 65536 : be16(16)
            guard pageSize >= 512 else { return nil }
            // The in-header page count is only trusted when the change counter
            // matches the version-valid-for number; older writers left it stale.
            let inHeader = Int(be32(28))
            pageCount = inHeader > 0 && be32(24) == be32(92) ? inHeader : (fileSize ?? 0) / pageSize
            freePages = Int(be32(36))
            wal = b[18] == 2 || b[19] == 2
            encoding = [1: "UTF-8", 2: "UTF-16le", 3: "UTF-16be"][be32(56)] ?? "UTF-8"
            userVersion = Int32(bitPattern: be32(60))
            applicationID = be32(68)
            let v = Int(be32(96))
            writtenBy = v > 3_000_000 ? "\(v / 1_000_000).\(v / 1000 % 1000).\(v % 1000)" : nil
        }

        func write(into out: NSMutableAttributedString) {
            var first = true
            func field(_ label: String, _ value: String, _ color: NSColor = PreviewStyle.plain) {
                out.t(first ? "" : "  \u{2022}  ", PreviewStyle.dim)
                first = false
                if !label.isEmpty { out.t(label + " ", PreviewStyle.dim) }
                out.t(value, color)
            }

            if let writtenBy { field("SQLite", writtenBy) }
            field("", encoding)
            field("", wal ? "WAL" : "rollback journal")
            field("pages", "\(pageCount.formatted()) \u{00D7} \(ByteCountFormatter.string(fromByteCount: Int64(pageSize), countStyle: .memory))", PreviewStyle.number)
            if freePages > 0 { field("free", freePages.formatted(), PreviewStyle.number) }
            out.t("\n", PreviewStyle.punct)

            // Both are 0 unless an application set them, and then they are
            // the most specific thing the file says about what it is.
            if userVersion != 0 || applicationID != 0 {
                first = true
                if userVersion != 0 { field("user_version", String(userVersion), PreviewStyle.number) }
                if applicationID != 0 { field("application_id", applicationName, PreviewStyle.tag) }
                out.t("\n", PreviewStyle.punct)
            }
            if wal {
                out.t("WAL mode: writes not yet checkpointed from the -wal file are not shown\n", PreviewStyle.dim)
            }
        }

        /// Registered ids from SQLite's own magic.txt, else the four bytes as
        /// text when they are printable — apps tend to pick a FourCC.
        private var applicationName: String {
            let known: [UInt32: String] = [
                0x0f05_5111: "Fossil repository", 0x0f05_5112: "Fossil checkout",
                0x0f05_5113: "Fossil global configuration", 0x4265_4462: "BeSQLite database",
                0x4265_4c6e: "Bentley localization file", 0x4750_4b47: "GeoPackage",
                0x4750_3130: "GeoPackage 1.0", 0x4750_3131: "GeoPackage 1.1",
                0x4573_7269: "Esri spatially-enabled database", 0x4d50_4258: "MBTiles tileset"
            ]
            let hex = "0x" + String(applicationID, radix: 16, uppercase: true)
            if let name = known[applicationID] { return "\(name) (\(hex))" }
            let bytes = (0..<4).map { UInt8(truncatingIfNeeded: applicationID >> (24 - 8 * $0)) }
            if bytes.allSatisfy({ (0x20...0x7e).contains($0) }) {
                return "'\(String(decoding: bytes, as: UTF8.self))' (\(hex))"
            }
            return hex
        }
    }

    // MARK: - connection

    struct SchemaEntry {
        let type: String
        let name: String
        let table: String
        let sql: String?

        /// `sqlite_sequence`, `sqlite_stat1` and friends.
        var isInternal: Bool { name.hasPrefix("sqlite_") }
    }

    enum Count {
        case exact(Int)
        case timedOut(maxRowid: Int?)
        case skipped                   // the shared counting budget ran out first
        case failed(String)
    }

    enum Cell {
        case null, integer(String), real(String), text(String), blob(Int)
    }

    /// A read-only handle with a deadline on every statement.
    ///
    /// Opened with `immutable=1`: the sandbox lets us read the file Quick Look
    /// hands over but not create the `-shm` next to it that a WAL database
    /// otherwise needs, and immutable skips locking and journals entirely.
    private final class Connection {

        struct Failure: Error { let message: String }

        private var db: OpaquePointer?
        private var deadline = CFAbsoluteTime.infinity

        init(url: URL) throws {
            var uri = URLComponents()
            uri.scheme = "file"
            uri.path = url.path                       // percent-encodes ?, # and spaces
            uri.queryItems = [URLQueryItem(name: "immutable", value: "1")]
            guard let string = uri.string else { throw Failure(message: "bad path") }

            let rc = sqlite3_open_v2(string, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            guard rc == SQLITE_OK else {
                let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
                sqlite3_close(db)
                db = nil
                throw Failure(message: message)
            }
            sqlite3_progress_handler(db, 1000, { context in
                let me = Unmanaged<Connection>.fromOpaque(context!).takeUnretainedValue()
                return CFAbsoluteTimeGetCurrent() > me.deadline ? 1 : 0
            }, Unmanaged.passUnretained(self).toOpaque())
        }

        deinit { sqlite3_close(db) }

        /// Steps `sql`, calling `row` until it returns false. Throws on error,
        /// including running past `seconds`.
        func query(_ sql: String, seconds: Double = 0.25,
                   _ row: (OpaquePointer) -> Bool = { _ in true }) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw Failure(message: String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            deadline = CFAbsoluteTimeGetCurrent() + seconds
            defer { deadline = .infinity }
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW: if !row(statement) { return }
                case SQLITE_DONE: return
                case SQLITE_INTERRUPT: throw Failure(message: "timed out")
                default: throw Failure(message: String(cString: sqlite3_errmsg(db)))
                }
            }
        }

        func schema() throws -> [SchemaEntry] {
            var entries: [SchemaEntry] = []
            // Reading sqlite_schema is the first real read, so a file that is
            // not a database after all (or is encrypted) fails here.
            try query("SELECT type, name, tbl_name, sql FROM sqlite_schema ORDER BY name", seconds: 1) { s in
                entries.append(SchemaEntry(type: text(s, 0) ?? "", name: text(s, 1) ?? "",
                                           table: text(s, 2) ?? "", sql: text(s, 3)))
                return true
            }
            return entries
        }

        /// `count(1)`, not `count(*)`: SQLite answers a bare `count(*)` with a
        /// single opcode that walks the whole b-tree without ever calling the
        /// progress handler, so no deadline can stop it on a large table.
        /// `count(1)` steps row by row and can be interrupted — and measured
        /// faster, too.
        func count(_ table: String, seconds: Double) -> Count {
            var n = 0
            do {
                try query("SELECT count(1) FROM \(quote(table))", seconds: seconds) { s in
                    n = Int(sqlite3_column_int64(s, 0))
                    return false
                }
                return .exact(n)
            } catch let failure as Failure where failure.message == "timed out" {
                // O(log n), and a fair hint at size unless rows were deleted.
                // Fails on WITHOUT ROWID tables, which is fine.
                var maxRowid: Int?
                try? query("SELECT max(rowid) FROM \(quote(table))", seconds: 0.05) { s in
                    if sqlite3_column_type(s, 0) != SQLITE_NULL { maxRowid = Int(sqlite3_column_int64(s, 0)) }
                    return false
                }
                return .timedOut(maxRowid: maxRowid)
            } catch let failure as Failure {
                return .failed(failure.message)
            } catch {
                return .failed("\(error)")
            }
        }
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard sqlite3_column_type(s, i) != SQLITE_NULL, let p = sqlite3_column_text(s, i) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: p, count: Int(sqlite3_column_bytes(s, i))),
                      as: UTF8.self)
    }

    private static func cell(_ s: OpaquePointer, _ i: Int32) -> Cell {
        switch sqlite3_column_type(s, i) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .integer(text(s, i) ?? "")
        case SQLITE_FLOAT: return .real(text(s, i) ?? "")
        case SQLITE_BLOB: return .blob(Int(sqlite3_column_bytes(s, i)))
        default: return .text(text(s, i) ?? "")
        }
    }

    private static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - sections

    /// Virtual tables keep their data in ordinary tables named after them —
    /// FTS5's `notes_data`, `notes_idx` and so on. Maps each of those to the
    /// virtual table that owns it, so they can be folded away.
    private static func shadowOwners(_ schema: [SchemaEntry]) -> [String: String] {
        let virtual = schema.filter {
            $0.type == "table" && $0.sql?.uppercased().hasPrefix("CREATE VIRTUAL TABLE") == true
        }.map(\.name)
        var owners: [String: String] = [:]
        for entry in schema where entry.type == "table" && !virtual.contains(entry.name) {
            if let owner = virtual.first(where: { entry.name.hasPrefix($0 + "_") }) {
                owners[entry.name] = owner
            }
        }
        return owners
    }

    private static func describe(_ schema: [SchemaEntry], shadows: Int) -> String {
        let parts: [(String, Int)] = [
            ("table", schema.filter { $0.type == "table" && !$0.isInternal }.count - shadows),
            ("view", schema.filter { $0.type == "view" }.count),
            ("index", schema.filter { $0.type == "index" }.count),
            ("trigger", schema.filter { $0.type == "trigger" }.count)
        ]
        return parts.filter { $0.1 > 0 || $0.0 == "table" }
            .map { "\($0.1) \($0.0 == "index" && $0.1 != 1 ? "indexes" : $0.0 + ($0.1 == 1 ? "" : "s"))" }
            .joined(separator: ", ")
    }

    private static func section(_ title: String, into out: NSMutableAttributedString) {
        out.t(title + "\n", PreviewStyle.punct, PreviewStyle.monoBold)
    }

    private static func writeOverview(_ tables: [SchemaEntry], _ counts: [Count], owners: [String: String],
                                      into out: NSMutableAttributedString) {
        guard !tables.isEmpty else {
            out.t("no tables\n", PreviewStyle.dim)
            return
        }
        section("TABLES", into: out)
        let width = min(tables.map(\.name.count).max() ?? 0, 48)
        let digits = counts.map { if case .exact(let n) = $0 { return n.formatted().count } else { return 0 } }.max() ?? 0
        for (table, count) in zip(tables, counts) {
            let name = clip(table.name, width)
            let owner = owners[table.name]
            out.t("  " + name, owner == nil ? PreviewStyle.key : PreviewStyle.dim)
            out.t(String(repeating: " ", count: width - name.count + 2), PreviewStyle.punct)
            if case .exact(let n) = count {                  // right-aligned, so magnitudes compare
                out.t(String(repeating: " ", count: digits - n.formatted().count), PreviewStyle.punct)
            }
            write(count, into: out)
            if let owner {
                out.t("  storage for \(owner)", PreviewStyle.dim)
            } else if let module = virtualModule(table) {
                out.t("  virtual, \(module)", PreviewStyle.dim)
            }
            out.t("\n", PreviewStyle.punct)
        }
        out.t("\n", PreviewStyle.punct)
    }

    private static func write(_ count: Count, into out: NSMutableAttributedString) {
        switch count {
        case .exact(let n):
            out.t(n.formatted(), PreviewStyle.number)
            out.t(n == 1 ? " row" : " rows", PreviewStyle.dim)
        case .timedOut(let maxRowid):
            out.t("too many rows to count quickly", PreviewStyle.dim)
            if let maxRowid {
                out.t(", max rowid ", PreviewStyle.dim)
                out.t(maxRowid.formatted(), PreviewStyle.number)
            }
        case .skipped:
            out.t("not counted", PreviewStyle.dim)
        case .failed(let message):
            out.t("unreadable: \(message)", PreviewStyle.error)
        }
    }

    /// `fts5`, `rtree`: the module after USING.
    private static func virtualModule(_ table: SchemaEntry) -> String? {
        guard let sql = table.sql, sql.uppercased().hasPrefix("CREATE VIRTUAL TABLE"),
              let using = sql.range(of: "USING", options: .caseInsensitive) else { return nil }
        let rest = sql[using.upperBound...].drop { $0 == " " }
        let module = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return module.isEmpty ? nil : String(module)
    }

    private static func writeTable(_ table: SchemaEntry, count: Count, db: Connection,
                                   sampleRows: Int, maxColumns: Int, seconds: Double,
                                   into out: NSMutableAttributedString) {
        let rule = String(repeating: "\u{2501}", count: max(4, 40 - table.name.count))
        out.t("\u{2501}\u{2501} ", PreviewStyle.dim)
        out.t(table.name, PreviewStyle.key, PreviewStyle.monoBold)
        out.t(" " + rule + "  ", PreviewStyle.dim)
        write(count, into: out)
        out.t("\n", PreviewStyle.punct)

        if let module = virtualModule(table) {
            out.t("  virtual table using \(module)\n", PreviewStyle.dim)
        }
        writeColumns(table.name, db: db, into: out)
        writeIndexes(table.name, db: db, into: out)
        out.t("\n", PreviewStyle.punct)

        if case .exact(0) = count { return }
        writeSample(table.name, db: db, rows: sampleRows, maxColumns: maxColumns, count: count,
                    seconds: seconds, into: out)
        out.t("\n", PreviewStyle.punct)
    }

    private struct Column {
        let name: String
        let type: String
        let notNull: Bool
        let defaultValue: String?
        let primaryKey: Int
        let hidden: Int
    }

    private static func writeColumns(_ table: String, db: Connection, into out: NSMutableAttributedString) {
        var columns: [Column] = []
        var references: [String: String] = [:]
        do {
            // table_xinfo also lists generated columns, flagged in `hidden`.
            try db.query("PRAGMA table_xinfo(\(quote(table)))") { s in
                columns.append(Column(name: text(s, 1) ?? "", type: text(s, 2) ?? "",
                                      notNull: sqlite3_column_int(s, 3) != 0, defaultValue: text(s, 4),
                                      primaryKey: Int(sqlite3_column_int(s, 5)),
                                      hidden: Int(sqlite3_column_int(s, 6))))
                return true
            }
            try db.query("PRAGMA foreign_key_list(\(quote(table)))") { s in
                let target = text(s, 2) ?? ""
                let to = text(s, 4).map { "(\($0))" } ?? ""
                references[text(s, 3) ?? ""] = target + to
                return true
            }
        } catch let failure as Connection.Failure {
            out.t("  columns unreadable: \(failure.message)\n", PreviewStyle.error)
            return
        } catch {
            return
        }
        // Virtual tables report their visible columns; hidden ones (1) are
        // FTS internals, 2 and 3 are generated columns worth showing.
        columns.removeAll { $0.hidden == 1 }

        let nameWidth = min(columns.map(\.name.count).max() ?? 0, 32)
        let typeWidth = min(columns.map(\.type.count).max() ?? 0, 24)
        for column in columns {
            let name = clip(column.name, nameWidth)
            out.t("  " + name + String(repeating: " ", count: nameWidth - name.count + 2), PreviewStyle.plain)
            let type = clip(column.type, typeWidth)
            out.t(type + String(repeating: " ", count: typeWidth - type.count), PreviewStyle.tag)

            var flags: [(String, NSColor)] = []
            if column.primaryKey > 0 { flags.append(("PK", PreviewStyle.literal)) }
            if column.notNull { flags.append(("NOT NULL", PreviewStyle.literal)) }
            if column.hidden >= 2 { flags.append(("GENERATED", PreviewStyle.literal)) }
            if let value = column.defaultValue { flags.append(("DEFAULT " + clip(value, 40), PreviewStyle.dim)) }
            if let target = references[column.name] { flags.append(("\u{2192} " + target, PreviewStyle.key)) }
            for (flag, color) in flags {
                out.t("  ", PreviewStyle.punct)
                out.t(flag, color)
            }
            out.t("\n", PreviewStyle.punct)
        }
    }

    /// Named indexes and the implicit ones behind UNIQUE and PRIMARY KEY, so
    /// a constraint shows up even though it has no CREATE INDEX of its own.
    private static func writeIndexes(_ table: String, db: Connection, into out: NSMutableAttributedString) {
        var indexes: [(name: String, unique: Bool, origin: String, partial: Bool)] = []
        try? db.query("PRAGMA index_list(\(quote(table)))") { s in
            indexes.append((text(s, 1) ?? "", sqlite3_column_int(s, 2) != 0,
                            text(s, 3) ?? "c", sqlite3_column_int(s, 4) != 0))
            return true
        }
        for index in indexes.reversed() {
            var columns: [String] = []
            try? db.query("PRAGMA index_info(\(quote(index.name)))") { s in
                columns.append(text(s, 2) ?? "<expr>")
                return true
            }
            out.t("  index ", PreviewStyle.dim)
            let label = index.origin == "c" ? index.name : index.origin == "pk" ? "primary key" : "unique constraint"
            out.t(label, index.origin == "c" ? PreviewStyle.plain : PreviewStyle.dim)
            if index.unique, index.origin == "c" { out.t(" UNIQUE", PreviewStyle.literal) }
            out.t(" (" + columns.joined(separator: ", ") + ")", PreviewStyle.punct)
            if index.partial { out.t(" WHERE \u{2026}", PreviewStyle.dim) }
            out.t("\n", PreviewStyle.punct)
        }
    }

    private static func writeSample(_ table: String, db: Connection, rows limit: Int, maxColumns: Int,
                                    count: Count, seconds: Double, into out: NSMutableAttributedString) {
        var headers: [String] = []
        var rows: [[Cell]] = []
        var totalColumns = 0
        do {
            try db.query("SELECT * FROM \(quote(table)) LIMIT \(limit)", seconds: seconds) { s in
                if headers.isEmpty {
                    totalColumns = Int(sqlite3_column_count(s))
                    headers = (0..<Int32(min(totalColumns, maxColumns))).map {
                        sqlite3_column_name(s, $0).map { String(cString: $0) } ?? ""
                    }
                }
                rows.append((0..<Int32(headers.count)).map { cell(s, $0) })
                return true
            }
        } catch let failure as Connection.Failure {
            out.t("  rows unreadable: \(failure.message)\n", PreviewStyle.error)
            return
        } catch {
            return
        }
        guard !headers.isEmpty else { return }

        let shown = rows.map { $0.map(display) }
        let widths = headers.indices.map { c in
            max(width(of: clip(headers[c], 40)), shown.map { width(of: $0[c].text) }.max() ?? 0)
        }
        let separator = " \u{2502} "

        out.t("  ", PreviewStyle.punct)
        for (c, header) in headers.enumerated() {
            if c > 0 { out.t(separator, PreviewStyle.dim) }
            let h = clip(header, 40)
            out.t(h + String(repeating: " ", count: widths[c] - width(of: h)), PreviewStyle.key, PreviewStyle.monoBold)
        }
        out.t("\n  " + widths.map { String(repeating: "\u{2500}", count: $0) }
            .joined(separator: "\u{2500}\u{253C}\u{2500}") + "\n", PreviewStyle.dim)

        for row in shown {
            out.t("  ", PreviewStyle.punct)
            for (c, value) in row.enumerated() {
                if c > 0 { out.t(separator, PreviewStyle.dim) }
                let pad = String(repeating: " ", count: widths[c] - width(of: value.text))
                out.t(value.rightAligned ? pad + value.text : value.text + pad, value.color)
            }
            out.t("\n", PreviewStyle.punct)
        }

        var notes: [String] = []
        if case .exact(let n) = count {
            if n > rows.count {
                notes.append("\((n - rows.count).formatted()) more row\(n - rows.count == 1 ? "" : "s")")
            }
        } else if rows.count == limit {
            notes.append("more rows")
        }
        if totalColumns > headers.count {
            notes.append("\(totalColumns - headers.count) more column\(totalColumns - headers.count == 1 ? "" : "s")")
        }
        if !notes.isEmpty {
            out.t("  \u{2026} " + notes.joined(separator: ", ") + "\n", PreviewStyle.dim)
        }
    }

    private static func display(_ cell: Cell) -> (text: String, color: NSColor, rightAligned: Bool) {
        switch cell {
        case .null: return ("NULL", PreviewStyle.dim, false)
        case .integer(let v): return (clip(v, 40), PreviewStyle.number, true)
        case .real(let v): return (clip(v, 40), PreviewStyle.number, true)
        case .blob(0):
            return ("<empty blob>", PreviewStyle.dim, false)
        case .blob(let bytes):
            return ("<blob \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory))>",
                    PreviewStyle.dim, false)
        case .text(let v):
            // One cell, one line: newlines and tabs would break the grid.
            let flat = v.replacingOccurrences(of: "\r\n", with: "\u{21B5}")
                .replacingOccurrences(of: "\n", with: "\u{21B5}")
                .replacingOccurrences(of: "\r", with: "\u{21B5}")
                .replacingOccurrences(of: "\t", with: " ")
            return (clip(flat, 40), PreviewStyle.string, false)
        }
    }

    /// Columns a string takes in a monospaced font: East Asian wide
    /// characters and emoji take two, so a grid of Japanese names still lines
    /// up. Combining marks are already folded into their Character.
    private static func width(of s: String) -> Int {
        s.reduce(0) { total, ch in
            guard let v = ch.unicodeScalars.first?.value else { return total }
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v)
                || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v)
                || (0xFE30...0xFE4F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1F64F).contains(v)
                || (0x1F900...0x1F9FF).contains(v) || (0x20000...0x3FFFD).contains(v)
            return total + (wide ? 2 : 1)
        }
    }

    private static func clip(_ s: String, _ width: Int) -> String {
        s.count <= width ? s : String(s.prefix(max(width - 1, 0))) + "\u{2026}"
    }

    private static func writeSQL(_ title: String, _ entries: [SchemaEntry], into out: NSMutableAttributedString) {
        guard !entries.isEmpty else { return }
        section(title, into: out)
        for entry in entries {
            SQLHighlighter.write(entry.sql ?? "-- \(entry.name): no SQL recorded", into: out)
            out.t("\n\n", PreviewStyle.punct)
        }
    }
}

/// Just enough SQL colouring for CREATE VIEW and CREATE TRIGGER bodies.
enum SQLHighlighter {

    private static let keywords: Set<String> = [
        "ABORT", "ACTION", "AFTER", "ALL", "ALWAYS", "AND", "AS", "ASC", "AUTOINCREMENT", "BEFORE",
        "BEGIN", "BETWEEN", "BY", "CASCADE", "CASE", "CAST", "CHECK", "COLLATE", "CONFLICT",
        "CREATE", "CROSS", "DEFAULT", "DELETE", "DESC", "DISTINCT", "EACH", "ELSE", "END", "EXCEPT",
        "EXISTS", "FOR", "FOREIGN", "FROM", "FULL", "GENERATED", "GLOB", "GROUP", "HAVING", "IF", "IN",
        "INDEX", "INNER", "INSERT", "INSTEAD", "INTERSECT", "INTO", "IS", "JOIN", "KEY", "LEFT",
        "LIKE", "LIMIT", "NEW", "NO", "NOT", "NULL", "OF", "OFFSET", "OLD", "ON", "OR", "ORDER",
        "OUTER", "OVER", "PARTITION", "PRIMARY", "RAISE", "RECURSIVE", "REFERENCES", "REPLACE",
        "RESTRICT", "RETURNING", "RIGHT", "ROW", "ROWID", "SELECT", "SET", "STORED", "STRICT",
        "TABLE", "TEMP", "TEMPORARY", "THEN", "TRIGGER", "UNION", "UNIQUE", "UPDATE", "USING",
        "VALUES", "VIEW", "VIRTUAL", "WHEN", "WHERE", "WINDOW", "WITH", "WITHOUT"
    ]

    static func write(_ sql: String, into out: NSMutableAttributedString) {
        let c = Array(sql)
        var i = 0
        while i < c.count {
            let ch = c[i]
            var j = i + 1

            if ch == "-", j < c.count, c[j] == "-" {
                while j < c.count, !c[j].isNewline { j += 1 }
                out.t(String(c[i..<j]), PreviewStyle.comment)
            } else if ch == "/", j < c.count, c[j] == "*" {
                j += 1
                while j + 1 < c.count, !(c[j] == "*" && c[j + 1] == "/") { j += 1 }
                j = min(j + 2, c.count)
                out.t(String(c[i..<j]), PreviewStyle.comment)
            } else if ch == "'" || ch == "\"" || ch == "`" || ch == "[" {
                // Doubled quotes escape; [identifiers] close on ].
                let close: Character = ch == "[" ? "]" : ch
                while j < c.count {
                    if c[j] == close {
                        if close != "]", j + 1 < c.count, c[j + 1] == close { j += 2; continue }
                        j += 1
                        break
                    }
                    j += 1
                }
                out.t(String(c[i..<j]), ch == "'" ? PreviewStyle.string : PreviewStyle.plain)
            } else if ch.isLetter || ch == "_" {
                while j < c.count, c[j].isLetter || c[j].isNumber || c[j] == "_" || c[j] == "$" { j += 1 }
                let word = String(c[i..<j])
                out.t(word, keywords.contains(word.uppercased()) ? PreviewStyle.key : PreviewStyle.plain)
            } else if ch.isNumber {
                while j < c.count, c[j].isNumber || c[j] == "." || c[j].isLetter { j += 1 }
                out.t(String(c[i..<j]), PreviewStyle.number)
            } else {
                out.t(String(ch), "(),;.".contains(ch) ? PreviewStyle.punct : PreviewStyle.plain)
            }
            i = j
        }
    }
}
