import Cocoa
import FinderSync
import KompacCore

/// Finder extension: two items in the right-click menu of any file or folder, and two more when every
/// selected item is an archive. It only hands the selection to the app (`FinderRequest`); the
/// sandbox keeps it from compressing or extracting by itself.
final class FinderSync: FIFinderSync {
    /// Kompac.app, three levels above Contents/PlugIns/KompacFinder.appex.
    private let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    override init() {
        super.init()
        // The whole disk: the menu shows up in every folder, external volumes included.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems,
              let items = FIFinderSyncController.default().selectedItemURLs(), !items.isEmpty else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 16, height: 16)
        let menu = NSMenu(title: "")
        if items.allSatisfy(FinderRequest.isArchive) {
            menu.addItem(withTitle: NSLocalizedString("Extract Here", comment: "Finder menu: extract the selected archives next to them"),
                         action: #selector(extractHere(_:)), keyEquivalent: "").image = icon
            menu.addItem(withTitle: NSLocalizedString("Extract with Kompac…", comment: "Finder menu: open the selected archives in Kompac"),
                         action: #selector(openArchives(_:)), keyEquivalent: "").image = icon
        }
        let zip = ArchiveFormat.zip
        menu.addItem(withTitle: String(format: NSLocalizedString("Compress to “%@”", comment: "Finder menu: compress straight to a ZIP; %@ = archive file name"),
                                       Compressor.defaultName(for: items) + "." + zip.fileExtension),
                     action: #selector(compressToZip(_:)), keyEquivalent: "").image = icon
        menu.addItem(withTitle: NSLocalizedString("Compress with Kompac…", comment: "Finder menu: open the New window with the selected items"),
                     action: #selector(compressWithOptions(_:)), keyEquivalent: "").image = icon
        return menu
    }

    @objc func compressToZip(_ sender: AnyObject?) { send(.zip) }

    @objc func compressWithOptions(_ sender: AnyObject?) { send(.window) }

    @objc func extractHere(_ sender: AnyObject?) { send(.extractHere) }

    @objc func openArchives(_ sender: AnyObject?) { send(.open) }

    private func send(_ action: FinderRequest.Action) {
        guard let items = FIFinderSyncController.default().selectedItemURLs(), !items.isEmpty else { return }
        // This copy of the app, not whichever one Launch Services has for "kompac:".
        NSWorkspace.shared.open([FinderRequest(action: action, items: items).url], withApplicationAt: app,
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
