import AppKit
import SwiftUI
import KompacCore

/// "New Compressed Archive" window: starts empty, takes dropped files and folders.
@MainActor
enum CompressWindow {
    /// Open windows (they are not NSDocuments, so someone has to hold on to them).
    private static var open: [NSWindowController] = []

    @discardableResult
    static func show(with urls: [URL] = []) -> CompressModel {
        let model = CompressModel()
        model.add(urls)
        let host = NSHostingController(rootView: CompressView(model: model))
        let window = NSWindow(contentViewController: host)
        window.title = NSLocalizedString("New Compressed Archive", comment: "Window title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 560))
        window.minSize = NSSize(width: 480, height: 460)
        window.isReleasedWhenClosed = false
        let wc = NSWindowController(window: window)
        wc.shouldCascadeWindows = true
        model.window = window
        open.append(wc)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                model.cancel()
                open.removeAll { $0 === wc }
            }
        }
        wc.showWindow(nil)
        window.center()
        return model
    }
}

struct CompressView: View {
    @Bindable var model: CompressModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if let notice = model.notice {
                HStack {
                    Image(systemName: "info.circle").foregroundStyle(Color.kompacWarn)
                    Text(notice).textSelection(.enabled)
                    Spacer()
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.kompacWarn.opacity(0.12))
                Divider()
            }
            if model.sources.isEmpty {
                emptyDropZone
            } else {
                SourceList(model: model)
                    .frame(minHeight: 110)
                Divider()
                OptionsForm(model: model)
                    .disabled(model.isRunning)
            }
            Divider()
            BottomBar(model: model)
        }
        .tint(.kompac)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(Color.kompac, lineWidth: 3).padding(3)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            model.add(files)
            return !files.isEmpty && !model.isRunning
        } isTargeted: { dropTargeted = $0 }
    }

    private var emptyDropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "archivebox").font(.system(size: 44)).foregroundStyle(Color.kompac)
            Text(NSLocalizedString("Drag files and folders here", comment: "Empty compress window")).font(.title3)
            Text(NSLocalizedString("They go into the archive with their current names.\n.DS_Store, ._* and __MACOSX are left out.", comment: "Empty compress window, below the title"))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(NSLocalizedString("Choose…", comment: "Button that opens a panel to pick items to compress")) { model.chooseSources() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SourceList: View {
    @Bindable var model: CompressModel

    var body: some View {
        List {
            ForEach(model.sources, id: \.self) { url in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.head).foregroundStyle(.secondary).font(.caption)
                    Button { model.remove(url) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(model.isRunning)
                        .help(NSLocalizedString("Remove from the list", comment: "Tooltip of the minus button next to an item"))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(Format.count(model.sources.count,
                                  NSLocalizedString("item", comment: "Item count, singular (after the number)"),
                                  NSLocalizedString("items", comment: "Item count, plural (after the number)"))).foregroundStyle(.secondary)
                Spacer()
                Button(NSLocalizedString("Add…", comment: "Button below the item list")) { model.chooseSources() }.disabled(model.isRunning)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)
        }
    }
}

private struct OptionsForm: View {
    @Bindable var model: CompressModel

    var body: some View {
        Form {
            Picker(NSLocalizedString("Format", comment: "Compress option label"), selection: $model.format) {
                ForEach(ArchiveFormat.allCases) { f in
                    Text(verbatim: "\(f.label) — \(f.detail)").tag(f)
                }
            }
            Picker(NSLocalizedString("Compression", comment: "Compress option label: level"), selection: $model.level) {
                ForEach(CompressionLevel.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            SecureField(NSLocalizedString("Password", comment: "Compress option label"), text: $model.password, prompt: Text(passwordPrompt))
                .disabled(!model.format.supportsPassword)
            if let issue = model.passwordIssue {
                Text(issue).font(.caption).foregroundStyle(Color.kompacWarn)
            }
            if model.format.supportsEncryptedNames {
                Toggle(NSLocalizedString("Encrypt file names too", comment: "Compress option"), isOn: $model.encryptNames)
                    .disabled(model.password.isEmpty)
                    .help(NSLocalizedString("Without the password, you cannot even see what is inside.", comment: "Tooltip of Encrypt file names too"))
            }
            if model.format.supportsVolumes {
                HStack {
                    Toggle(NSLocalizedString("Split into parts of", comment: "Compress option, followed by a number field and MB"), isOn: $model.split)
                    TextField(NSLocalizedString("MB", comment: "Unit: megabytes"), value: $model.splitMB, format: .number)
                        .frame(width: 70)
                        .disabled(!model.split)
                    Text(NSLocalizedString("MB", comment: "Unit: megabytes"))
                }
            }

            TextField(NSLocalizedString("Name", comment: "Compress option label: archive name"), text: $model.name)
            LabeledContent(NSLocalizedString("Destination", comment: "Compress option label")) {
                SwiftUI.Menu {
                    if let first = model.sources.first {
                        Button(String(format: NSLocalizedString("Next to the Originals (%@)", comment: "Destination menu item; %@ = folder name"), first.deletingLastPathComponent().lastPathComponent)) {
                            model.resetDestination()
                        }
                    }
                    Button(NSLocalizedString("Choose Another Folder…", comment: "Destination menu item")) { model.chooseDestination() }
                } label: {
                    Label(model.destination?.lastPathComponent ?? "—", systemImage: "folder")
                }
                .fixedSize()
                .help(model.destination?.path ?? "")
            }
            LabeledContent(NSLocalizedString("Will create", comment: "Compress option label: resulting file name")) {
                Text(model.fileName).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private var passwordPrompt: String {
        switch model.format {
        case .zip: return NSLocalizedString("optional (AES-256)", comment: "Password field placeholder")
        case .sevenZip: return NSLocalizedString("optional (AES-256)", comment: "Password field placeholder")
        case .tarGz, .tarXz: return NSLocalizedString("tar has no password", comment: "Password field placeholder")
        }
    }
}

private struct BottomBar: View {
    @Bindable var model: CompressModel

    var body: some View {
        HStack(spacing: 10) {
            if let p = model.progress {
                Text(NSLocalizedString("Compressing…", comment: "Bottom bar while compressing"))
                ProgressView(value: p).frame(maxWidth: 240)
                Text(verbatim: "\(Int(p * 100))%").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button(NSLocalizedString("Cancel", comment: "Button"), role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
            } else {
                if let r = model.result {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.kompac)
                    Text(r.parts.count > 1
                         ? String(format: NSLocalizedString("%ld parts created", comment: "Bottom bar after a split archive; %ld = number of parts"), r.parts.count)
                         : String(format: NSLocalizedString("Created: %@", comment: "Bottom bar after compressing; %@ = file name"), r.location.lastPathComponent))
                        .lineLimit(1).truncationMode(.middle)
                    Button(NSLocalizedString("Show in Finder", comment: "Button")) { model.reveal() }
                    Button(NSLocalizedString("Open", comment: "Button: opens the created archive")) { model.openResult() }
                }
                Spacer()
                Button(NSLocalizedString("Compress", comment: "Button: starts compressing")) { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStart)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
        .background(.bar)
    }
}
