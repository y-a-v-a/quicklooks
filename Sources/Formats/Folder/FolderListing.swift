import AppKit

/// What the folder preview shows: the folder's items and, for each subfolder,
/// the items directly inside it. One level down and no further, so a preview
/// costs one directory read per subfolder however deep the tree goes.
struct FolderItem: Sendable {
    let url: URL
    let name: String
    let isFolder: Bool          // packages (.app) count as files, as in Finder
    let isHidden: Bool
    let date: Date?
    let kind: String
    /// A file's own size. A subfolder's is the sum of the files directly in
    /// it; nil for folders one level down, whose contents are not read.
    var size: Int64?
    var children: [FolderItem] = []
    /// Why a subfolder's contents could not be read, shown in its row.
    var problem: String?

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isHiddenKey,
                                                 .contentModificationDateKey,
                                                 .localizedTypeDescriptionKey, .fileSizeKey]

    init(url: URL) {
        let v = try? url.resourceValues(forKeys: Set(Self.keys))
        self.url = url
        name = url.lastPathComponent
        let directory = v?.isDirectory ?? false
        isFolder = directory && !(v?.isPackage ?? false)
        isHidden = v?.isHidden ?? name.hasPrefix(".")
        date = v?.contentModificationDate
        kind = v?.localizedTypeDescription ?? ""
        size = directory ? nil : Int64(v?.fileSize ?? 0)
    }

    /// The items in `url`, by name. Finder never shows `.DS_Store`, and
    /// neither do we, even with hidden files on.
    static func contents(of url: URL) throws -> [FolderItem] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys)
            .filter { $0.lastPathComponent != ".DS_Store" }
            .map(FolderItem.init)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// This subfolder with its contents read, one level deep. One that
    /// cannot be read keeps its row and says why.
    func opened() -> FolderItem {
        var folder = self
        do {
            folder.children = try Self.contents(of: url)
            folder.size = folder.children.reduce(0) { $0 + ($1.size ?? 0) }
        } catch {
            folder.problem = error.localizedDescription
        }
        return folder
    }
}

/// One line of the list.
enum FolderRow {
    case item(FolderItem, depth: Int)
    case more(Int)                      // "… 1,234 more items" under a long subfolder

    /// Every item, each subfolder followed by at most `cap` of its children.
    static func rows(_ items: [FolderItem], showHidden: Bool, cap: Int = 200) -> [FolderRow] {
        var rows: [FolderRow] = []
        for item in items where showHidden || !item.isHidden {
            rows.append(.item(item, depth: 0))
            let children = item.children.filter { showHidden || !$0.isHidden }
            rows += children.prefix(cap).map { .item($0, depth: 1) }
            if children.count > cap { rows.append(.more(children.count - cap)) }
        }
        return rows
    }
}
