import AppKit

/// Markdown, rendered: headings, emphasis, lists, quotes, tables, links, and
/// code in green monospace.
///
/// Foundation's own CommonMark parser (with GitHub tables and strikethrough)
/// does the parsing. It returns the text with block structure attached as
/// `presentationIntent` and inline styling as `inlinePresentationIntent`, and
/// this file only turns those into AppKit attributes. What it leaves alone is
/// handled here: YAML front matter, task-list boxes and empty table cells.
enum MarkdownRenderer {

    static func render(url: URL, maxBytes: Int = 2 << 20) throws -> NSAttributedString {
        let size = fileSize(url) ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes) ?? Data()
        var source = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) ?? ""
        source = source.replacingOccurrences(of: "\r\n", with: "\n")

        let lines = source.reduce(into: 1) { n, c in if c == "\n" { n += 1 } }
        var facts = ["\(lines.formatted()) line\(lines == 1 ? "" : "s")"]
        if size > data.count { facts.append("first \(formatBytes(data.count)) shown") }

        let (frontMatter, markdown) = splitFrontMatter(source)
        let parsed = try AttributedString(markdown: markdown, options: .init(
            allowsExtendedAttributes: true,
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible))

        let out = reportHeader(url, size: size, facts)
        if let frontMatter {
            let box = MarkdownBlock(.fill(MarkdownStyle.frontMatterFill), padding: 16, marginBelow: 18)
            out.append(NSAttributedString(string: frontMatter + "\n", attributes: [
                .font: MarkdownStyle.code, .foregroundColor: MarkdownStyle.secondary,
                .paragraphStyle: MarkdownStyle.paragraph(after: 0, lineSpacing: 2, blocks: [box])
            ]))
        }
        var writer = BlockWriter(out: out)
        for (intent, range) in parsed.runs[\.presentationIntent] {
            writer.write(parsed[range], intent: intent)
        }
        writer.finish()
        return out
    }

    /// A `---` block at the very top, as Jekyll, Hugo and Obsidian write it.
    static func splitFrontMatter(_ s: String) -> (String?, String) {
        guard s.hasPrefix("---\n") else { return (nil, s) }
        var lines = s.components(separatedBy: "\n")
        guard let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else { return (nil, s) }
        let front = lines[1..<end].joined(separator: "\n")
        lines.removeSubrange(0...end)
        return (front, lines.joined(separator: "\n"))
    }
}

/// Appends one parsed block at a time. Remembers the list items, quotes and
/// tables already started, since their paragraphs arrive one by one and must
/// share a marker, a bar or a grid.
private struct BlockWriter {

    let out: NSMutableAttributedString
    private var seenListItems: Set<Int> = []
    private var quoteBlocks: [Int: MarkdownBlock] = [:]
    private var table: (id: Int, grid: NSTextTable, columns: [PresentationIntent.TableColumn])?
    private var row = -1
    private var nextColumn = 0
    private var previousList: Int?

    init(out: NSMutableAttributedString) { self.out = out }

