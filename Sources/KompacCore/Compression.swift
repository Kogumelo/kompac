import Foundation

/// Formats Kompac creates. It reads everything 7zz opens, but creates only these four.
public enum ArchiveFormat: String, CaseIterable, Identifiable, Sendable {
    case zip
    case sevenZip = "7z"
    case tarGz = "tar.gz"
    case tarXz = "tar.xz"

    public var id: String { rawValue }

    /// Extension of the generated file, without the dot.
    public var fileExtension: String { rawValue }

    public var label: String {
        switch self {
        case .zip: return "ZIP"
        case .sevenZip: return "7z"
        case .tarGz: return "tar.gz"
        case .tarXz: return "tar.xz"
        }
    }

    public var detail: String {
        switch self {
        case .zip: return NSLocalizedString("maximum compatibility (Windows, Mac, phone)", comment: "Archive format description (ZIP), shown after the format name")
        case .sevenZip: return NSLocalizedString("maximum compression, password with encrypted names", comment: "Archive format description (7z), shown after the format name")
        case .tarGz: return NSLocalizedString("Linux servers", comment: "Archive format description (tar.gz), shown after the format name")
        case .tarXz: return NSLocalizedString("Linux, smallest size", comment: "Archive format description (tar.xz), shown after the format name")
        }
    }

    /// ZIP (AES-256) and 7z accept a password; tar does not encrypt.
    public var supportsPassword: Bool { self == .zip || self == .sevenZip }
    /// Only 7z also encrypts the names (`-mhe=on`).
    public var supportsEncryptedNames: Bool { self == .sevenZip }
    /// Split into parts `.7z.001`, `.002`… (7z only: 7zz's split ZIP is not the standard `.z01`).
    public var supportsVolumes: Bool { self == .sevenZip }

    var isCompressedTar: Bool { self == .tarGz || self == .tarXz }

    /// 7zz type for the final file (for tar.*, the second stage's).
    var sevenZipType: String {
        switch self {
        case .zip: return "zip"
        case .sevenZip: return "7z"
        case .tarGz: return "gzip"
        case .tarXz: return "xz"
        }
    }
}

public enum CompressionLevel: String, CaseIterable, Identifiable, Sendable {
    case fast, normal, maximum

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fast: return NSLocalizedString("Fast", comment: "Compression level")
        case .normal: return NSLocalizedString("Normal", comment: "Compression level")
        case .maximum: return NSLocalizedString("Maximum", comment: "Compression level")
        }
    }

    /// 7zz's `-mx`.
    var mx: Int {
        switch self {
        case .fast: return 1
        case .normal: return 5
        case .maximum: return 9
        }
    }
}

/// What to compress and how.
///
/// 7zz first writes to a hidden file (`.kompac-…`) in the destination, and only at the end does it
/// get the chosen name. Nothing existing is overwritten ("name 2.zip"). Cancelling or failing deletes the partial file.
public struct CompressionPlan: Sendable {
    /// Files and folders to include; each goes at the top of the archive under its own name.
    public var sources: [URL]
    public var format: ArchiveFormat
    public var level: CompressionLevel
    /// Ignored (must be nil) for formats without a password.
    public var password: String?
    /// 7z with a password: also encrypts the names, which then require the password even to list.
    public var encryptNames: Bool
    /// 7z: size of each part in bytes; nil = a single file.
    public var volumeSize: UInt64?
    /// Folder where the archive appears (default: the first item's).
    public var destination: URL
    /// Name without the format extension ("backup" → "backup.tar.gz").
    public var name: String

    public init(sources: [URL], format: ArchiveFormat = .zip, level: CompressionLevel = .normal,
                password: String? = nil, encryptNames: Bool = false, volumeSize: UInt64? = nil,
                destination: URL? = nil, name: String? = nil) {
        self.sources = sources
        self.format = format
        self.level = level
        self.password = password
        self.encryptNames = encryptNames
        self.volumeSize = volumeSize
        self.destination = destination ?? sources.first?.deletingLastPathComponent()
            ?? FileManager.default.homeDirectoryForCurrentUser
        self.name = name ?? Compressor.defaultName(for: sources)
    }
}

