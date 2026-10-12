import Foundation

public enum ArchiveError: Error, LocalizedError, Equatable {
    case toolNotFound
    /// The archive (or the item) is encrypted and no password was given.
    case passwordRequired
    case wrongPassword
    case notAnArchive
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .toolNotFound: return NSLocalizedString("The 7zz engine was not found inside the app.", comment: "Error message")
        case .passwordRequired: return NSLocalizedString("This archive is password protected.", comment: "Error message")
        case .wrongPassword: return NSLocalizedString("Wrong password.", comment: "Error message")
        case .notAnArchive: return NSLocalizedString("Could not open: it is not a recognized archive, or it is damaged.", comment: "Error message")
        case .cancelled: return NSLocalizedString("Cancelled.", comment: "Error message")
        case .failed(let msg): return msg
        }
    }
}

/// Access to the official 7zz (7-Zip for macOS), run as a process.
public struct SevenZip: Sendable {
    public let executable: URL

    public init(executable: URL) { self.executable = executable }

    /// `KOMPAC_7ZZ` in the environment (tests, debugging) or the app's `Contents/Resources/7zz`.
    public static func locate(bundle: Bundle = .main) -> SevenZip? {
        let fm = FileManager.default
        if let env = ProcessInfo.processInfo.environment["KOMPAC_7ZZ"], fm.isExecutableFile(atPath: env) {
            return SevenZip(executable: URL(fileURLWithPath: env))
        }
        if let url = bundle.url(forResource: "7zz", withExtension: nil), fm.isExecutableFile(atPath: url.path) {
            return SevenZip(executable: url)
        }
        return nil
    }

    /// Common options: UTF-8 names in output and in lists, and no interactive prompt
    /// (`-p` always present: without a password, 7zz does not stop waiting for the keyboard).
    static func common(password: String?) -> [String] {
        ["-sccUTF-8", "-scsUTF-8", "-p" + (password ?? "")]
    }

    /// Types that are only a compression layer; with a .tar inside, they become a compressed tar.
    static let streamTypes: Set<String> = ["gzip", "bzip2", "xz", "zstd", "lzma", "z", "lzip"]

    // MARK: Listing

    public func list(_ archive: URL, password: String? = nil) async throws -> ArchiveListing {
        let collector = Collector()
        let r = try await ProcessRunner.runAsync(
            executable: executable,
            stages: [["l", "-slt"] + Self.common(password: password) + ["--", archive.path]],
            onStdout: collector.append)
        try Self.check(r, password: password)
        let listing = SLTParser.parse(collector.take())

        // tar.gz, tar.xz…: lists the inner tar, decompressing through a pipe.
        // (In xz the inner item has no name and the parser drops it: zero items.)
        if Self.streamTypes.contains(listing.type.lowercased()), listing.items.count <= 1,
           Self.looksLikeTar(inner: listing.items.first?.rawPath ?? "", outer: archive.lastPathComponent) {
            let inner = Collector()
            let r2 = try await ProcessRunner.runAsync(
                executable: executable,
                stages: [["x", "-so", "-bd"] + Self.common(password: password) + ["--", archive.path],
                         ["l", "-slt", "-si", "-ttar", "-sccUTF-8", "-scsUTF-8"]],
                onStdout: inner.append)
            try Self.check(r2, password: password)
            var tar = SLTParser.parse(inner.take())
            tar.type = listing.type + " + tar"
            tar.compressedTar = true
            return tar
        }
        return listing
    }

    static func looksLikeTar(inner: String, outer: String) -> Bool {
        // xz does not store the inner name (the item has no name): the outer name counts, "x.tar.xz".
        let i = inner.lowercased(), o = outer.lowercased()
        let outerStem = (o as NSString).deletingPathExtension
        return i.hasSuffix(".tar") || outerStem.hasSuffix(".tar")
            || [".tgz", ".tbz", ".tbz2", ".txz", ".tzst", ".tlz", ".taz"].contains { o.hasSuffix($0) }
    }

