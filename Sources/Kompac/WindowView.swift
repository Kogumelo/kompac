import AppKit
import SwiftUI
import UniformTypeIdentifiers
import KompacCore

/// Kogumelo green and warning orange (from the mockup), lighter in dark mode.
extension Color {
    static let kompac = adaptive(light: (0.18, 0.42, 0.34), dark: (0.49, 0.77, 0.66))
    static let kompacWarn = adaptive(light: (0.64, 0.34, 0.11), dark: (0.89, 0.63, 0.42))

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

struct WindowView: View {
    @Bindable var model: WindowModel

    var body: some View {
        VStack(spacing: 0) {
            ToolRow(model: model)
            Divider()
            if let notice = model.notice {
                NoticeBar(text: notice) { model.notice = nil }
                Divider()
            }
            content
            Divider()
            FooterBar(model: model)
        }
        .tint(.kompac)
        .sheet(item: $model.passwordPrompt) { prompt in
            PasswordSheet(fileName: model.url.lastPathComponent, prompt: prompt,
                          submit: { model.submitPassword($0, for: prompt.purpose) },
                          cancel: { model.cancelPassword() })
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                Text(NSLocalizedString("Reading contents…", comment: "Shown while the archive listing loads")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsPassword:
            ContentUnavailableView {
                Label(NSLocalizedString("Password protected", comment: "Title when the archive has encrypted names"), systemImage: "lock")
            } description: {
                Text(NSLocalizedString("Even the file names are encrypted. Enter the password to see the contents.", comment: "Description when the archive has encrypted names"))
            } actions: {
                Button(NSLocalizedString("Enter Password…", comment: "Button that opens the password sheet")) { model.askPassword(for: .open, error: nil) }
                    .buttonStyle(.borderedProminent)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label(NSLocalizedString("Could not open", comment: "Title when the archive cannot be read"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .ready:
            VSplitView {
                ItemTable(model: model)
                    .frame(minHeight: 160)
                PreviewPane(state: model.preview)
                    .frame(minHeight: 70, idealHeight: 150)
            }
        }
    }
}

// MARK: - Action bar

private struct ToolRow: View {
    @Bindable var model: WindowModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.extract(selectedOnly: true)
            } label: {
                Label(NSLocalizedString("Extract Selected", comment: "Toolbar button"), systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canExtract || model.selection.isEmpty)
            .help(NSLocalizedString("Extracts the items selected in the list (⌘E)", comment: "Tooltip of Extract Selected"))

            Button {
                model.extract(selectedOnly: false)
            } label: {
                Label(NSLocalizedString("Extract All", comment: "Toolbar button"), systemImage: "archivebox")
            }
            .disabled(!model.canExtract)
            .help(NSLocalizedString("Extracts all contents (⇧⌘E)", comment: "Tooltip of Extract All"))

            SwiftUI.Menu {
                Button(String(format: NSLocalizedString("Archive's Folder (%@)", comment: "Destination menu item; %@ = name of the folder containing the archive"), model.url.deletingLastPathComponent().lastPathComponent)) {
                    model.resetDestination()
                }
                Button(NSLocalizedString("Choose Another Folder…", comment: "Destination menu item")) { model.chooseDestination() }
            } label: {
                Label(model.destination.lastPathComponent, systemImage: "folder")
            }
            .fixedSize()
            .disabled(model.extraction != nil)
            .help(String(format: NSLocalizedString("Destination: %@", comment: "Tooltip of the destination menu; %@ = folder path"), model.destination.path))

            Spacer(minLength: 12)

            Text(NSLocalizedString("Names in", comment: "Label before the name encoding picker")).foregroundStyle(.secondary)
            Picker(NSLocalizedString("Names in", comment: "Label before the name encoding picker"), selection: $model.encodingChoice) {
                ForEach(NameEncoding.allCases) { e in
                    if e == .automatic {
                        Text(model.hasForeignNames
                             ? String(format: NSLocalizedString("Automatic (%@)", comment: "Encoding picker item; %@ = detected encoding, e.g. CP850"), model.detected.shortLabel)
                             : NSLocalizedString("Automatic", comment: "Encoding picker item")).tag(e)
                    } else {
                        Text(e.label).tag(e)
                    }
                }
            }
            .labelsHidden()
            .fixedSize()
            .help(NSLocalizedString("Encoding of the names. ZIPs made on Windows usually store them in CP850/CP437 or Windows-1252.", comment: "Tooltip of the encoding picker"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .controlSize(.regular)
    }
}

private struct NoticeBar: View {
    let text: String
    let close: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "info.circle").foregroundStyle(Color.kompacWarn)
            Text(text).textSelection(.enabled)
            Spacer()
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.kompacWarn.opacity(0.12))
    }
}

// MARK: - Tree list

private struct ItemTable: View {
    @Bindable var model: WindowModel

    var body: some View {
        Table(model.tree?.roots ?? [], children: \.children, selection: $model.selection) {
            TableColumn(NSLocalizedString("Name", comment: "Column header")) { node in
                HStack(spacing: 6) {
                    Image(nsImage: Icons.icon(for: node)).resizable().frame(width: 16, height: 16)
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    if node.encrypted {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                            .help(NSLocalizedString("Encrypted", comment: "Tooltip of the lock icon next to an encrypted item"))
                    }
                }
            }
            .width(min: 180, ideal: 360)
            TableColumn(NSLocalizedString("Size", comment: "Column header")) { node in
                Text(Format.bytes(node.size)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn(NSLocalizedString("Compressed", comment: "Column header: packed size")) { node in
                Text(Format.bytes(node.packedSize)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn(NSLocalizedString("Modified", comment: "Column header: modification date")) { node in
                Text(Format.date(node.modified)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 130)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if !ids.isEmpty {
                Button(ids.count == 1
                       ? NSLocalizedString("Extract Item", comment: "Context menu, one item selected")
                       : String(format: NSLocalizedString("Extract %ld Items", comment: "Context menu; %ld = number of selected items"), ids.count)) {
                    model.selection = ids
                    model.extract(selectedOnly: true)
                }
                .disabled(!model.canExtract)
            }
        }
    }
}

@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for node: ArchiveNode) -> NSImage {
        let ext = node.isFolder ? "/" : (node.name as NSString).pathExtension.lowercased()
        if let i = cache[ext] { return i }
        let type: UTType = node.isFolder ? .folder : (UTType(filenameExtension: ext) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[ext] = image
        return image
    }
}

// MARK: - Preview

private struct PreviewPane: View {
    let state: PreviewState

    var body: some View {
        Group {
            switch state {
            case .none:
                placeholder(NSLocalizedString("Click a file to see its beginning without extracting.", comment: "Preview pane placeholder"))
            case .loading(let node):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(String(format: NSLocalizedString("Reading %@…", comment: "Preview pane while loading; %@ = file name"), node.name)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .info(let node, let text):
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.name).font(.headline)
                    Text(text).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .text(let node, let text, let truncated):
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(node.name).font(.headline)
                        Spacer()
                        Text(truncated
                             ? String(format: NSLocalizedString("first 16 KB of %@", comment: "Preview header when truncated; %@ = file size, e.g. 48.3 MB"), Format.bytes(node.size))
                             : Format.bytes(node.size))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                    ScrollView([.vertical, .horizontal]) {
                        Text(text.isEmpty ? NSLocalizedString("(empty)", comment: "Preview of an empty text file") : text)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(12)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    private func placeholder(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @Bindable var model: WindowModel

    var body: some View {
        HStack(spacing: 10) {
            if let ex = model.extraction {
                Text(ex.label)
                ProgressView(value: ex.progress).frame(maxWidth: 260)
                Text(verbatim: "\(Int(ex.progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                Button(NSLocalizedString("Cancel", comment: "Button"), role: .cancel) { model.cancelExtraction() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
            } else if let done = model.lastResult {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.kompac)
                Text(String(format: NSLocalizedString("Extracted to %@", comment: "Footer after extracting; %@ = destination path"),
                            done.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~")))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Button(NSLocalizedString("Show in Finder", comment: "Button")) { model.revealLastResult() }
                Spacer()
            } else {
                Text(model.footerText).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            if model.phase == .ready && model.hasForeignNames {
                pill
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 30)
        .background(.bar)
    }

    /// Names came in a legacy code page: tells whether they are fixed or not.
    private var pill: some View {
        let fixed = model.effectiveEncoding != .utf8
        let text = fixed
            ? String(format: NSLocalizedString("accents fixed · %@", comment: "Footer pill; %@ = encoding in use, e.g. CP850"), model.effectiveEncoding.shortLabel)
            : NSLocalizedString("names with odd characters", comment: "Footer pill when names look garbled")
        let color = fixed ? Color.kompac : Color.kompacWarn
        return Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

// MARK: - Password

private struct PasswordSheet: View {
    let fileName: String
    let prompt: PasswordPrompt
    let submit: (String) -> Void
    let cancel: () -> Void
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").font(.title2).foregroundStyle(Color.kompac)
                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("Password Required", comment: "Password sheet title")).font(.headline)
                    Text(reason).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            SecureField(NSLocalizedString("Password", comment: "Password field placeholder"), text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !password.isEmpty { submit(password) } }
            if let error = prompt.error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button(NSLocalizedString("Cancel", comment: "Button"), role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("OK", comment: "Button")) { submit(password) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var reason: String {
        switch prompt.purpose {
        case .open: return String(format: NSLocalizedString("“%@” has encrypted names.", comment: "Password sheet reason; %@ = archive name"), fileName)
        case .extract: return String(format: NSLocalizedString("The items to extract from “%@” are encrypted.", comment: "Password sheet reason; %@ = archive name"), fileName)
        case .preview: return String(format: NSLocalizedString("This item of “%@” is encrypted.", comment: "Password sheet reason; %@ = archive name"), fileName)
        }
    }
}