public struct CompressionResult: Sendable {
    /// The archive created (the first part, if split).
    public var location: URL
    /// All parts, in order (just `location` when not split).
    public var parts: [URL]
    /// 7zz warnings that did not prevent the archive (e.g. an item that could not be read).
    public var warnings: String?
}

public enum Compressor {
    /// macOS junk that never goes in: Finder metadata, resource forks and the Archive Utility folder.
    /// `.kompac-*` is our own partial file, in case the destination is inside a source folder.
    public static let excludedPatterns = [".DS_Store", "._*", "__MACOSX", ".kompac-*"]

    public static func isExcluded(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == "__MACOSX" || name.hasPrefix(".kompac-")
    }

    /// One item: its name ("Relatórios", "foto.jpg" → "foto"); several: "Archive".
    public static func defaultName(for sources: [URL]) -> String {
        guard sources.count == 1, let only = sources.first else {
            return NSLocalizedString("Archive", comment: "Default file name (without extension) for an archive made from several items")
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: only.path, isDirectory: &isDir), isDir.boolValue {
            return only.lastPathComponent
        }
        let stem = only.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? only.lastPathComponent : stem
    }

    /// Final file name for the plan ("backup.tar.gz").
    public static func fileName(_ plan: CompressionPlan) -> String {
        plan.name + "." + plan.format.fileExtension
    }

    public static func run(_ plan: CompressionPlan, with tool: SevenZip,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> CompressionResult {
        let fm = FileManager.default
        let sources = plan.sources.filter { !isExcluded($0.lastPathComponent) }
        guard !sources.isEmpty else { throw ArchiveError.failed(NSLocalizedString("Nothing to compress.", comment: "Error message")) }
        for s in sources where !fm.fileExists(atPath: s.path) {
            throw ArchiveError.failed(String(format: NSLocalizedString("“%@” no longer exists.", comment: "Error message; %@ = file or folder name"), s.lastPathComponent))
        }
        let name = plan.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            throw ArchiveError.failed(NSLocalizedString("Invalid name for the archive.", comment: "Error message"))
        }
        let password = plan.format.supportsPassword ? plan.password.flatMap { $0.isEmpty ? nil : $0 } : nil
        if plan.password?.isEmpty == false && password == nil {
            throw ArchiveError.failed(String(format: NSLocalizedString("The %@ format does not accept a password.", comment: "Error message; %@ = format name such as tar.gz"), plan.format.label))
        }
        // 7zz limitation: ZIP passwords must be ASCII only (7z accepts any character).
        if plan.format == .zip, let password, !password.allSatisfy(\.isASCII) {
            throw ArchiveError.failed(NSLocalizedString("A ZIP password cannot contain accents or symbols such as €. Use only unaccented letters, digits and common punctuation, or choose 7z.", comment: "Error message"))
        }
        let volume = plan.format.supportsVolumes ? plan.volumeSize : nil

        let staging = plan.destination.appendingPathComponent(".kompac-\(UUID().uuidString).\(plan.format.fileExtension)")
        do {
            let r = try await tool.createRaw(staging, sources: sources, format: plan.format, level: plan.level,
                                             password: password, encryptNames: plan.encryptNames,
                                             volumeSize: volume, innerName: name, progress: progress)
            try Task.checkCancellation()

            let final = plan.destination.appendingPathComponent(name + "." + plan.format.fileExtension)
            var parts: [URL] = []
            if volume == nil {
                let target = Extractor.uniqueURL(final)
                try fm.moveItem(at: staging, to: target)
                parts = [target]
            } else {
                // Parts: ".kompac-…7z.001" → "name.7z.001"; "name 2" applies to all of them if 001 already exists.
                let staged = try stagedParts(of: staging)
                guard !staged.isEmpty else { throw ArchiveError.failed(NSLocalizedString("7zz did not produce any part.", comment: "Error message")) }
                let first = Extractor.uniqueURL(URL(fileURLWithPath: final.path + ".001"))
                let base = String(first.path.dropLast(4))
                for p in staged {
                    let target = URL(fileURLWithPath: base + "." + p.pathExtension)
                    try fm.moveItem(at: p, to: target)
                    parts.append(target)
                }
            }
            return CompressionResult(location: parts[0], parts: parts, warnings: r)
        } catch {
            try? fm.removeItem(at: staging)
            for p in (try? stagedParts(of: staging)) ?? [] { try? fm.removeItem(at: p) }
            if error is CancellationError { throw ArchiveError.cancelled }
            throw error
        }
    }

