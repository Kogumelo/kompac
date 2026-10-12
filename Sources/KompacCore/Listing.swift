import Foundation

/// An item of the archive, as 7zz describes it in `l -slt`.
public struct ArchiveItem: Sendable, Hashable {
    /// Path exactly as 7zz writes it (may start with "./", in tar). It is what is passed
    /// back to 7zz to extract or preview the item.
    public var rawPath: String
    public var isFolder: Bool
    public var size: UInt64?
    public var packedSize: UInt64?
    public var modified: Date?
    public var encrypted: Bool

    public init(rawPath: String, isFolder: Bool = false, size: UInt64? = nil, packedSize: UInt64? = nil,
                modified: Date? = nil, encrypted: Bool = false) {
        self.rawPath = rawPath
        self.isFolder = isFolder
        self.size = size
        self.packedSize = packedSize
        self.modified = modified
        self.encrypted = encrypted
    }

    /// Path as 7zz writes it to disk: no leading "./" or "/", no trailing "/".
    public var diskPath: String { ArchiveItem.normalize(rawPath) }

    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return parts.joined(separator: "/")
    }
}

/// Result of listing an archive.
public struct ArchiveListing: Sendable {
    /// Type 7zz recognized ("zip", "Rar", "Rar5", "7z", "gzip", "Dmg"…).
    public var type: String
    public var items: [ArchiveItem]
    /// tar inside gzip/bzip2/xz/zstd: 7zz only sees the outer layer, so listing and
    /// extraction go through two 7zz piped together.
    public var compressedTar: Bool = false

    public init(type: String, items: [ArchiveItem], compressedTar: Bool = false) {
        self.type = type
        self.items = items
        self.compressedTar = compressedTar
    }

    public var hasEncryptedItems: Bool { items.contains { $0.encrypted } }
    public var fileCount: Int { items.filter { !$0.isFolder }.count }
    public var totalSize: UInt64 { items.reduce(0) { $0 + ($1.size ?? 0) } }
}

/// Reads the output of `7zz l -slt`: "Key = value" blocks separated by a blank line.
/// Before the "----------" line come the archive's properties (sometimes more than one level, as in DMG,
/// which opens the APFS image inside); after it, one block per item.
public enum SLTParser {
    public static func parse(_ text: String) -> ArchiveListing {
        var type: String?
        var items: [ArchiveItem] = []
        var inItems = false
        var current: [String: String] = [:]
        var inBraces = false

        func flush() {
            defer { current = [:] }
            guard inItems, let path = current["Path"] else { return }
            let normalized = ArchiveItem.normalize(path)
            if normalized.isEmpty { return }
            let attrs = current["Attributes"] ?? ""
            items.append(ArchiveItem(
                rawPath: path,
                isFolder: current["Folder"] == "+" || attrs.hasPrefix("D"),
                size: current["Size"].flatMap { UInt64($0) },
                packedSize: current["Packed Size"].flatMap { UInt64($0) },
                modified: current["Modified"].flatMap(parseDate),
                encrypted: current["Encrypted"] == "+"
            ))
        }

        text.enumerateLines { line, _ in
            // Multi-line comments ("Comment = " followed by "{ … }") are skipped.
            if inBraces { if line == "}" { inBraces = false }; return }
            if line == "{" { inBraces = true; return }
            if line == "----------" { inItems = true; current = [:]; return }
            if line.isEmpty { flush(); return }
            guard let r = line.range(of: " = ") ?? (line.hasSuffix(" =") ? line.range(of: " =", options: .backwards) : nil)
            else { return }
            let key = String(line[..<r.lowerBound])
            if key.hasPrefix(" ") { return }
            let value = String(line[r.upperBound...])
            if !inItems {
                if key == "Type", type == nil { type = value }
                return
            }
            current[key] = value
        }
        flush()
        return ArchiveListing(type: type ?? "?", items: items)
    }

    /// "2026-10-10 01:18:39.8102439" (fraction optional), local time.
    static func parseDate(_ s: String) -> Date? {
        let digits = s.split(whereSeparator: { !$0.isNumber }).prefix(6).compactMap { Int($0) }
        guard digits.count == 6 else { return nil }
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (digits[0], digits[1], digits[2], digits[3], digits[4], digits[5])
        return Calendar(identifier: .gregorian).date(from: c)
    }
}