    /// Turns 7zz's result into an error. Code 0 = ok, 1 = warning (continue), 2+ = error.
    static func check(_ r: RunResult, password: String?) throws {
        let err = r.allStderr
        if err.contains("Wrong password") || err.contains("Cannot open encrypted archive") {
            throw (password ?? "").isEmpty ? ArchiveError.passwordRequired : ArchiveError.wrongPassword
        }
        guard let worst = r.statuses.max(), worst > 1 else { return }
        if err.contains("Cannot open the file as archive") || err.contains("Can not open the file as archive") {
            throw ArchiveError.notAnArchive
        }
        let lines = err.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("7-Zip") && !$0.hasPrefix("64-bit") }
        throw ArchiveError.failed(lines.prefix(4).joined(separator: "\n").ifEmpty(String(format: NSLocalizedString("7zz finished with error %ld.", comment: "Error message when 7zz gave no details; %ld = exit code"), Int(worst))))
    }

    // MARK: Preview

    /// First `limit` bytes of the item, read into memory (`7zz e -so`), without writing anything to disk.
    public func head(of item: String, in archive: URL, listing: ArchiveListing, password: String?,
                     limit: Int = 64 * 1024) async throws -> Data {
        let box = Collector(limit: limit)
        let stages: [[String]]
        if listing.compressedTar {
            stages = [["x", "-so", "-bd"] + Self.common(password: password) + ["--", archive.path],
                      ["e", "-so", "-si", "-ttar", "-spd", "-bd", "-sccUTF-8", "-scsUTF-8", "--", item]]
        } else {
            stages = [["e", "-so", "-spd", "-bd"] + Self.common(password: password) + ["--", archive.path, item]]
        }
        let r = try await ProcessRunner.runAsync(executable: executable, stages: stages, onStdout: box.append)
        if !r.stoppedEarly { try Self.check(r, password: password) }
        return box.takeData()
    }

    // MARK: Extraction

    /// Extracts into `directory` (which must already exist), keeping the paths inside the archive.
    /// Empty `items` = everything. `progress` receives 0 to 1.
    public func extractRaw(_ archive: URL, listing: ArchiveListing, items: [String], to directory: URL,
                           password: String?, progress: @escaping @Sendable (Double) -> Void) async throws {
        let base = ["-y", "-sns-", "-spd"]
        let stages: [[String]]
        let onStdout: @Sendable (Data) -> Bool
        let onStderr: @Sendable (Int, Data) -> Void
        if listing.compressedTar {
            // Progress comes from the first stage (decompression), via stderr.
            stages = [["x", "-so", "-bsp2"] + Self.common(password: password) + ["--", archive.path],
                      ["x", "-si", "-ttar", "-bsp0", "-bso0", "-sccUTF-8", "-scsUTF-8"] + base
                        + ["-o" + directory.path, "--"] + items]
            onStdout = { _ in true }
            onStderr = { stage, d in if stage == 0, let p = Self.percent(in: d) { progress(p) } }
        } else {
            stages = [["x", "-bsp1", "-bso0", "-bse2"] + base + Self.common(password: password)
                        + ["-o" + directory.path, "--", archive.path] + items]
            onStdout = { d in if let p = Self.percent(in: d) { progress(p) }; return true }
            onStderr = { _, _ in }
        }
        let r = try await ProcessRunner.runAsync(executable: executable, stages: stages,
                                                 onStdout: onStdout, onStderr: onStderr)
        try Self.check(r, password: password)
        progress(1)
    }

    /// Last "NN%" in a chunk of `-bsp` output (the line is rewritten with backspaces).
    static func percent(in data: Data) -> Double? {
        let s = String(decoding: data, as: UTF8.self)
        var last: Double?
        var digits = ""
        for ch in s {
            if ch.isNumber { digits.append(ch) } else {
                if ch == "%", let v = Int(digits), v <= 100 { last = Double(v) / 100 }
                digits = ""
            }
        }
        return last
    }
}

/// Collects a process's output; with `limit`, stops reading once it is reached.
final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int?

    init(limit: Int? = nil) { self.limit = limit }

    func append(_ d: Data) -> Bool {
        lock.withLock {
            if let limit {
                data.append(d.prefix(limit - data.count))
                return data.count < limit
            }
            data.append(d)
            return true
        }
    }

    func take() -> String { String(decoding: takeData(), as: UTF8.self) }

    func takeData() -> Data {
        lock.withLock {
            defer { data = Data() }
            return data
        }
    }
}

extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}
