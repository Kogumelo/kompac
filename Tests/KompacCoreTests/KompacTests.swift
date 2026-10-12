import Foundation
import Testing
@testable import KompacCore

/// 7zz: `KOMPAC_7ZZ` from the environment, or the package's `vendor/7zz`.
let tool: SevenZip = {
    if let t = SevenZip.locate() { return t }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    return SevenZip(executable: root.appendingPathComponent("vendor/7zz"))
}()

func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: "Fixtures/" + name, withExtension: nil)!
}

/// A new temporary folder for each test; the caller deletes it with `cleanup`.
func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kompac-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func cleanup(_ url: URL) { try? FileManager.default.removeItem(at: url) }

/// Relative paths of everything below `root`, sorted.
func tree(_ root: URL) -> [String] {
    let e = FileManager.default.enumerator(atPath: root.path)
    var out: [String] = []
    while let p = e?.nextObject() as? String { out.append(p) }
    return out.sorted()
}

/// Copies the fixture to a temporary folder: extraction writes next to the archive.
func staged(_ name: String) throws -> (dir: URL, archive: URL) {
    let dir = try tempDir()
    let dest = dir.appendingPathComponent(name)
    try FileManager.default.copyItem(at: fixture(name), to: dest)
    return (dir, dest)
}

// MARK: - Listing

@Suite struct ListingTests {
    @Test func zipFlat() async throws {
        let l = try await tool.list(fixture("six.zip"))
        #expect(l.type == "zip")
        #expect(l.items.map(\.rawPath).sorted() == ["f1.txt", "f2.txt", "f3.txt", "f4.txt", "f5.txt", "f6.txt"])
        #expect(l.items.allSatisfy { $0.size == 10 && !$0.isFolder && $0.modified != nil })
    }

    @Test func encryptedHeadersNeedPassword() async throws {
        await #expect(throws: ArchiveError.passwordRequired) { try await tool.list(fixture("enc.7z")) }
        await #expect(throws: ArchiveError.wrongPassword) { try await tool.list(fixture("enc.7z"), password: "errada") }
        let l = try await tool.list(fixture("enc.7z"), password: "segredo")
        #expect(Set(l.items.map(\.diskPath)) == ["a.txt", "pasta", "pasta/b.txt"])
    }

    @Test func rar5WithPassword() async throws {
        await #expect(throws: ArchiveError.passwordRequired) { try await tool.list(fixture("rar5_encrypted_filenames.rar")) }
        let l = try await tool.list(fixture("rar5_encrypted_filenames.rar"), password: "password")
        #expect(l.type == "Rar5")
        #expect(l.items.map(\.rawPath) == ["a.txt", "b.txt", "c.txt", "d.txt"])
        let head = try await tool.head(of: "b.txt", in: fixture("rar5_encrypted_filenames.rar"), listing: l, password: "password")
        #expect(String(decoding: head, as: UTF8.self) == "This is from b.txt")
    }

    @Test func rar4WithPassword() async throws {
        let l = try await tool.list(fixture("rar4_encrypted_filenames.rar"), password: "password")
        #expect(l.type == "Rar")
        #expect(l.items.count == 4)
    }

    @Test func tarGzListsInnerTar() async throws {
        let l = try await tool.list(fixture("docs.tar.gz"))
        #expect(l.compressedTar)
        #expect(Set(l.items.map(\.diskPath)) == ["docs", "docs/leia.txt", "x.txt"])
        let t = ArchiveTree(listing: l, encoding: .utf8)
        let node = try #require(t.byID["docs/leia.txt"])
        #expect(node.rawPath == "./docs/leia.txt")
        let head = try await tool.head(of: node.rawPath, in: fixture("docs.tar.gz"), listing: l, password: nil)
        #expect(PreviewText.decode(head) == "Olá, tar!\nlinha 2\n")
    }

