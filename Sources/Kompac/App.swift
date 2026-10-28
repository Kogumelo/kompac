import AppKit
import KompacCore

/// Entry point: AppKit document app, menu built in code (no nib).
@main
@MainActor
enum App {
    static let delegate = AppDelegate()

    static func main() {
        // The first NSDocumentController created becomes `shared`.
        _ = DocumentController()
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.mainMenu = Menu.mainMenu()
        app.run()
    }
}

/// Every window is a `Document`, whatever the type: the Open panel accepts any file
/// (7zz recognizes the format by its content, and `.zst` has no system type).
final class DocumentController: NSDocumentController {
    override func documentClass(forType typeName: String) -> AnyClass? { Document.self }

    override func typeForContents(of url: URL) throws -> String {
        (try? super.typeForContents(of: url)) ?? "public.data"
    }

    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?,
                                 completionHandler: @escaping (Int) -> Void) {
        openPanel.message = NSLocalizedString("Choose an archive to open", comment: "Open panel message")
        super.beginOpenPanel(openPanel, forTypes: nil, completionHandler: completionHandler)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Launched (or reached) by the Finder extension: no Open panel, even after a quick ZIP has
    /// already closed its window.
    private var gotFinderRequest = false

    /// `kompac:` URLs come as an Apple event; files to open still go to NSDocumentController.
    func applicationWillFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    /// From the Finder extension: compress straight to ZIP, or open the New window with the items;
    /// extract each archive next to it, or open each one in its window.
    @objc func handleURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text), let request = FinderRequest(url: url) else { return }
        gotFinderRequest = true
        NSApp.activate()
        switch request.action {
        case .zip, .window:
            let model = CompressWindow.show(with: request.items)
            if request.action == .zip {
                model.closesWhenDone = true
                model.start()
            }
        case .extractHere, .open:
            for item in request.items {
                NSDocumentController.shared.openDocument(withContentsOf: item, display: true) { doc, _, _ in
                    if request.action == .extractHere { (doc as? Document)?.model?.extractAllWhenReady() }
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if CompressSelfTest.output != nil {
            CompressSelfTest.run()
            return
        }
        // Launched without a file (from the Dock or Launchpad): show the Open panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if NSDocumentController.shared.documents.isEmpty && !self.gotFinderRequest && SelfTest.output == nil {
                NSDocumentController.shared.openDocument(nil)
            }
        }
    }

    /// About Kompac: the standard panel, with the build commit (stamped by build.sh) next to the
    /// build number, as in "(42 · 1a2b3c4)".
    @objc func showAbout(_ sender: Any?) {
        let info = Bundle.main.infoDictionary ?? [:]
        var build = info["CFBundleVersion"] as? String ?? ""
        if let c = info["KompacCommit"] as? String { build += " · \(c)" }
        NSApp.orderFrontStandardAboutPanel(options: [.version: build])
    }

    /// File › New: empty window that takes files and folders to compress.
    @objc func newArchive(_ sender: Any?) { CompressWindow.show() }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { NSDocumentController.shared.openDocument(nil) }
        return false
    }

    /// Read-only: nothing to save on quit; extractions in progress are cancelled by the document.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// `KOMPAC_SELFTEST=<output file>`: once the first document finishes listing, writes a
/// summary of what the window shows and exits. Used to test opening through Launch Services
/// (`open -a Kompac.app --env KOMPAC_SELFTEST=… archive`), the same path the Finder takes.
/// `KOMPAC_SELFTEST_PASSWORD`: password already given on open (self-test only).
@MainActor
enum SelfTest {
    static let output = ProcessInfo.processInfo.environment["KOMPAC_SELFTEST"].map(URL.init(fileURLWithPath:))
    static var password: String? {
        output == nil ? nil : ProcessInfo.processInfo.environment["KOMPAC_SELFTEST_PASSWORD"]
    }

    static func report(_ model: WindowModel) {
        guard let output else { return }
        var lines = ["archive: \(model.url.path)"]
        switch model.phase {
        case .loading: return
        case .failed(let msg): lines.append("error: \(msg)")
        case .needsPassword: lines.append("asks for password")
        case .ready:
            lines.append("type: \(model.listing?.type ?? "?")")
            lines.append("names: \(model.encodingSummary)")
            lines.append("footer: \(model.footerText)")
            model.tree?.roots.forEach { root in
                root.walk { n in
                    let depth = n.id.split(separator: "/").count - 1
                    lines.append(String(repeating: "  ", count: depth) + n.name + (n.isFolder ? "/" : "")
                                 + " \(n.size.map(String.init) ?? "-")")
                }
            }
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
        // exit, not NSApp.terminate: with the password sheet open, AppKit postpones termination.
        exit(0)
    }
}

/// `KOMPAC_SELFTEST_COMPRESS=<output file>`: opens the New window, adds the items from
/// `KOMPAC_SELFTEST_SOURCES` (paths separated by "|"), compresses in the format
/// `KOMPAC_SELFTEST_FORMAT` (zip, 7z, tar.gz, tar.xz) with optional `KOMPAC_SELFTEST_PASSWORD`,
/// writes the result and exits.
@MainActor
enum CompressSelfTest {
    static let env = ProcessInfo.processInfo.environment
    static let output = env["KOMPAC_SELFTEST_COMPRESS"].map(URL.init(fileURLWithPath:))

