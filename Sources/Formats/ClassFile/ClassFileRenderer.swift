import AppKit

/// A compiled Java class as the declaration it came from: modifiers, name,
/// supertypes, fields and method signatures, plus the Java version it targets.
///
/// Reads the constant pool and member tables, skipping every attribute except
/// SourceFile and Exceptions, so no bytecode is decoded. A class that is cut
/// short still shows whatever parsed before the damage.
enum ClassFileRenderer {

    struct NotAClassFile: Error {}

    /// `major` is the class-file version: 52 is Java 8, 61 is Java 17.
    static func javaVersion(major: Int) -> String {
        switch major {
        case ..<45: return "class file version \(major)"
        case 45: return "Java 1.1 (major 45)"
        case 46...48: return "Java 1.\(major - 44) (major \(major))"
        default: return "Java \(major - 44) (major \(major))"
        }
    }

    private enum Constant {
        case utf8(String)
        case classRef(Int)
        case other
    }

    private struct Member {
        var access: Int
        var name: String
        var descriptor: String
        var exceptions: [String] = []
    }

    static func render(url: URL, maxBytes: Int = 16 << 20) throws -> NSAttributedString {
        let size = fileSize(url) ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes) ?? Data()

        var r = ByteReader(data, bigEndian: true)
        guard (try? r.u32()) == 0xCAFEBABE, let minor = try? r.u16(), let major = try? r.u16() else {
            throw NotAClassFile()
        }
        // Universal Mach-O binaries share the 0xCAFEBABE magic; their next
        // field is an architecture count, which reads as a tiny "major".
        guard major >= 45 else { throw NotAClassFile() }

        var facts = [javaVersion(major: major)]
        if minor == 0xFFFF { facts.append("preview features") }
        let body = NSMutableAttributedString()

        var pool: [Constant] = []
        var access = 0
        var this = "", superName: String?
        var interfaces: [String] = []
        var fields: [Member] = []
        var methods: [Member] = []
        var sourceFile: String?
        var damaged = false

        do {
            pool = try readPool(&r)
            func utf8(_ i: Int) -> String {
                if i < pool.count, case .utf8(let s) = pool[i] { return s }
                return "#\(i)"
            }
            func className(_ i: Int) -> String {
                if i < pool.count, case .classRef(let n) = pool[i] { return utf8(n).replacingOccurrences(of: "/", with: ".") }
                return "#\(i)"
            }
            access = try r.u16()
            this = className(try r.u16())
            let superIndex = try r.u16()
            superName = superIndex == 0 ? nil : className(superIndex)
            for _ in 0..<(try r.u16()) { interfaces.append(className(try r.u16())) }

            func members() throws -> [Member] {
                var list: [Member] = []
                for _ in 0..<(try r.u16()) {
                    var m = Member(access: try r.u16(), name: utf8(try r.u16()), descriptor: utf8(try r.u16()))
                    for _ in 0..<(try r.u16()) {
                        let name = utf8(try r.u16())
                        var attr = ByteReader(try r.bytes(try r.u32()), bigEndian: true)
                        if name == "Exceptions" {
                            for _ in 0..<(try attr.u16()) { m.exceptions.append(className(try attr.u16())) }
                        }
                    }
                    list.append(m)
                }
                return list
            }
            fields = try members()
            methods = try members()
            for _ in 0..<(try r.u16()) {
                let name = utf8(try r.u16())
                var attr = ByteReader(try r.bytes(try r.u32()), bigEndian: true)
                if name == "SourceFile" { sourceFile = utf8(try attr.u16()) }
            }
        } catch {
            damaged = true
        }

        if let sourceFile { facts.append("from \(sourceFile)") }
        if damaged { facts.append(size > maxBytes ? "too large, partly read" : "damaged or truncated") }
        let out = reportHeader(url, size: size, facts)
        if this.isEmpty {
            out.t("Could not read past the constant pool.\n", PreviewStyle.dim)
            return out
        }