    @Test func notAnArchive() async throws {
        let (dir, _) = try staged("SOURCE.txt")
        defer { cleanup(dir) }
        await #expect(throws: ArchiveError.notAnArchive) {
            try await tool.list(dir.appendingPathComponent("SOURCE.txt"))
        }
    }

    /// Real 7zz output for a DMG: two header levels and a multiline comment.
    @Test func parserSkipsHeadersAndMultilineComments() {
        let text = """
        --
        Path = t.dmg
        Type = Dmg
        Comment =
        {
        unpack-size: 10532864
        Path = enganoso
        }
        ----
        Path = 4.apfs
        Size = 10493952
        --
        Path = 4.apfs
        Type = APFS
        Comment =
        {
        num_files: 2
        }
        ----------
        Path = pasta
        Folder = +
        Size =
        Modified = 2026-10-12 11:38:57.184405873

        Path = pasta/b.txt
        Folder = -
        Size = 4
        Packed Size =
        Modified = 2026-10-12 11:38:58

        """
        let l = SLTParser.parse(text)
        #expect(l.type == "Dmg")
        #expect(l.items.map(\.rawPath) == ["pasta", "pasta/b.txt"])
        #expect(l.items[0].isFolder && !l.items[1].isFolder)
        #expect(l.items[1].size == 4 && l.items[1].packedSize == nil)
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .hour, .second], from: l.items[1].modified!)
        #expect(c.year == 2026 && c.hour == 11 && c.second == 58)
    }

    /// A real, large RAR (e.g. made by WinRAR). Only runs with `KOMPAC_REAL_RAR=<path to the .rar>`; only lists.
    @Test(.enabled(if: RealRAR.path != nil))
    func realRAR() async throws {
        let l = try await tool.list(URL(fileURLWithPath: RealRAR.path!))
        #expect(l.type.hasPrefix("Rar"), "type: \(l.type)")
        #expect(!l.items.isEmpty)
    }
}

/// `KOMPAC_REAL_RAR` from the environment, when it points to an existing file.
enum RealRAR {
    static let path: String? = {
        guard let p = ProcessInfo.processInfo.environment["KOMPAC_REAL_RAR"], !p.isEmpty,
              FileManager.default.fileExists(atPath: p) else { return nil }
        return p
    }()
}

// MARK: - Names

@Suite struct EncodingTests {
    @Test func windows1252ZipBecomesRelatorio() async throws {
        let l = try await tool.list(fixture("w1252.zip"))
        let raw = l.items.map(\.diskPath)
        #expect(raw.allSatisfy { !$0.contains("Relatório") })
        #expect(NameDecoder.detect(raw) == .windows1252)
        let t = ArchiveTree(listing: l, encoding: .windows1252)
        #expect(t.roots.map(\.name) == ["Atenção", "Configuração.ini", "Relatório de notas.txt"])
        // Read as CP437, it comes out as Unzip One's "Relat≤rio".
        let wrong = ArchiveTree(listing: l, encoding: .cp437)
        #expect(wrong.roots.contains { $0.name == "Relat≤rio de notas.txt" })
    }

    @Test func cp850ZipDetected() async throws {
        let l = try await tool.list(fixture("cp850.zip"))
        #expect(NameDecoder.detect(l.items.map(\.diskPath)) == .cp850)
        let t = ArchiveTree(listing: l, encoding: .cp850)
        #expect(Set(t.roots.map(\.name)) == ["Matrícula 2026", "Relatório.txt"])
    }

    @Test func utf8NamesAreLeftAlone() {
        #expect(NameDecoder.detect(["Relatório.txt", "a/b.txt"]) == .utf8)
        #expect(NameDecoder.convert("Relatório.txt", using: .windows1252) == "Relatório.txt")
        #expect(NameDecoder.convert("Relat\u{EFF3}rio.txt", using: .windows1252) == "Relatório.txt")
        #expect(NameDecoder.convert("Relat\u{EFF3}rio.txt", using: .utf8) == "Relat\u{FFFD}rio.txt")
    }

    @Test func extractionFixesNamesOnDisk() async throws {
        let (dir, archive) = try staged("w1252.zip")
        defer { cleanup(dir) }
        let l = try await tool.list(archive)
        let r = try await Extractor.run(ExtractionPlan(archive: archive, listing: l, encoding: .windows1252),
                                        with: tool) { _ in }
        #expect(r.location.lastPathComponent == "w1252")
        #expect(tree(r.location) == ["Atenção", "Atenção/leia.txt", "Configuração.ini", "Relatório de notas.txt"])
        // nothing left behind (hidden working folder)
        #expect(tree(dir).filter { $0.hasPrefix(".kompac") }.isEmpty)
    }
}