    /// ".kompac-X.7z.001", ".002"… in order.
    static func stagedParts(of staging: URL) throws -> [URL] {
        let dir = staging.deletingLastPathComponent()
        let prefix = staging.lastPathComponent + "."
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) && Int($0.pathExtension) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

extension SevenZip {
    /// Creates `output` with the `sources` at the top. tar.gz/tar.xz: two 7zz piped together
    /// (`a -ttar -so` → `a -tgzip -si`), with no intermediate .tar on disk.
    /// Returns 7zz's warnings (exit code 1), if any.
    func createRaw(_ output: URL, sources: [URL], format: ArchiveFormat, level: CompressionLevel,
                   password: String?, encryptNames: Bool, volumeSize: UInt64?, innerName: String,
                   progress: @escaping @Sendable (Double) -> Void) async throws -> String? {
        let utf8 = ["-sccUTF-8", "-scsUTF-8"]
        let exclude = Compressor.excludedPatterns.map { "-xr!" + $0 }
        let paths = ["--"] + sources.map(\.path)
        let stages: [[String]]
        let onStdout: @Sendable (Data) -> Bool
        let onStderr: @Sendable (Int, Data) -> Void

        if format.isCompressedTar {
            // Progress comes from the first stage (reading the originals), via stderr.
            stages = [["a", "-ttar", "-so", "-an", "-bsp2", "-bso0"] + utf8 + exclude + paths,
                      ["a", "-t" + format.sevenZipType, "-mx=\(level.mx)", "-si" + innerName + ".tar",
                       "-bsp0", "-bso0"] + utf8 + ["--", output.path]]
            onStdout = { _ in true }
            onStderr = { stage, d in if stage == 0, let p = Self.percent(in: d) { progress(p) } }
        } else {
            var args = ["a", "-t" + format.sevenZipType, "-mx=\(level.mx)", "-bsp1", "-bso0", "-bse2"] + utf8 + exclude
            // No password, no "-p": when empty, 7zz stops and asks for the password on the keyboard.
            if let password {
                args.append("-p" + password)
                if format == .zip { args.append("-mem=AES256") }
                if format == .sevenZip && encryptNames { args.append("-mhe=on") }
            }
            if let volumeSize { args.append("-v\(volumeSize)b") }
            stages = [args + ["--", output.path] + sources.map(\.path)]
            onStdout = { d in if let p = Self.percent(in: d) { progress(p) }; return true }
            onStderr = { _, _ in }
        }
        let r = try await ProcessRunner.runAsync(executable: executable, stages: stages,
                                                 onStdout: onStdout, onStderr: onStderr)
        try Self.check(r, password: nil)
        progress(1)
        guard r.statuses.max() == 1 else { return nil }
        let lines = r.allStderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("%") }
        return lines.prefix(4).joined(separator: "\n").ifEmpty(NSLocalizedString("7zz finished with warnings.", comment: "Warning shown after compressing when 7zz gave no details"))
    }
}
