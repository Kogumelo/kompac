import AppKit
import Observation
import KompacCore

/// What the password was asked for: when the sheet closes, that action resumes.
enum PasswordPurpose: Equatable {
    case open
    case extract(selectedOnly: Bool)
    case preview
}

struct PasswordPrompt: Identifiable {
    let id = UUID()
    var purpose: PasswordPurpose
    var error: String?
}

enum Phase: Equatable {
    case loading
    case ready
    case needsPassword
    case failed(String)
}

enum PreviewState {
    case none
    case loading(ArchiveNode)
    case text(ArchiveNode, String, truncated: Bool)
    case info(ArchiveNode, String)
}

struct ExtractionState {
    var progress: Double = 0
    var label: String
}

/// State of one window. Used on the main thread only.
@MainActor
@Observable
final class WindowModel {
    let url: URL
    private(set) var phase: Phase = .loading
    private(set) var listing: ArchiveListing?
    private(set) var tree: ArchiveTree?
    var selection: Set<String> = [] { didSet { if selection != oldValue { updatePreview() } } }
    private(set) var preview: PreviewState = .none

    /// Choice in the "Names in" picker.
    var encodingChoice: NameEncoding = .automatic { didSet { if encodingChoice != oldValue { rebuildTree() } } }
    /// What automatic mode picked.
    private(set) var detected: NameEncoding = .utf8
    /// Some name came with non-UTF-8 bytes (Windows ZIP).
    private(set) var hasForeignNames = false
    var effectiveEncoding: NameEncoding { encodingChoice == .automatic ? detected : encodingChoice }

    var destination: URL
    var passwordPrompt: PasswordPrompt?
    private(set) var extraction: ExtractionState?
    private(set) var lastResult: URL?
    /// Notice in the top banner (extraction error, cancellation…).
    var notice: String?

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var password: String?
    @ObservationIgnored private let tool = SevenZip.locate()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var extractTask: Task<Void, Never>?
    @ObservationIgnored let archiveSize: UInt64