// MARK: - Extraction

@Suite struct ExtractionTests {
    @Test func twoOfSixSelected() async throws {
        let (dir, archive) = try staged("six.zip")
        defer { cleanup(dir) }
        let l = try await tool.list(archive)
        let plan = ExtractionPlan(archive: archive, listing: l, rawPaths: ["f2.txt", "f5.txt"], diskPaths: ["f2.txt", "f5.txt"])
        let r = try await Extractor.run(plan, with: tool) { _ in }
        #expect(r.location.path == dir.appendingPathComponent("six").path)
        #expect(tree(r.location) == ["f2.txt", "f5.txt"])
        #expect(try String(contentsOf: r.location.appendingPathComponent("f5.txt"), encoding: .utf8) == "arquivo 5\n")
        #expect(tree(dir) == ["six", "six.zip", "six/f2.txt", "six/f5.txt"])
    }

    @Test func allSixGoIntoFolderNamedAfterArchive() async throws {
        let (dir, archive) = try staged("six.zip")
        defer { cleanup(dir) }
        let l = try await tool.list(archive)
        let progress = ProgressLog()
        let r = try await Extractor.run(ExtractionPlan(archive: archive, listing: l), with: tool) { progress.set($0) }
        #expect(tree(r.location).count == 6)
        #expect(progress.last == 1)
        // again: does not overwrite, creates "six 2"
        let r2 = try await Extractor.run(ExtractionPlan(archive: archive, listing: l), with: tool) { _ in }
        #expect(r2.location.lastPathComponent == "six 2")
    }

    @Test func singleRootFolderIsNotDoubled() async throws {
        let (dir, archive) = try staged("single.zip")
        defer { cleanup(dir) }
        let l = try await tool.list(archive)
        let r = try await Extractor.run(ExtractionPlan(archive: archive, listing: l), with: tool) { _ in }
        #expect(r.location.path == dir.appendingPathComponent("Projeto").path)
        #expect(tree(dir) == ["Projeto", "Projeto/b.txt", "Projeto/sub", "Projeto/sub/a.txt", "single.zip"])
    }

    @Test func selectedNestedItemComesOutAlone() async throws {
        let (dir, archive) = try staged("single.zip")
        defer { cleanup(dir) }
        let l = try await tool.list(archive)
        let plan = ExtractionPlan(archive: archive, listing: l, rawPaths: ["Projeto/sub"], diskPaths: ["Projeto/sub"])
        let r = try await Extractor.run(plan, with: tool) { _ in }
        #expect(r.location.path == dir.appendingPathComponent("sub").path)
        #expect(tree(r.location) == ["a.txt"])
    }

    @Test func tarGzSelection() async throws {
        let (dir, archive) = try staged("docs.tar.gz")
        defer { cleanup(dir) }
        let l = try await tool.list(archive)
        let t = ArchiveTree(listing: l, encoding: .utf8)
        let nodes = t.topMost(["docs", "docs/leia.txt"])
        #expect(nodes.map(\.id) == ["docs"])
        let plan = ExtractionPlan(archive: archive, listing: l, rawPaths: nodes.map(\.rawPath), diskPaths: nodes.map(\.id))
        let r = try await Extractor.run(plan, with: tool) { _ in }
        #expect(r.location.path == dir.appendingPathComponent("docs").path)
        #expect(tree(r.location) == ["leia.txt"])
        // everything: two top-level items → folder named after the archive ("docs"), which already exists → "docs 2".
        let all = try await Extractor.run(ExtractionPlan(archive: archive, listing: l), with: tool) { _ in }
        #expect(all.location.lastPathComponent == "docs 2")
        #expect(tree(all.location) == ["docs", "docs/leia.txt", "x.txt"])
    }

