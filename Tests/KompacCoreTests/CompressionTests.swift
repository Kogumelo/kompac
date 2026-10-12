import Foundation
import Testing
@testable import KompacCore

/// Source folder with accents, a subfolder, a binary, an empty file, an empty folder and the macOS
/// junk that must not go into the archive.
func makeSources(in dir: URL) throws -> [URL] {
    let fm = FileManager.default
    let folder = dir.appendingPathComponent("Relatórios")
    try fm.createDirectory(at: folder.appendingPathComponent("2026/março"), withIntermediateDirectories: true)
    try fm.createDirectory(at: folder.appendingPathComponent("vazia"), withIntermediateDirectories: true)
    try fm.createDirectory(at: folder.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true)
    try "Relatório de vendas\n".write(to: folder.appendingPathComponent("leia-me.txt"), atomically: true, encoding: .utf8)
    // random: does not compress, and splitting into 20 KB parts yields more than one
    try Data((0..<70_000).map { _ in UInt8.random(in: 0...255) })
        .write(to: folder.appendingPathComponent("2026/março/dados.bin"))
    try Data().write(to: folder.appendingPathComponent("2026/vazio.txt"))
    for junk in [".DS_Store", "2026/.DS_Store", "._leia-me.txt", "__MACOSX/._x"] {
        try Data("lixo".utf8).write(to: folder.appendingPathComponent(junk))
    }
    let loose = dir.appendingPathComponent("avulso ção.txt")
    try "solto\n".write(to: loose, atomically: true, encoding: .utf8)
    return [folder, loose]
}

/// Compares two trees (names and bytes), ignoring the junk compression must leave out.
func expectSameContent(_ a: URL, _ b: URL, sourceLocation: SourceLocation = #_sourceLocation) {
    let fm = FileManager.default
    let left = tree(a).filter { !$0.split(separator: "/").contains { Compressor.isExcluded(String($0)) } }
    let right = tree(b)
    #expect(left == right, sourceLocation: sourceLocation)
    for rel in left {
        var isDir: ObjCBool = false
        fm.fileExists(atPath: a.appendingPathComponent(rel).path, isDirectory: &isDir)
        if isDir.boolValue { continue }
        let da = fm.contents(atPath: a.appendingPathComponent(rel).path)
        let db = fm.contents(atPath: b.appendingPathComponent(rel).path)
        #expect(da != nil && da == db, "content differs: \(rel)", sourceLocation: sourceLocation)
    }
}