    init(url: URL) {
        self.url = url
        destination = url.deletingLastPathComponent()
        password = SelfTest.password
        archiveSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    var canExtract: Bool { phase == .ready && extraction == nil && !(listing?.items.isEmpty ?? true) }

    // MARK: Open

    func load() {
        guard let tool else {
            phase = .failed(ArchiveError.toolNotFound.localizedDescription)
            SelfTest.report(self)
            return
        }
        phase = .loading
        loadTask?.cancel()
        loadTask = Task {
            do {
                let l = try await tool.list(url, password: password)
                listing = l
                let names = l.items.map(\.diskPath)
                hasForeignNames = names.contains(where: NameDecoder.hasRawBytes)
                detected = NameDecoder.detect(names)
                rebuildTree()
                phase = .ready
            } catch ArchiveError.passwordRequired {
                phase = .needsPassword
                askPassword(for: .open, error: nil)
            } catch ArchiveError.wrongPassword {
                phase = .needsPassword
                askPassword(for: .open, error: NSLocalizedString("Wrong password. Try again.", comment: "Password sheet error"))
            } catch is CancellationError {
                return
            } catch {
                phase = .failed(error.localizedDescription)
            }
            SelfTest.report(self)
        }
    }

    private func rebuildTree() {
        guard let listing else { return }
        tree = ArchiveTree(listing: listing, encoding: effectiveEncoding)
        selection = selection.filter { tree?.byID[$0] != nil }
        updatePreview()
    }

    // MARK: Password

    func askPassword(for purpose: PasswordPurpose, error: String?) {
        passwordPrompt = PasswordPrompt(purpose: purpose, error: error)
    }

    func submitPassword(_ pw: String, for purpose: PasswordPurpose) {
        password = pw
        passwordPrompt = nil
        switch purpose {
        case .open: load()
        case .extract(let selectedOnly): extract(selectedOnly: selectedOnly)
        case .preview: updatePreview()
        }
    }

    func cancelPassword() {
        passwordPrompt = nil
    }

    // MARK: Preview

    private func updatePreview() {
        previewTask?.cancel()
        guard let tree, let tool, let listing, selection.count == 1, let node = tree.byID[selection.first!] else {
            preview = .none
            return
        }
        if node.isFolder {
            var files = 0, folders = 0
            node.children?.forEach { $0.walk { n in if n.isFolder { folders += 1 } else { files += 1 } } }
            preview = .info(node, String(format: NSLocalizedString("Folder · %@, %@ · %@", comment: "Preview of a selected folder; %1$@ = file count, %2$@ = folder count, %3$@ = total size"),
                                         Format.count(files, NSLocalizedString("file", comment: "Count noun, singular (\"1 file\")"), NSLocalizedString("files", comment: "Count noun, plural (\"3 files\")")),
                                         Format.count(folders, NSLocalizedString("folder", comment: "Count noun, singular (\"1 folder\")"), NSLocalizedString("folders", comment: "Count noun, plural (\"3 folders\")")), Format.bytes(node.size)))
            return
        }
        if node.encrypted && password == nil {
            preview = .info(node, String(format: NSLocalizedString("%@ · %@ · password protected", comment: "Preview of an encrypted file; %1$@ = file kind, %2$@ = size"), PreviewText.kind(of: node.name), Format.bytes(node.size)))
            return
        }
        if node.size == 0 {
            preview = .text(node, "", truncated: false)
            return
        }
        preview = .loading(node)
        let limit = 16 * 1024
        let pw = password
        previewTask = Task {
            do {
                let data = try await tool.head(of: node.rawPath, in: url, listing: listing, password: pw, limit: limit)
                guard !Task.isCancelled else { return }
                let truncated = data.count >= limit
                if let text = PreviewText.decode(data, truncated: truncated) {
                    preview = .text(node, text, truncated: truncated)
                } else {
                    preview = .info(node, String(format: NSLocalizedString("%@ · %@ · no preview (binary content)", comment: "Preview of a binary file; %1$@ = file kind, %2$@ = size"), PreviewText.kind(of: node.name), Format.bytes(node.size)))
                }
            } catch is CancellationError {
            } catch ArchiveError.cancelled {
            } catch ArchiveError.passwordRequired, ArchiveError.wrongPassword {
                guard !Task.isCancelled else { return }
                preview = .info(node, String(format: NSLocalizedString("%@ · %@ · password protected", comment: "Preview of an encrypted file; %1$@ = file kind, %2$@ = size"), PreviewText.kind(of: node.name), Format.bytes(node.size)))
            } catch {
                guard !Task.isCancelled else { return }
                preview = .info(node, String(format: NSLocalizedString("Could not read: %@", comment: "Preview error; %@ = error message"), error.localizedDescription))
            }
        }
    }

    // MARK: Extract

    func extract(selectedOnly: Bool) {
        guard canExtract, let tool, let listing, let tree else { return }
        let nodes = selectedOnly ? tree.topMost(selection) : []
        if selectedOnly && nodes.isEmpty {
            notice = NSLocalizedString("Select items in the list first.", comment: "Top banner notice")
            return
        }
        // Encrypted item and no password yet: ask before starting.
        if password == nil {
            var encrypted = false
            if selectedOnly { nodes.forEach { $0.walk { if $0.encrypted { encrypted = true } } } } else { encrypted = listing.hasEncryptedItems }
            if encrypted {
                askPassword(for: .extract(selectedOnly: selectedOnly), error: nil)
                return
            }
        }
        let plan = ExtractionPlan(archive: url, listing: listing, rawPaths: nodes.map(\.rawPath),
                                  diskPaths: nodes.map(\.id), destination: destination,
                                  encoding: effectiveEncoding, password: password)
        notice = nil
        lastResult = nil
        extraction = ExtractionState(label: selectedOnly
            ? String(format: NSLocalizedString("Extracting %@…", comment: "Extraction progress label; %@ = item count such as \"3 items\""), Format.count(nodes.count, NSLocalizedString("item", comment: "Count noun, singular (\"1 item\")"), NSLocalizedString("items", comment: "Count noun, plural (\"3 items\")")))
            : NSLocalizedString("Extracting everything…", comment: "Extraction progress label"))
        extractTask = Task {
            do {
                let r = try await Extractor.run(plan, with: tool) { p in
                    Task { @MainActor in self.extraction?.progress = p }
                }
                lastResult = r.location
            } catch ArchiveError.cancelled {
                notice = NSLocalizedString("Extraction cancelled. Nothing was written.", comment: "Top banner notice")
            } catch ArchiveError.passwordRequired {
                askPassword(for: .extract(selectedOnly: selectedOnly), error: nil)
            } catch ArchiveError.wrongPassword {
                password = nil
                askPassword(for: .extract(selectedOnly: selectedOnly), error: NSLocalizedString("Wrong password. Try again.", comment: "Password sheet error"))
            } catch {
                notice = String(format: NSLocalizedString("Extraction failed: %@", comment: "Top banner notice; %@ = error message"), error.localizedDescription)
            }
            extraction = nil
        }
    }

    func cancelExtraction() { extractTask?.cancel() }

    func cancelAll() {
        loadTask?.cancel()
        previewTask?.cancel()
        extractTask?.cancel()
    }

    func revealLastResult() {
        guard let lastResult else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastResult])
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = NSLocalizedString("Choose", comment: "Destination panel button")
        panel.message = String(format: NSLocalizedString("Where to extract the contents of %@", comment: "Destination panel message; %@ = archive file name"), url.lastPathComponent)
        panel.directoryURL = destination
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            if r == .OK, let u = panel.url { self?.destination = u }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    func resetDestination() { destination = url.deletingLastPathComponent() }