    @Test func encryptedNeedsRightPasswordAndLeavesNothingBehind() async throws {
        let (dir, archive) = try staged("rar5_encrypted_filenames.rar")
        defer { cleanup(dir) }
        let l = try await tool.list(archive, password: "password")
        await #expect(throws: ArchiveError.wrongPassword) {
            try await Extractor.run(ExtractionPlan(archive: archive, listing: l, password: "nao"), with: tool) { _ in }
        }
        #expect(tree(dir) == ["rar5_encrypted_filenames.rar"])
        let r = try await Extractor.run(ExtractionPlan(archive: archive, listing: l, password: "password"), with: tool) { _ in }
        #expect(tree(r.location) == ["a.txt", "b.txt", "c.txt", "d.txt"])
    }

    @Test func cancelRemovesPartialExtraction() async throws {
        // a file large enough to leave time to cancel
        let dir = try tempDir()
        defer { cleanup(dir) }
        let src = dir.appendingPathComponent("grande.bin")
        FileManager.default.createFile(atPath: src.path, contents: Data(count: 1))
        let h = try FileHandle(forWritingTo: src)
        let chunk = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 13) })
        for _ in 0..<400 { h.write(chunk) }
        try h.close()
        let archive = dir.appendingPathComponent("grande.7z")
        let p = Process()
        p.executableURL = tool.executable
        p.arguments = ["a", "-bso0", "-bsp0", "-mx=0", archive.path, src.path]
        try p.run(); p.waitUntilExit()
        try FileManager.default.removeItem(at: src)

        let l = try await tool.list(archive)
        let task = Task { try await Extractor.run(ExtractionPlan(archive: archive, listing: l), with: tool) { _ in } }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        await #expect(throws: ArchiveError.cancelled) { try await task.value }
        #expect(tree(dir) == ["grande.7z"])
    }

    @Test func names() {
        #expect(Extractor.baseName(of: "backup.tar.gz") == "backup")
        #expect(Extractor.baseName(of: "fotos.zip") == "fotos")
        #expect(Extractor.baseName(of: "Backup2026.rar") == "Backup2026")
    }

    /// Full extraction of the real, large RAR (`KOMPAC_REAL_RAR`).
    /// Only runs when `KOMPAC_BIG_EXTRACT=<temporary folder>` is set too.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["KOMPAC_BIG_EXTRACT"] != nil && RealRAR.path != nil))
    func realRARExtraction() async throws {
        let dest = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KOMPAC_BIG_EXTRACT"]!)
            .appendingPathComponent("kompac-big-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        defer { cleanup(dest) }
        let archive = URL(fileURLWithPath: RealRAR.path!)
        let l = try await tool.list(archive)
        let progress = ProgressLog()
        let start = Date()
        let r = try await Extractor.run(ExtractionPlan(archive: archive, listing: l, destination: dest), with: tool) {
            progress.set($0)
        }
        let seconds = Date().timeIntervalSince(start)
        print("\(archive.lastPathComponent) extracted in \(String(format: "%.1f", seconds)) s; \(progress.count) progress updates")
        // One top-level item lands directly in `dest`; several go into a folder named after the archive.
        let roots = Set(l.items.map { String($0.diskPath.split(separator: "/").first ?? "") })
        let base = roots.count == 1 ? dest : r.location
        for item in l.items where !item.isFolder {
            let path = base.appendingPathComponent(item.diskPath).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? UInt64
            #expect(size != nil, "not extracted: \(item.diskPath)")
            if let listed = item.size { #expect(size == listed, "\(item.diskPath): listed \(listed), extracted \(size ?? 0)") }
        }
        #expect(progress.count > 2)
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func set(_ v: Double) { lock.withLock { values.append(v) } }
    var last: Double? { lock.withLock { values.last } }
    var count: Int { lock.withLock { values.count } }
}

// MARK: - Preview

@Suite struct PreviewTests {
    @Test func textAndBinary() {
        #expect(PreviewText.decode(Data("Olá".utf8)) == "Olá")
        // cut in the middle of a 2-byte character
        #expect(PreviewText.decode(Data("Olá".utf8).dropLast(), truncated: true) == "Ol")
        #expect(PreviewText.decode(Data([0x4F, 0x6C, 0xE1])) == "Olá") // Windows-1252
        #expect(PreviewText.decode(Data([0x00, 0x01, 0x02, 0x03])) == nil)
    }

    @Test func headStopsAtLimit() async throws {
        let l = try await tool.list(fixture("w1252.zip"))
        let item = try #require(l.items.first { $0.diskPath.hasSuffix(".ini") })
        let d = try await tool.head(of: item.rawPath, in: fixture("w1252.zip"), listing: l, password: nil, limit: 5)
        #expect(d.count == 5)
    }
}