func run(_ path: String, _ args: [String]) throws -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    // without a UTF-8 locale, bsdtar writes accents as \\303\\263
    p.environment = ["LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

@Suite struct CompressionTests {
    /// Create → list → extract → compare byte by byte, in all four formats.
    @Test(arguments: ArchiveFormat.allCases)
    func roundTrip(_ format: ArchiveFormat) async throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let src = dir.appendingPathComponent("origem")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let sources = try makeSources(in: src)
        let out = dir.appendingPathComponent("saida")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let progress = ProgressLog()
        let r = try await Compressor.run(CompressionPlan(sources: sources, format: format, destination: out,
                                                         name: "pacote"), with: tool) { progress.set($0) }
        #expect(r.location.lastPathComponent == "pacote." + format.fileExtension)
        #expect(r.parts == [r.location])
        #expect(r.warnings == nil)
        #expect(progress.last == 1)
        #expect(tree(out) == ["pacote." + format.fileExtension], "no intermediate .tar nor hidden partial file")

        let l = try await tool.list(r.location)
        #expect(l.compressedTar == (format == .tarGz || format == .tarXz))
        let names = l.items.map(\.diskPath)
        #expect(names.contains { $0.hasSuffix("dados.bin") })
        #expect(!names.contains { $0.split(separator: "/").contains { Compressor.isExcluded(String($0)) } },
                "macOS junk in the archive: \(names)")

        let extracted = try await Extractor.run(ExtractionPlan(archive: r.location, listing: l, destination: out),
                                                with: tool) { _ in }
        #expect(extracted.location.lastPathComponent == "pacote")
        expectSameContent(src, extracted.location)
    }

    @Test(arguments: [ArchiveFormat.zip, .sevenZip])
    func withPassword(_ format: ArchiveFormat) async throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let src = dir.appendingPathComponent("origem")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let sources = try makeSources(in: src)

        // ZIP: ASCII only (a 7zz limit); 7z accepts accents and symbols.
        let pw = format == .zip ? "s3gr3do!" : "s3gr€do"
        let plan = CompressionPlan(sources: sources, format: format, level: .maximum, password: pw,
                                   encryptNames: format == .sevenZip, destination: dir, name: "cofre")
        let r = try await Compressor.run(plan, with: tool) { _ in }

        if format == .sevenZip {
            // encrypted names: cannot even list without the password
            await #expect(throws: ArchiveError.passwordRequired) { try await tool.list(r.location) }
        } else {
            let l = try await tool.list(r.location)
            #expect(l.hasEncryptedItems)
            let slt = try run(tool.executable.path, ["l", "-slt", "-pnada", r.location.path]).out
            #expect(slt.contains("AES-256"))
        }
        let l = try await tool.list(r.location, password: pw)
        await #expect(throws: ArchiveError.wrongPassword) {
            try await Extractor.run(ExtractionPlan(archive: r.location, listing: l, destination: dir, password: "errada"),
                                    with: tool) { _ in }
        }
        let x = try await Extractor.run(ExtractionPlan(archive: r.location, listing: l, destination: dir,
                                                       password: pw), with: tool) { _ in }
        expectSameContent(src, x.location)
    }

    @Test func zipPasswordMustBeASCII() async throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let sources = try makeSources(in: dir)
        await #expect(throws: ArchiveError.self) {
            try await Compressor.run(CompressionPlan(sources: sources, format: .zip, password: "senha€"), with: tool) { _ in }
        }
        #expect(!tree(dir).contains { $0.hasSuffix(".zip") || $0.hasPrefix(".kompac-") })
    }

    @Test func tarRefusesPassword() async throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let sources = try makeSources(in: dir)
        await #expect(throws: ArchiveError.failed("The tar.gz format does not accept a password.")) {
            try await Compressor.run(CompressionPlan(sources: sources, format: .tarGz, password: "x"), with: tool) { _ in }
        }
        #expect(!tree(dir).contains { $0.hasSuffix(".tar.gz") || $0.hasSuffix(".tar") })
    }

    /// The same path Archive Utility (ditto) and the system bsdtar take.
    @Test func systemToolsOpenWhatWeCreate() async throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let src = dir.appendingPathComponent("origem")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let sources = try makeSources(in: src)

        let zip = try await Compressor.run(CompressionPlan(sources: sources, format: .zip, destination: dir), with: tool) { _ in }
        #expect(zip.location.lastPathComponent == "Archive.zip")
        let dittoOut = dir.appendingPathComponent("ditto")
        #expect(try run("/usr/bin/ditto", ["-x", "-k", zip.location.path, dittoOut.path]).status == 0)
        expectSameContent(src, dittoOut)

        for (format, flag) in [(ArchiveFormat.tarGz, "-tzf"), (.tarXz, "-tJf")] {
            let t = try await Compressor.run(CompressionPlan(sources: sources, format: format, destination: dir), with: tool) { _ in }
            let r = try run("/usr/bin/bsdtar", [flag, t.location.path])
            #expect(r.status == 0)
            #expect(r.out.contains("Relatórios/2026/março/dados.bin") || r.out.contains("Relato\u{301}rios/2026/marc\u{327}o/dados.bin"))
            #expect(!r.out.contains(".DS_Store"))
        }
    }

    @Test func existingNameIsNotOverwritten() async throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let sources = try makeSources(in: dir)
        try Data("antigo".utf8).write(to: dir.appendingPathComponent("Archive.7z"))
        let r = try await Compressor.run(CompressionPlan(sources: sources, format: .sevenZip), with: tool) { _ in }
        #expect(r.location.lastPathComponent == "Archive 2.7z")
        #expect(FileManager.default.contents(atPath: dir.appendingPathComponent("Archive.7z").path) == Data("antigo".utf8))
    }

    @Test func splitIntoVolumes() async throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let src = dir.appendingPathComponent("origem")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let sources = try makeSources(in: src)
        let plan = CompressionPlan(sources: sources, format: .sevenZip, level: .fast, volumeSize: 20_000,
                                   destination: dir, name: "partes")
        let r = try await Compressor.run(plan, with: tool) { _ in }
        #expect(r.parts.count > 1)
        #expect(r.parts.enumerated().allSatisfy { i, p in p.lastPathComponent == String(format: "partes.7z.%03d", i + 1) })
        #expect(!tree(dir).contains { $0.hasPrefix(".kompac-") })

        let l = try await tool.list(r.location)
        let x = try await Extractor.run(ExtractionPlan(archive: r.location, listing: l, destination: dir), with: tool) { _ in }
        expectSameContent(src, x.location)
    }

    @Test func cancelRemovesPartialArchive() async throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let src = dir.appendingPathComponent("grande.bin")
        FileManager.default.createFile(atPath: src.path, contents: Data(count: 1))
        let h = try FileHandle(forWritingTo: src)
        let chunk = Data((0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 13) })
        for _ in 0..<300 { h.write(chunk) }
        try h.close()

        for format in [ArchiveFormat.sevenZip, .tarXz] {
            let task = Task {
                try await Compressor.run(CompressionPlan(sources: [src], format: format, level: .maximum), with: tool) { _ in }
            }
            try await Task.sleep(for: .milliseconds(300))
            task.cancel()
            await #expect(throws: ArchiveError.cancelled) { try await task.value }
            #expect(tree(dir) == ["grande.bin"], "partial file left over for \(format)")
        }
    }

    @Test func defaultNames() throws {
        let dir = try tempDir()
        defer { cleanup(dir) }
        let sources = try makeSources(in: dir)
        #expect(Compressor.defaultName(for: [sources[0]]) == "Relatórios")
        #expect(Compressor.defaultName(for: [sources[1]]) == "avulso ção")
        #expect(Compressor.defaultName(for: sources) == "Archive")
        #expect(Compressor.isExcluded(".DS_Store") && Compressor.isExcluded("._foto.jpg") && Compressor.isExcluded("__MACOSX"))
        #expect(!Compressor.isExcluded("_normal.txt"))
    }
}