    // MARK: Texts

    var encodingSummary: String {
        if encodingChoice == .automatic {
            let automatic = NSLocalizedString("Automatic (%@)", comment: "Name encoding summary; %@ = encoding picked, such as UTF-8")
            return String(format: automatic, hasForeignNames ? detected.shortLabel : "UTF-8")
        }
        return encodingChoice.shortLabel
    }

    var footerText: String {
        guard let listing else { return "" }
        let files = listing.fileCount
        let folders = tree.map { t in var n = 0; t.roots.forEach { $0.walk { if $0.isFolder { n += 1 } } }; return n } ?? 0
        var parts = [Format.count(files, NSLocalizedString("file", comment: "Count noun, singular (\"1 file\")"), NSLocalizedString("files", comment: "Count noun, plural (\"3 files\")"))]
        if folders > 0 { parts[0] += ", " + Format.count(folders, NSLocalizedString("folder", comment: "Count noun, singular (\"1 folder\")"), NSLocalizedString("folders", comment: "Count noun, plural (\"3 folders\")")) }
        let total = listing.totalSize
        if total > 0 && archiveSize > 0 {
            let saved = 1 - Double(archiveSize) / Double(total)
            let ratio = saved > 0.005
                ? String(format: NSLocalizedString("%ld%% smaller", comment: "Footer compression ratio; %ld = percent saved"), Int((saved * 100).rounded()))
                : NSLocalizedString("no compression", comment: "Footer compression ratio when nothing was saved")
            parts.append("\(Format.bytes(total)) → \(Format.bytes(archiveSize)) (\(ratio))")
        }
        parts.append(listing.type)
        return parts.joined(separator: " · ")
    }
}

enum Format {
    private static let number: NumberFormatter = {
        // the system's region: "48,3 MB" in Brazil, "48.3 MB" in the US
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 1
        return f
    }()

    private static let date: DateFormatter = {
        // short date and time in the system's region (dd/MM/yyyy HH:mm in Brazil)
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    /// "48,3 MB" (multiples of 1000, like the Finder).
    static func bytes(_ n: UInt64?) -> String {
        guard let n else { return "—" }
        if n < 1000 { return String(format: NSLocalizedString("%ld bytes", comment: "Size under 1 KB; %ld = byte count"), Int(n)) }
        let units = ["KB", "MB", "GB", "TB"]
        var v = Double(n) / 1000, i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        number.maximumFractionDigits = v < 100 ? 1 : 0
        return "\(number.string(from: v as NSNumber) ?? "\(v)") \(units[i])"
    }

    static func date(_ d: Date?) -> String { d.map { date.string(from: $0) } ?? "" }

    static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(number.string(from: n as NSNumber) ?? "\(n)") \(n == 1 ? singular : plural)"
    }
}