    static func run() {
        guard let output else { return }
        let sources = (env["KOMPAC_SELFTEST_SOURCES"] ?? "").split(separator: "|").map { URL(fileURLWithPath: String($0)) }
        let model = CompressWindow.show(with: sources)
        model.format = ArchiveFormat(rawValue: env["KOMPAC_SELFTEST_FORMAT"] ?? "zip") ?? .zip
        model.password = env["KOMPAC_SELFTEST_PASSWORD"] ?? ""
        model.onFinish = {
            var lines = ["window: \(model.window?.title ?? "?")", "items: \(model.sources.map(\.lastPathComponent))"]
            if let r = model.result {
                lines += ["created: \(r.location.path)"] + r.parts.dropFirst().map { "part: \($0.path)" }
            }
            if let n = model.notice { lines.append("notice: \(n)") }
            try? (lines.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
            exit(0)
        }
        model.start()
        if !model.isRunning { model.onFinish?() }
    }
}

@MainActor
enum Menu {
    static func item(_ title: String, _ action: Selector?, _ keyEq: String = "",
                     _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: keyEq)
        i.keyEquivalentModifierMask = mods
        return i
    }

    static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = m
        return i
    }

    static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let name = "Kompac"

        main.addItem(submenu(name, [
            item(String(format: NSLocalizedString("About %@", comment: "App menu; %@ = app name"), name), #selector(AppDelegate.showAbout(_:))),
            .separator(),
            item(String(format: NSLocalizedString("Hide %@", comment: "App menu; %@ = app name"), name), #selector(NSApplication.hide(_:)), "h"),
            item(NSLocalizedString("Hide Others", comment: "App menu"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(NSLocalizedString("Show All", comment: "App menu"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(String(format: NSLocalizedString("Quit %@", comment: "App menu; %@ = app name"), name), #selector(NSApplication.terminate(_:)), "q"),
        ]))

        let recents = submenu(NSLocalizedString("Open Recent", comment: "File menu submenu"), [
            item(NSLocalizedString("Clear Menu", comment: "File › Open Recent menu"), #selector(NSDocumentController.clearRecentDocuments(_:))),
        ])
        main.addItem(submenu(NSLocalizedString("File", comment: "Menu title"), [
            item(NSLocalizedString("New…", comment: "File menu: new compress window"), #selector(AppDelegate.newArchive(_:)), "n"),
            item(NSLocalizedString("Open…", comment: "File menu"), #selector(NSDocumentController.openDocument(_:)), "o"),
            recents,
            .separator(),
            item(NSLocalizedString("Close", comment: "File menu"), #selector(NSWindow.performClose(_:)), "w"),
        ]))

        main.addItem(submenu(NSLocalizedString("Edit", comment: "Menu title"), [
            item(NSLocalizedString("Copy", comment: "Edit menu"), #selector(NSText.copy(_:)), "c"),
            item(NSLocalizedString("Select All", comment: "Edit menu"), #selector(NSText.selectAll(_:)), "a"),
        ]))

        main.addItem(submenu(NSLocalizedString("Extract", comment: "Menu title"), [
            item(NSLocalizedString("Extract Selected", comment: "Extract menu"), #selector(Document.extractSelected(_:)), "e"),
            item(NSLocalizedString("Extract All", comment: "Extract menu"), #selector(Document.extractAll(_:)), "e", [.command, .shift]),
            .separator(),
            item(NSLocalizedString("Choose Destination…", comment: "Extract menu"), #selector(Document.chooseDestination(_:)), "d", [.command, .shift]),
            item(NSLocalizedString("Show Extracted in Finder", comment: "Extract menu"), #selector(Document.revealExtracted(_:)), "r"),
            .separator(),
            item(NSLocalizedString("Enter Password…", comment: "Extract menu"), #selector(Document.enterPassword(_:))),
        ]))

        let window = submenu(NSLocalizedString("Window", comment: "Menu title"), [
            item(NSLocalizedString("Minimize", comment: "Window menu"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(NSLocalizedString("Zoom", comment: "Window menu"), #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(NSLocalizedString("Bring All to Front", comment: "Window menu"), #selector(NSApplication.arrangeInFront(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        return main
    }
}
