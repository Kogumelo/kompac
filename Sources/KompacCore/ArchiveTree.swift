import Foundation

/// Node of the tree shown in the window. Folders the archive does not record as items (a ZIP made
/// without folder entries) are created from their children's paths.
public final class ArchiveNode: Identifiable, @unchecked Sendable {
    /// On-disk path of the item (no name conversion): stable when the encoding is changed.
    public let id: String
    /// Name already converted to the chosen encoding.
    public let name: String
    /// Path passed to 7zz to extract/preview this node.
    public let rawPath: String
    public let item: ArchiveItem?
    public let isFolder: Bool
    public internal(set) var children: [ArchiveNode]?
    /// Folders: sum of the children.
    public internal(set) var size: UInt64?
    public internal(set) var packedSize: UInt64?
    public var modified: Date? { item?.modified }
    public var encrypted: Bool { item?.encrypted ?? false }

    init(id: String, name: String, rawPath: String, item: ArchiveItem?, isFolder: Bool) {
        self.id = id
        self.name = name
        self.rawPath = rawPath
        self.item = item
        self.isFolder = isFolder
        self.children = isFolder ? [] : nil
        self.size = item?.size
        self.packedSize = item?.packedSize
    }

    /// Every node below this one (inclusive).
    public func walk(_ f: (ArchiveNode) -> Void) {
        f(self)
        children?.forEach { $0.walk(f) }
    }
}

public struct ArchiveTree: Sendable {
    public let roots: [ArchiveNode]
    public let byID: [String: ArchiveNode]

    public init(listing: ArchiveListing, encoding: NameEncoding) {
        var byID: [String: ArchiveNode] = [:]
        var roots: [ArchiveNode] = []

        func attach(_ node: ArchiveNode, parentID: String?) {
            if let pid = parentID, let parent = byID[pid] { parent.children?.append(node) } else { roots.append(node) }
        }

        /// Ensures the folders for `components[..<n]` exist; returns the folder's id.
        func ensureFolder(_ components: [Substring], _ n: Int, sampleRaw: String, sampleDisk: String) -> String? {
            guard n > 0 else { return nil }
            let id = components[..<n].joined(separator: "/")
            if byID[id] != nil { return id }
            let parentID = ensureFolder(components, n - 1, sampleRaw: sampleRaw, sampleDisk: sampleDisk)
            // Raw path of the folder: the child's, minus the part after it (keeps a leading "./").
            let tail = sampleDisk.count - id.count
            let raw = tail > 0 && sampleRaw.count >= tail ? String(sampleRaw.dropLast(tail)) : id
            let node = ArchiveNode(id: id, name: NameDecoder.convert(String(components[n - 1]), using: encoding),
                                   rawPath: raw, item: nil, isFolder: true)
            byID[id] = node
            attach(node, parentID: parentID)
            return id
        }

        for item in listing.items {
            let disk = item.diskPath
            let comps = disk.split(separator: "/")
            guard let last = comps.last else { continue }
            let parentID = ensureFolder(comps, comps.count - 1, sampleRaw: item.rawPath, sampleDisk: disk)
            if let existing = byID[disk] {
                // Folder created earlier from a child: replace it with the real item (which has a date).
                guard existing.item == nil else { continue }
                let node = ArchiveNode(id: disk, name: existing.name, rawPath: item.rawPath, item: item,
                                       isFolder: true)
                node.children = existing.children
                byID[disk] = node
                if let pid = parentID, let parent = byID[pid] {
                    parent.children = parent.children?.map { $0 === existing ? node : $0 }
                } else {
                    roots = roots.map { $0 === existing ? node : $0 }
                }
                continue
            }
            let node = ArchiveNode(id: disk, name: NameDecoder.convert(String(last), using: encoding),
                                   rawPath: item.rawPath, item: item, isFolder: item.isFolder)
            byID[disk] = node
            attach(node, parentID: parentID)
        }

        func finish(_ nodes: inout [ArchiveNode]) {
            nodes.sort { a, b in
                if a.isFolder != b.isFolder { return a.isFolder }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            for n in nodes where n.isFolder {
                var kids = n.children ?? []
                finish(&kids)
                n.children = kids
                n.size = kids.reduce(0) { $0 + ($1.size ?? 0) }
                let packed = kids.compactMap(\.packedSize)
                n.packedSize = packed.isEmpty ? nil : packed.reduce(0, +)
            }
        }
        finish(&roots)
        self.roots = roots
        self.byID = byID
    }

    /// Selected ids, minus those already inside another selected folder.
    public func topMost(_ ids: Set<String>) -> [ArchiveNode] {
        ids.sorted().filter { id in
            !ids.contains { other in other != id && id.hasPrefix(other + "/") }
        }.compactMap { byID[$0] }
    }
}
