import AppKit
import SwiftUI
import KompacCore

/// An open archive, read-only. Does not load the file into memory (it may be
/// gigabytes): keeps only its location and lets 7zz read it.
final class Document: NSDocument {
    private(set) var model: WindowModel?

    override class var autosavesInPlace: Bool { false }
    override class var readableTypes: [String] { ["public.data"] }
    override class func isNativeType(_ type: String) -> Bool { false }

    override func read(from url: URL, ofType typeName: String) throws {
        let m = MainActor.assumeIsolated { WindowModel(url: url) }
        model = m
    }

    override func data(ofType typeName: String) throws -> Data {
        throw CocoaError(.featureUnsupported)
    }

    override func makeWindowControllers() {
        guard let model else { return }
        let host = NSHostingController(rootView: WindowView(model: model))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 860, height: 620))
        window.minSize = NSSize(width: 560, height: 380)
        let wc = NSWindowController(window: window)
        wc.shouldCascadeWindows = true
        addWindowController(wc)
        // The autosave name is a defaults key, not UI: kept as is so saved window frames survive.
        window.setFrameAutosaveName("kompac.janela")
        model.window = window
        model.load()
    }

    override func close() {
        model?.cancelAll()
        super.close()
    }

    // MARK: Extract menu

    @objc func extractSelected(_ sender: Any?) { model?.extract(selectedOnly: true) }
    @objc func extractAll(_ sender: Any?) { model?.extract(selectedOnly: false) }
    @objc func chooseDestination(_ sender: Any?) { model?.chooseDestination() }
    @objc func revealExtracted(_ sender: Any?) { model?.revealLastResult() }
    @objc func enterPassword(_ sender: Any?) { model?.askPassword(for: .open, error: nil) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let model else { return super.validateUserInterfaceItem(item) }
        switch item.action {
        case #selector(extractSelected(_:)): return model.canExtract && !model.selection.isEmpty
        case #selector(extractAll(_:)): return model.canExtract
        case #selector(chooseDestination(_:)): return model.extraction == nil
        case #selector(revealExtracted(_:)): return model.lastResult != nil
        case #selector(enterPassword(_:)): return model.extraction == nil
        default: return super.validateUserInterfaceItem(item)
        }
    }
}