        writeDeclaration(access: access, this: this, superName: superName, interfaces: interfaces, into: body)
        let simple = this.split(separator: ".").last.map(String.init) ?? this
        let visibleFields = fields.filter { $0.access & 0x1000 == 0 }
        let visibleMethods = methods.filter { $0.access & 0x1040 == 0 }
        for f in visibleFields {
            body.t("    ", PreviewStyle.punct)
            modifiers(f.access, field: true, into: body)
            body.t(typeName(f.descriptor), PreviewStyle.tag)
            body.t(" " + f.name, PreviewStyle.key)
            body.t(";\n", PreviewStyle.punct)
        }
        if !visibleFields.isEmpty, !visibleMethods.isEmpty { body.t("\n", PreviewStyle.punct) }
        for m in visibleMethods { writeMethod(m, simpleName: simple, into: body) }
        let hidden = fields.count - visibleFields.count + methods.count - visibleMethods.count
        if hidden > 0 { body.t("    // \(hidden) synthetic member\(hidden == 1 ? "" : "s") not shown\n", PreviewStyle.comment) }
        body.t("}\n", PreviewStyle.punct)
        out.append(body)
        return out
    }

    private static func readPool(_ r: inout ByteReader) throws -> [Constant] {
        let count = try r.u16()
        var pool = [Constant](repeating: .other, count: max(count, 1))
        var i = 1
        while i < count {
            let tag = try r.u8()
            switch tag {
            case 1: pool[i] = .utf8(modifiedUTF8(try r.bytes(try r.u16())))
            case 7: pool[i] = .classRef(try r.u16())
            case 8, 16, 19, 20: try r.skip(2)
            case 3, 4, 9, 10, 11, 12, 17, 18: try r.skip(4)
            case 15: try r.skip(3)
            case 5, 6:
                try r.skip(8)
                i += 1                                      // longs and doubles take two slots
            default: throw ByteReader.OutOfBounds()
            }
            i += 1
        }
        return pool
    }

    /// Java's "modified UTF-8" differs only for NUL and characters outside the
    /// BMP, which are rare in names; fall back to a lossy decode for those.
    private static func modifiedUTF8(_ bytes: Data) -> String {
        String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
    }

    private static func writeDeclaration(access: Int, this: String, superName: String?, interfaces: [String],
                                         into out: NSMutableAttributedString) {
        let kind: String
        var extends = superName
        var implements = interfaces
        if access & 0x8000 != 0 { kind = "module" }
        else if access & 0x2000 != 0 { kind = "@interface"; implements.removeAll { $0 == "java.lang.annotation.Annotation" } }
        else if access & 0x0200 != 0 { kind = "interface" }
        else if access & 0x4000 != 0 || superName == "java.lang.Enum" { kind = "enum"; extends = nil }
        else if superName == "java.lang.Record" { kind = "record"; extends = nil }
        else { kind = "class" }
        if extends == "java.lang.Object" { extends = nil }

        var mods: [String] = []
        if access & 0x0001 != 0 { mods.append("public") }
        if access & 0x0400 != 0, kind == "class" { mods.append("abstract") }
        if access & 0x0010 != 0, kind == "class" { mods.append("final") }
        if !mods.isEmpty { out.t(mods.joined(separator: " ") + " ", PreviewStyle.literal) }
        out.t(kind + " ", PreviewStyle.literal, PreviewStyle.monoBold)
        out.t(this, PreviewStyle.key, PreviewStyle.monoBold)
        if let extends {
            out.t(" extends ", PreviewStyle.literal)
            out.t(extends, PreviewStyle.tag)
        }
        if !implements.isEmpty {
            out.t(kind == "interface" ? " extends " : " implements ", PreviewStyle.literal)
            out.t(implements.joined(separator: ", "), PreviewStyle.tag)
        }
        out.t(" {\n", PreviewStyle.punct)
    }

    private static func modifiers(_ access: Int, field: Bool, into out: NSMutableAttributedString) {
        var mods: [String] = []
        if access & 0x0001 != 0 { mods.append("public") }
        if access & 0x0002 != 0 { mods.append("private") }
        if access & 0x0004 != 0 { mods.append("protected") }
        if access & 0x0008 != 0 { mods.append("static") }
        if access & 0x0010 != 0 { mods.append("final") }
        if field {
            if access & 0x0080 != 0 { mods.append("transient") }
            if access & 0x0040 != 0 { mods.append("volatile") }
        } else {
            if access & 0x0020 != 0 { mods.append("synchronized") }
            if access & 0x0100 != 0 { mods.append("native") }
            if access & 0x0400 != 0 { mods.append("abstract") }
        }
        if !mods.isEmpty { out.t(mods.joined(separator: " ") + " ", PreviewStyle.literal) }
    }

    private static func writeMethod(_ m: Member, simpleName: String, into out: NSMutableAttributedString) {
        out.t("    ", PreviewStyle.punct)
        if m.name == "<clinit>" {
            out.t("static", PreviewStyle.literal)
            out.t(" { \u{2026} }\n", PreviewStyle.punct)
            return
        }
        modifiers(m.access, field: false, into: out)
        let (params, result) = splitDescriptor(m.descriptor)
        if m.name == "<init>" {
            out.t(simpleName, PreviewStyle.key)
        } else {
            out.t(result + " ", PreviewStyle.tag)
            out.t(m.name, PreviewStyle.key)
        }
        out.t("(", PreviewStyle.punct)
        for (n, p) in params.enumerated() {
            if n > 0 { out.t(", ", PreviewStyle.punct) }
            let varargs = m.access & 0x0080 != 0 && n == params.count - 1 && p.hasSuffix("[]")
            out.t(varargs ? String(p.dropLast(2)) + "..." : p, PreviewStyle.tag)
        }
        out.t(")", PreviewStyle.punct)
        if !m.exceptions.isEmpty {
            out.t(" throws ", PreviewStyle.literal)
            out.t(m.exceptions.joined(separator: ", "), PreviewStyle.tag)
        }
        out.t(";\n", PreviewStyle.punct)
    }

    /// `(Ljava/lang/String;[I)V` → (["String", "int[]"], "void").
    private static func splitDescriptor(_ d: String) -> ([String], String) {
        let c = Array(d)
        guard c.first == "(", let close = c.firstIndex(of: ")") else { return ([], d) }
        var params: [String] = []
        var i = 1
        while i < close {
            let (name, next) = parseType(c, i)
            params.append(name)
            i = max(next, i + 1)
        }
        return (params, parseType(c, close + 1).0)
    }

    private static func typeName(_ d: String) -> String { parseType(Array(d), 0).0 }

    private static func parseType(_ c: [Character], _ start: Int) -> (String, Int) {
        var i = start
        var dims = 0
        while i < c.count, c[i] == "[" { dims += 1; i += 1 }
        guard i < c.count else { return ("?", i) }
        var name: String
        switch c[i] {
        case "B": name = "byte"
        case "C": name = "char"
        case "D": name = "double"
        case "F": name = "float"
        case "I": name = "int"
        case "J": name = "long"
        case "S": name = "short"
        case "Z": name = "boolean"
        case "V": name = "void"
        case "L":
            let end = c[i...].firstIndex(of: ";") ?? c.count
            name = String(c[min(i + 1, end)..<end]).replacingOccurrences(of: "/", with: ".")
            if name.hasPrefix("java.lang."), !name.dropFirst(10).contains(".") { name.removeFirst(10) }
            i = end
        default: name = String(c[i])
        }
        return (name + String(repeating: "[]", count: dims), i + 1)
    }
}
