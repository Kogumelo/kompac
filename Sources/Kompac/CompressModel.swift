import AppKit
import Observation
import KompacCore

/// State of the "New Compressed Archive" window. Used only on the main thread.
@MainActor
@Observable
final class CompressModel {
    private(set) var sources: [URL] = []
    var format: ArchiveFormat = .zip
    var level: CompressionLevel = .normal
    var password = ""
    var encryptNames = true
    var split = false
    /// Size of each part, in MB (1000 × 1000 bytes, like the Finder).
    var splitMB = 100
    /// Name without extension; follows the items until the user types another one.
    var name = NSLocalizedString("Archive", comment: "Default name of a new archive, before any item is added") { didSet { if name != autoName { nameEdited = true } } }
    private(set) var destination: URL?
    private(set) var progress: Double?
    private(set) var result: CompressionResult?
    var notice: String?

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var nameEdited = false
    @ObservationIgnored private var autoName = NSLocalizedString("Archive", comment: "Default name of a new archive, before any item is added")
    @ObservationIgnored private var destinationChosen = false
    @ObservationIgnored private let tool = SevenZip.locate()
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Called when finished (self-test).
    @ObservationIgnored var onFinish: (() -> Void)?

    var isRunning: Bool { progress != nil }
    var canStart: Bool {
        !sources.isEmpty && !isRunning && !name.trimmingCharacters(in: .whitespaces).isEmpty && destination != nil
    }
    var fileName: String { name.trimmingCharacters(in: .whitespaces) + "." + format.fileExtension + (usesVolumes ? ".001…" : "") }
    private var usesVolumes: Bool { format.supportsVolumes && split }

    /// Warning about the chosen password, before compressing.
    var passwordIssue: String? {
        guard format == .zip, !password.allSatisfy(\.isASCII) else { return nil }
        return NSLocalizedString("A ZIP password only accepts unaccented letters, digits and common symbols. To use accents, choose 7z.", comment: "Warning under the password field")
    }

    // MARK: Items

    /// Adds items (dropped or chosen), without duplicates and without the macOS junk.
    func add(_ urls: [URL]) {
        guard !isRunning else { return }
        let known = Set(sources.map(\.standardizedFileURL.path))
        let new = urls.map(\.standardizedFileURL)
            .filter { !known.contains($0.path) && !Compressor.isExcluded($0.lastPathComponent) }
        guard !new.isEmpty else { return }
        sources += new
        result = nil
        sourcesChanged()
    }

    func remove(_ url: URL) {
        guard !isRunning else { return }
        sources.removeAll { $0 == url }
        result = nil
        sourcesChanged()
    }

    private func sourcesChanged() {
        autoName = Compressor.defaultName(for: sources)
        if !nameEdited { name = autoName }
        if !destinationChosen { destination = sources.first?.deletingLastPathComponent() }
    }

    func chooseSources() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = NSLocalizedString("Add", comment: "Open panel button for choosing items to compress")
        panel.message = NSLocalizedString("Files and folders to compress", comment: "Open panel message")
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            if r == .OK { self?.add(panel.urls) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = NSLocalizedString("Choose", comment: "Open panel button for choosing the destination folder")
        panel.message = String(format: NSLocalizedString("Where to save %@", comment: "Open panel message; %@ = archive file name"), fileName)
        panel.directoryURL = destination
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            if r == .OK, let u = panel.url {
                self?.destination = u
                self?.destinationChosen = true
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    func resetDestination() {
        destinationChosen = false
        destination = sources.first?.deletingLastPathComponent()
    }

    // MARK: Compress

    func start() {
        guard canStart, let destination else { return }
        guard let tool else {
            notice = ArchiveError.toolNotFound.localizedDescription
            return
        }
        if let issue = passwordIssue {
            notice = issue
            return
        }
        let pw = format.supportsPassword && !password.isEmpty ? password : nil
        let plan = CompressionPlan(sources: sources, format: format, level: level, password: pw,
                                   encryptNames: pw != nil && format.supportsEncryptedNames && encryptNames,
                                   volumeSize: usesVolumes ? UInt64(max(splitMB, 1)) * 1_000_000 : nil,
                                   destination: destination, name: name.trimmingCharacters(in: .whitespaces))
        notice = nil
        result = nil
        progress = 0
        task = Task {
            do {
                let r = try await Compressor.run(plan, with: tool) { p in
                    Task { @MainActor in if self.progress != nil { self.progress = p } }
                }
                result = r
                if let w = r.warnings { notice = String(format: NSLocalizedString("Created, with warnings from 7zz: %@", comment: "Notice after compressing; %@ = 7zz warning text"), w) }
            } catch ArchiveError.cancelled {
                notice = NSLocalizedString("Cancelled. The partial archive was deleted.", comment: "Notice after cancelling compression")
            } catch {
                notice = String(format: NSLocalizedString("Compression failed: %@", comment: "Notice; %@ = error message"), error.localizedDescription)
            }
            progress = nil
            onFinish?()
        }
    }

    func cancel() { task?.cancel() }

    func reveal() {
        guard let result else { return }
        NSWorkspace.shared.activateFileViewerSelecting(result.parts)
    }

    /// Opens the result in a Kompac window, to check its contents.
    func openResult() {
        guard let result else { return }
        NSDocumentController.shared.openDocument(withContentsOf: result.location, display: true) { _, _, _ in }
    }
}