    mutating func write(_ text: AttributedSubstring, intent: PresentationIntent?) {
        let parts = intent?.components ?? []           // innermost first
        let lists = parts.filter { $0.kind == .orderedList || $0.kind == .unorderedList }
        let outerList = lists.last?.identity
        if let previousList, previousList != outerList { spaceAfterLastParagraph(14) }
        previousList = outerList
        guard let kind = parts.first?.kind else {
            closeTable()
            out.append(inline(text, font: MarkdownStyle.body, paragraph: MarkdownStyle.paragraph()))
            return
        }
        if case .tableCell(let column) = kind {
            cell(text, column: column, parts: parts)
            return
        }
        closeTable()

        let quotes = parts.filter { $0.kind == .blockQuote }
        let quoteBlock = quotes.first.map { q in
            quoteBlocks[q.identity] ?? {
                let b = MarkdownBlock(.quoteBar, marginBelow: 14)
                b.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
                quoteBlocks[q.identity] = b
                return b
            }()
        }
        let color = quotes.isEmpty ? MarkdownStyle.text : MarkdownStyle.secondary
        let indent = CGFloat(max(lists.count - 1, 0)) * 24

        switch kind {
        case .header(let level):
            let rule: [NSTextBlock] = level <= 2 ? [MarkdownBlock(.dottedRule, marginBelow: 18)] : []
            let style = MarkdownStyle.paragraph(before: level <= 2 ? 14 : 8, after: level <= 2 ? 8 : 10,
                                                blocks: rule)
            out.append(inline(text, font: MarkdownStyle.heading(level), paragraph: style, color: color))
        case .codeBlock(let language):
            var code = String(text.characters)
            if code.hasSuffix("\n") { code.removeLast() }
            let box = MarkdownBlock(.fill(MarkdownStyle.codeFill), padding: 18, marginBelow: 16)
            let block = MarkdownCode.highlight(code + "\n", language: language)
            block.addAttribute(.paragraphStyle, value: MarkdownStyle.paragraph(
                indent: indent, after: 0, lineSpacing: 3, blocks: [quoteBlock, box].compactMap { $0 }),
                range: NSRange(location: 0, length: block.length))
            out.append(block)
        case .thematicBreak:
            out.append(NSAttributedString(string: "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 4),
                .paragraphStyle: MarkdownStyle.paragraph(after: 14, blocks: [MarkdownBlock(.dottedRule)])
            ]))
        default:
            let blocks = [quoteBlock].compactMap { $0 }
            if let item = parts.first(where: { if case .listItem = $0.kind { return true }; return false }),
               let list = lists.first {
                let marker = seenListItems.insert(item.identity).inserted
                    ? listMarker(item.kind, ordered: list.kind == .orderedList, depth: lists.count) : nil
                let hanging: CGFloat = 24
                let style = MarkdownStyle.paragraph(indent: indent, hanging: hanging, after: 6, blocks: blocks)
                var body = inline(text, font: MarkdownStyle.body, paragraph: style, color: color)
                var bullet = marker.map { $0 + "\t" } ?? "\t"
                (body, bullet) = taskBox(body, bullet: bullet, isFirst: marker != nil)
                let line = NSMutableAttributedString(string: bullet, attributes: [
                    .font: MarkdownStyle.body, .foregroundColor: MarkdownStyle.secondary, .paragraphStyle: style
                ])
                line.append(body)
                out.append(line)
            } else {
                out.append(inline(text, font: MarkdownStyle.body,
                                  paragraph: MarkdownStyle.paragraph(blocks: blocks), color: color))
            }
        }
    }

    mutating func finish() { closeTable() }

    /// List items sit close together; the block after a list gets the
    /// normal paragraph gap again, by widening the list's last paragraph.
    private func spaceAfterLastParagraph(_ spacing: CGFloat) {
        guard out.length > 0 else { return }
        let range = (out.string as NSString).paragraphRange(for: NSRange(location: out.length - 1, length: 0))
        guard let style = out.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
              let wider = style.mutableCopy() as? NSMutableParagraphStyle else { return }
        wider.paragraphSpacing = max(wider.paragraphSpacing, spacing)
        out.addAttribute(.paragraphStyle, value: wider, range: range)
    }

    // MARK: lists

    private func listMarker(_ kind: PresentationIntent.Kind, ordered: Bool, depth: Int) -> String {
        guard case .listItem(let ordinal) = kind else { return "\u{2022}" }
        if ordered { return "\(ordinal)." }
        return ["\u{2022}", "\u{25E6}", "\u{25AA}"][(depth - 1) % 3]
    }

    /// `[ ]` and `[x]` at the start of an item become a box instead of a bullet.
    private func taskBox(_ body: NSAttributedString, bullet: String, isFirst: Bool) -> (NSAttributedString, String) {
        guard isFirst else { return (body, bullet) }
        let s = body.string
        let box: String
        if s.hasPrefix("[ ] ") { box = "\u{2610}" }
        else if s.hasPrefix("[x] ") || s.hasPrefix("[X] ") { box = "\u{2611}" }
        else { return (body, bullet) }
        return (body.attributedSubstring(from: NSRange(location: 4, length: body.length - 4)), box + "\t")
    }

    // MARK: tables

    private mutating func cell(_ text: AttributedSubstring, column: Int, parts: [PresentationIntent.IntentType]) {
        guard let tableIntent = parts.first(where: { if case .table = $0.kind { return true }; return false }),
              case .table(let columns) = tableIntent.kind else { return }
        if table?.id != tableIntent.identity {
            closeTable()
            let grid = NSTextTable()
            grid.numberOfColumns = columns.count
            grid.collapsesBorders = true
            grid.hidesEmptyCells = false
            table = (tableIntent.identity, grid, columns)
            row = -1
        }
        var rowIndex = 0
        for p in parts { if case .tableRow(let r) = p.kind { rowIndex = r } }
        if rowIndex != row { fillRow(); row = rowIndex; nextColumn = 0 }
        while nextColumn < column { appendCell(nil, column: nextColumn) }
        appendCell(text, column: column)
    }

    /// The parser drops empty cells, and NSTextTable needs every one of them.
    private mutating func fillRow() {
        guard let table, row >= 0 else { return }
        while nextColumn < table.columns.count { appendCell(nil, column: nextColumn) }
    }

    private mutating func appendCell(_ text: AttributedSubstring?, column: Int) {
        guard let table else { return }
        let block = NSTextTableBlock(table: table.grid, startingRow: max(row, 0), rowSpan: 1,
                                     startingColumn: column, columnSpan: 1)
        block.setWidth(0.5, type: .absoluteValueType, for: .border)
        block.setBorderColor(MarkdownStyle.tableBorder)
        block.setWidth(8, type: .absoluteValueType, for: .padding)
        block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .maxX)
        if row == 0 { block.backgroundColor = MarkdownStyle.tableHeaderFill }
        let alignment: NSTextAlignment
        switch table.columns[safe: column]?.alignment {
        case .center: alignment = .center
        case .right: alignment = .right
        default: alignment = .natural
        }
        let style = MarkdownStyle.paragraph(after: 0, alignment: alignment, blocks: [block])
        let font = row == 0 ? NSFont.boldSystemFont(ofSize: MarkdownStyle.bodySize) : MarkdownStyle.body
        if let text {
            out.append(inline(text, font: font, paragraph: style))
        } else {
            out.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
        }
        nextColumn = column + 1
    }

    private mutating func closeTable() {
        guard table != nil else { return }
        fillRow()
        table = nil
        // Space after the grid; an empty paragraph outside any block.
        out.append(NSAttributedString(string: "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 6), .paragraphStyle: MarkdownStyle.paragraph(after: 0)
        ]))
    }

    // MARK: inline

    /// One block's text with emphasis, code, links and images applied,
    /// ending in a newline so it is a paragraph of its own.
    private func inline(_ text: AttributedSubstring, font: NSFont, paragraph: NSParagraphStyle,
                        color: NSColor = MarkdownStyle.text) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for run in text.runs {
            var s = String(text[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.lineBreak) { s = "\u{2028}" }      // new line, same paragraph
            if intent.contains(.softBreak) { s = " " }

            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if intent.contains(.code) {
                attrs[.font] = traits.contains(.bold) ? MarkdownStyle.codeBold : MarkdownStyle.code
                attrs[.foregroundColor] = MarkdownStyle.codeText
                attrs[.backgroundColor] = MarkdownStyle.codeFill
                attrs[MarkdownStyle.inlineCode] = true
                // A little air inside the fill; no-break, so a wrap never
                // leaves an empty green box at the end of a line.
                s = "\u{202F}" + s + "\u{202F}"
            } else if intent.contains(.inlineHTML) || intent.contains(.blockHTML) {
                if intent.contains(.blockHTML), s.hasSuffix("\n") { s.removeLast() }   // we add our own
                attrs[.font] = MarkdownStyle.code
                attrs[.foregroundColor] = MarkdownStyle.secondary
            } else if !traits.isEmpty {
                let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
                attrs[.font] = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
            }
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attrs[.link] = link }
            if run.imageURL != nil {
                s = "\u{1F5BC}\u{FE0E} " + (s.isEmpty ? (run.imageURL?.lastPathComponent ?? "image") : s)
                attrs[.foregroundColor] = MarkdownStyle.secondary
            }
            result.append(NSAttributedString(string: s, attributes: attrs))
        }
        result.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraph]))
        return result
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
