import Foundation

/// Destination rules for extraction.
///
/// 7zz first extracts into a hidden folder (`.kompac-…`) next to the destination, on the same volume.
/// There the names are fixed (encoding) and the chosen items go to their final place:
/// - a single item at the top (folder or file): goes straight to the destination, no extra folder;
/// - several items: they go into a folder named after the archive.
/// Nothing existing is overwritten: if the name already exists, it becomes "name 2", "name 3"…
/// Cancelling or failing deletes the hidden folder, leaving no half-done extraction.
public struct ExtractionPlan: Sendable {
    public var archive: URL
    public var listing: ArchiveListing
    /// Raw paths (`ArchiveNode.rawPath`) to extract; empty = everything.
    public var rawPaths: [String]
    /// On-disk paths (`ArchiveNode.id`) matching `rawPaths`, in the same order.
    public var diskPaths: [String]
    /// Folder where the result appears (default: the archive's).
    public var destination: URL
    /// Concrete name encoding (not `automatic`).
    public var encoding: NameEncoding
    public var password: String?

    public init(archive: URL, listing: ArchiveListing, rawPaths: [String] = [], diskPaths: [String] = [],
                destination: URL? = nil, encoding: NameEncoding = .utf8, password: String? = nil) {
        self.archive = archive
        self.listing = listing
        self.rawPaths = rawPaths
        self.diskPaths = diskPaths
        self.destination = destination ?? archive.deletingLastPathComponent()
        self.encoding = encoding
        self.password = password
    }
}

public struct ExtractionResult: Sendable {
    /// What appeared in the destination: the folder created, or the single item.
    public var location: URL
    /// Items placed directly in the destination (1 when no folder was created).
    public var topLevel: [URL]
}

public enum Extractor {
    public static func run(_ plan: ExtractionPlan, with tool: SevenZip,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> ExtractionResult {
        let fm = FileManager.default
        let staging = plan.destination.appendingPathComponent(".kompac-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            try await tool.extractRaw(plan.archive, listing: plan.listing, items: plan.rawPaths, to: staging,
                                      password: plan.password, progress: progress)
            try Task.checkCancellation()
            try fixNames(in: staging, encoding: plan.encoding)

            // What goes to the destination: the chosen items (names already fixed) or the top of the extraction.
            var entries: [URL]
            if plan.diskPaths.isEmpty {
                entries = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            } else {
                entries = plan.diskPaths.map { disk in
                    let fixed = disk.split(separator: "/").map { NameDecoder.convert(String($0), using: plan.encoding) }
                    return fixed.reduce(staging) { $0.appendingPathComponent($1) }
                }.filter { fm.fileExists(atPath: $0.path) }
            }
            guard !entries.isEmpty else { throw ArchiveError.failed(NSLocalizedString("Nothing was extracted.", comment: "Error message")) }

            let result: ExtractionResult
            if entries.count == 1 {
                let target = uniqueURL(plan.destination.appendingPathComponent(entries[0].lastPathComponent))
                try fm.moveItem(at: entries[0], to: target)
                try? fm.removeItem(at: staging)
                result = ExtractionResult(location: target, topLevel: [target])
            } else {
                let folder = uniqueURL(plan.destination.appendingPathComponent(baseName(of: plan.archive.lastPathComponent)))
                if plan.diskPaths.isEmpty {
                    try fm.moveItem(at: staging, to: folder)
                } else {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: false)
                    for e in entries {
                        try fm.moveItem(at: e, to: uniqueURL(folder.appendingPathComponent(e.lastPathComponent)))
                    }
                    try? fm.removeItem(at: staging)
                }
                result = ExtractionResult(location: folder, topLevel: [folder])
            }
            return result
        } catch {
            try? fm.removeItem(at: staging)
            if error is CancellationError { throw ArchiveError.cancelled }
            throw error
        }
    }

    /// Renames what 7zz wrote with code-page bytes (U+EFxx) to the converted name.
    /// Deepest first, so that the parent folder's path is still the old one.
    static func fixNames(in root: URL, encoding: NameEncoding) throws {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else { return }
        var urls: [URL] = []
        for case let url as URL in e where NameDecoder.convert(url.lastPathComponent, using: encoding) != url.lastPathComponent {
            urls.append(url)
        }
        urls.sort { $0.pathComponents.count > $1.pathComponents.count }
        for url in urls {
            let newName = NameDecoder.convert(url.lastPathComponent, using: encoding)
            let target = uniqueURL(url.deletingLastPathComponent().appendingPathComponent(newName))
            try fm.moveItem(at: url, to: target)
        }
    }

    /// "name", "name 2", "name 3"… (the extension stays at the end: "Backup 2.fdb").
    public static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) || isSymlink(url) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : String(url.lastPathComponent.dropLast(ext.count + 1))
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) && !isSymlink(candidate) { return candidate }
            n += 1
        }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Folder name for an archive: "backup.tar.gz" → "backup", "fotos.zip" → "fotos".
    public static func baseName(of fileName: String) -> String {
        let lower = fileName.lowercased()
        for ext in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lzma", ".tar.z", ".tar.lz"] where lower.hasSuffix(ext) {
            return String(fileName.dropLast(ext.count)).ifEmpty(fileName)
        }
        let url = URL(fileURLWithPath: fileName)
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty
            ? String(format: NSLocalizedString("%@ (contents)", comment: "Folder name for the contents of an archive whose name has no stem; %@ = archive file name"), fileName)
            : stem
    }
}
