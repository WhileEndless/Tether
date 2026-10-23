import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import TetherCore
import FileTransferKit
import SSHTransport
import TerminalUI

@MainActor
@Observable
final class FileBrowserModel {
    let target: ConnectionTarget
    let fs: RemoteFileSystem
    private(set) var directory = ""
    private(set) var files: [RemoteFile] = [] { didSet { recomputeVisible() } }
    /// Sorted and filtered list, recomputed only when the files or the filter change.
    private(set) var visibleFiles: [RemoteFile] = []
    /// No content to show yet (first visit of a directory).
    private(set) var loading = false
    /// Showing cached content while fetching a fresh listing.
    private(set) var refreshing = false
    var error: String?
    var showHidden = false { didSet { recomputeVisible() } }
    private(set) var history: [String] = []
    /// Kept here (not in the view) so it survives tab switches and refreshes.
    var selection = Set<RemoteFile.ID>()

    /// Directory listings per host and path, shared by every browser (tabs and the host panel).
    private static var cache: [String: (directory: String, files: [RemoteFile])] = [:]
    private var loadToken = 0

    init(target: ConnectionTarget, fs: RemoteFileSystem) {
        self.target = target
        self.fs = fs
    }

    private func recomputeVisible() {
        let list = showHidden ? files : files.filter { !$0.isHidden }
        visibleFiles = list.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func cacheKey(_ path: String?) -> String { target.key + "|" + (path ?? "~") }

    /// Shows a directory: instantly from the cache when it was visited before, then refreshed in the
    /// background. A refresh keeps the selection and scroll position (rows keep their identity).
    func load(_ path: String?, pushHistory: Bool = true) async {
        loadToken += 1
        let token = loadToken
        let previous = directory
        if let cached = Self.cache[cacheKey(path)] {
            show(cached.directory, cached.files, from: previous, pushHistory: pushHistory)
            refreshing = true
        } else {
            loading = true
        }
        defer {
            if token == loadToken { loading = false; refreshing = false }
        }
        do {
            let r = try await fs.list(path)
            Self.cache[cacheKey(path)] = (r.directory, r.files)
            Self.cache[cacheKey(r.directory)] = (r.directory, r.files)
            // The user may have navigated elsewhere meanwhile.
            guard token == loadToken else { return }
            show(r.directory, r.files, from: previous, pushHistory: pushHistory && directory != r.directory)
            error = nil
            AppModel.shared.updateMetadata(for: target.key) { $0.lastRemoteDirectory = r.directory }
        } catch {
            if token == loadToken { self.error = error.localizedDescription }
        }
    }

    private func show(_ dir: String, _ list: [RemoteFile], from previous: String, pushHistory: Bool) {
        if pushHistory, !previous.isEmpty, previous != dir, history.last != previous { history.append(previous) }
        if dir != directory {
            directory = dir
            selection = []
        }
        // Only replace the list when it changed, so the table keeps its scroll position.
        if list != files {
            files = list
            let ids = Set(list.map(\.id))
            selection = selection.filter { ids.contains($0) }
        }
    }

    /// Re-reads the current directory (after uploads, deletes, …).
    func reload() async { await load(directory, pushHistory: false) }

    /// Forgets cached listings of a host (after changes made elsewhere).
    static func invalidate(_ target: ConnectionTarget) {
        cache = cache.filter { !$0.key.hasPrefix(target.key + "|") }
    }

    func back() async {
        guard let prev = history.popLast() else { return }
        await load(prev, pushHistory: false)
    }

    var parent: String {
        // Windows: C:/Users → C:/, and a drive root goes up to the list of drives (/).
        if directory.range(of: #"^[A-Za-z]:/?$"#, options: .regularExpression) != nil { return "/" }
        let p = (directory as NSString).deletingLastPathComponent
        if p.range(of: #"^[A-Za-z]:$"#, options: .regularExpression) != nil { return p + "/" }
        return p.isEmpty ? "/" : p
    }
}

struct FileBrowserView: View {
    @Environment(AppModel.self) private var model
    let target: ConnectionTarget
    let standalone: Bool
    var initialPath: String? = nil
    /// Opens a terminal in the given directory ("Open Terminal Here").
    var openTerminal: ((String) -> Void)? = nil
    /// A browser owned elsewhere (file tabs keep theirs so state survives tab switches).
    var external: FileBrowserModel? = nil
    @State private var own: FileBrowserModel?
    private var browser: FileBrowserModel? { external ?? own }
    @AppStorage("files.detailWidth") private var detailWidth = 300.0
    @AppStorage("files.detailHeight") private var detailHeight = 200.0
    @State private var dropTargeted = false
    @State private var pathText = ""
    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var renaming: RemoteFile?
    @State private var renameText = ""
    @State private var deleting: [RemoteFile] = []
    @State private var previewURL: URL?
    @State private var bulk: BulkAction?
    @State private var notice: Notice?

    var body: some View {
        Group {
            if let browser {
                content(browser)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if let external {
                if external.directory.isEmpty { Task { await external.load(initialPath) } }
                return
            }
            guard own == nil else { return }
            let b = FileBrowserModel(target: target, fs: RemoteFileSystem(executor: model.executor(for: target)))
            own = b
            let requested = model.fileBrowserRequests.removeValue(forKey: target.key)
            Task { await b.load(initialPath ?? requested ?? model.metadata(for: target.key).lastRemoteDirectory) }
        }
        .onChange(of: model.fileBrowserRequests[target.key]) { _, path in
            guard let path, let browser else { return }
            model.fileBrowserRequests[target.key] = nil
            Task { await browser.load(path) }
        }
        .navigationTitle(standalone ? "Files — \(target.displayName)" : "")
    }

    @ViewBuilder
    private func content(_ b: FileBrowserModel) -> some View {
        let selected = b.files.filter { b.selection.contains($0.id) }
        VStack(spacing: 0) {
            toolbar(b)
            Divider()
            TransferStatusBar(target: target)
            if standalone {
                ResizablePane(axis: .horizontal, size: $detailWidth, range: 220...520) {
                    table(b)
                } secondary: {
                    FileDetailView(target: target, files: selected, browser: b, previewURL: $previewURL)
                }
            } else if selected.isEmpty {
                table(b)
            } else {
                ResizablePane(axis: .vertical, size: $detailHeight, range: 120...420) {
                    table(b)
                } secondary: {
                    FileDetailView(target: target, files: selected, browser: b, previewURL: $previewURL)
                }
            }
        }
        .quickLookPreview($previewURL)
        .overlay(alignment: .bottom) {
            if let notice {
                GlassPill {
                    Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(notice.isError ? Color.orange : .primary)
                        .lineLimit(2)
                }
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $bulk) { action in
            BulkActionSheet(action: action) { perform($0, b) }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") {
                let path = b.directory + "/" + newFolderName
                newFolderName = ""
                Task { try? await b.fs.makeDirectory(path); await b.load(b.directory, pushHistory: false) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let f = renaming {
                    let dest = (f.path as NSString).deletingLastPathComponent + "/" + renameText
                    Task { try? await b.fs.rename(f.path, to: dest); await b.load(b.directory, pushHistory: false) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete \(deleting.count == 1 ? "\"\(deleting[0].name)\"" : "\(deleting.count) items")?",
                            isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button("Delete", role: .destructive) {
                let items = deleting
                Task {
                    for f in items {
                        do { try await b.fs.delete(f.path) } catch { b.error = error.localizedDescription }
                    }
                    await b.load(b.directory, pushHistory: false)
                }
            }
        } message: {
            Text("This permanently deletes the item on the server. It cannot be undone.")
        }
    }

    private func toolbar(_ b: FileBrowserModel) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button { Task { await b.back() } } label: { Image(systemName: "chevron.left") }
                    .disabled(b.history.isEmpty)
                Button { Task { await b.load(b.parent) } } label: { Image(systemName: "arrow.up") }
                    .disabled(b.directory == "/")
                Button { Task { await b.load(nil) } } label: { Image(systemName: "house") }
                TextField("Path", text: $pathText)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .onSubmit { Task { await b.load(pathText) } }
                Button { Task { await b.reload() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                if let openTerminal {
                    Button { openTerminal(b.directory) } label: { Image(systemName: "apple.terminal") }
                        .help("Open Terminal Here")
                }
                Menu {
                    Button("Upload Files…") { pickUpload(b) }
                    Button("New Folder…") { showNewFolder = true }
                    Divider()
                    Toggle("Show Hidden Files", isOn: Binding(get: { b.showHidden }, set: { v in b.showHidden = v }))
                    if !standalone {
                        Divider()
                        OpenFilesWindowButton(target: target, path: b.directory)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .buttonStyle(.borderless)
            if b.refreshing {
                Text("Showing cached listing — refreshing…")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = b.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .onChange(of: b.directory) { _, d in pathText = d }
    }

    private func table(_ b: FileBrowserModel) -> some View {
        Table(of: RemoteFile.self, selection: Binding(get: { b.selection }, set: { b.selection = $0 })) {
            TableColumn("Name") { (f: RemoteFile) in
                HStack(spacing: 6) {
                    Image(nsImage: icon(for: f)).resizable().frame(width: 16, height: 16)
                    Text(f.name).lineLimit(1).foregroundStyle(f.isHidden ? .secondary : .primary)
                    if f.kind == .symlink { Image(systemName: "arrow.turn.up.right").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            .width(min: 140, ideal: 220)
            TableColumn("Size") { (f: RemoteFile) in
                Text(f.isDirectory ? "—" : f.size.byteString).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70)
            TableColumn("Modified") { (f: RemoteFile) in
                Text(f.modified, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130)
            TableColumn("Permissions") { (f: RemoteFile) in
                Text(f.permissionString).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
        } rows: {
            ForEach(b.visibleFiles) { f in
                TableRow(f).itemProvider { dragProvider(for: f) }
            }
        }
        .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
            let items = b.files.filter { ids.contains($0.id) }
            if let openTerminal, items.count == 1, let f = items.first, f.isDirectory {
                Button("Open Terminal Here") { openTerminal(f.path) }
                Divider()
            }
            if items.count == 1, let f = items.first, !f.isDirectory {
                Button("Quick Look") { quickLook(f) }
            }
            Button(items.count > 1 ? "Copy \(items.count) Items" : "Copy") { copyToMac(items) }
            Button("Paste from Mac") { pasteFromMac(b) }
                .help("Uploads files or an image copied on this Mac")
                .disabled(!clipboardHasFiles)
            Button("Copy Path\(items.count > 1 ? "s" : "")") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("Download to Downloads") { download(items) }
            Button("Move To…") { bulk = BulkAction(kind: .move, items: items, value: b.directory) }
            Button("Copy To…") { bulk = BulkAction(kind: .copy, items: items, value: b.directory) }
            Button("Permissions…") {
                bulk = BulkAction(kind: .permissions, items: items,
                                  value: items.count == 1 ? String(items[0].permissions, radix: 8) : "644")
            }
            .disabled(PlatformCache.shared.cached(target.key)?.isWindows == true)
            Button("Compress to .tar.gz") { compress(items, b) }
            if items.count == 1, let f = items.first {
                Button("Rename…") { renameText = f.name; renaming = f }
            }
            Divider()
            Button(items.count > 1 ? "Delete \(items.count) Items…" : "Delete…", role: .destructive) { deleting = items }
        } primaryAction: { ids in
            guard let f = b.files.first(where: { ids.contains($0.id) }) else { return }
            if f.isDirectory || f.kind == .symlink { Task { await b.load(f.path) } } else { quickLook(f) }
        }
        .overlay {
            if b.loading && b.files.isEmpty {
                ProgressView()
            } else if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Color.accentColor.opacity(0.08))
                    .overlay {
                        Label("Upload to \((b.directory as NSString).lastPathComponent)", systemImage: "arrow.up.doc")
                            .font(.headline).padding().glassEffect()
                    }
                    .padding(6)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            uploadSafely(urls.filter(\.isFileURL), into: b)
            return true
        } isTargeted: { v in dropTargeted = v }
        // ⌘C / ⌘V with the Mac's clipboard (Finder).
        .onCommand(#selector(NSText.copy(_:))) {
            let items = b.files.filter { b.selection.contains($0.id) }
            if !items.isEmpty { copyToMac(items) }
        }
        .onCommand(#selector(NSText.paste(_:))) { pasteFromMac(b) }
        .onKeyPress(.delete) {
            let items = b.files.filter { b.selection.contains($0.id) }
            if !items.isEmpty { deleting = items }
            return .handled
        }
        // Finder keys: ⌘↓ opens, ⌘↑ goes to the parent, ⌘[ goes back.
        .onKeyPress(keys: [.downArrow, .upArrow, "["]) { press in
            switch (press.key, press.modifiers) {
            case (.downArrow, .command):
                guard let f = b.files.first(where: { b.selection.contains($0.id) }) else { return .ignored }
                if f.isDirectory || f.kind == .symlink { Task { await b.load(f.path) } } else { quickLook(f) }
            case (.upArrow, .command): Task { await b.load(b.parent) }
            case ("[", .command): Task { await b.back() }
            default: return .ignored
            }
            return .handled
        }
        .onKeyPress(.space) {
            if let f = b.files.first(where: { b.selection.contains($0.id) }), !f.isDirectory { quickLook(f) }
            return .handled
        }
    }

    private func icon(for f: RemoteFile) -> NSImage {
        if f.isDirectory { return NSWorkspace.shared.icon(for: .folder) }
        let type = UTType(filenameExtension: f.fileExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    /// Lets the user drag a remote file to Finder: the file is downloaded when dropped.
    private func dragProvider(for f: RemoteFile) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = f.name
        let type = f.isDirectory ? UTType.folder : (UTType(filenameExtension: f.fileExtension) ?? .data)
        let transfers = model.transfers
        let target = self.target
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            let dir = AppPaths.previewDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(f.name)
            Task { @MainActor in
                transfers.download(f.path, to: dest, target: target) { item in
                    if item.state == .completed { completion(dest, false, nil) }
                    else { completion(nil, false, RemoteErrorBox(message: "Download failed")) }
                }
            }
            return nil
        }
        return provider
    }

    private func download(_ items: [RemoteFile]) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        show("Downloading \(items.count) item(s) to Downloads…")
        downloadItems(items, to: downloads) { urls, failed in
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            if failed > 0 { show("\(failed) item(s) could not be downloaded — see Transfers", isError: true) }
        }
    }

    /// Downloads items into a local folder without replacing anything there (Finder-style
    /// "name 2" names). Many files travel as one packed stream (see Settings ▸ Transfers).
    private func downloadItems(_ items: [RemoteFile], to local: URL, completion: @escaping ([URL], Int) -> Void) {
        guard !items.isEmpty else { return }
        let names = LocalFiles.uniqueNames(in: local, for: items.map(\.name))
        let parents = Set(items.map { ($0.path as NSString).deletingLastPathComponent })
        let fs = RemoteFileSystem(executor: model.executor(for: target))
        let transfers = model.transfers
        let target = self.target
        Task {
            // Only folders need counting; plain files are counted as they are.
            var size = TransferSize(files: items.count, bytes: items.reduce(0) { $0 + $1.size })
            if items.contains(where: \.isDirectory), transfers.policy.archiveMode != .never {
                size = (try? await fs.measure(items.map(\.path))) ?? size
            }
            let finish: ([TransferItem]) -> Void = { made in
                let ok = made.filter { $0.state == .completed }
                let urls = ok.flatMap { $0.entries.map { URL(fileURLWithPath: $0.to) } }
                completion(urls, made.count - ok.count)
            }
            if parents.count == 1, let parent = parents.first {
                transfers.downloadGroup(items.map(\.name), from: parent, to: local, as: names, target: target,
                                        fileCount: size.files, totalBytes: size.bytes, completion: finish)
            } else {
                var made: [TransferItem] = []
                var remaining = items.count
                for (f, name) in zip(items, names) {
                    made.append(transfers.download(f.path, to: local.appendingPathComponent(name), target: target) { _ in
                        remaining -= 1
                        if remaining == 0 { finish(made) }
                    })
                }
            }
        }
    }

    private func quickLook(_ f: RemoteFile) {
        let dir = AppPaths.previewDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(f.name)
        model.transfers.download(f.path, to: dest, target: target) { item in
            if item.state == .completed { previewURL = dest }
        }
    }

    private func pickUpload(_ b: FileBrowserModel) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        uploadSafely(panel.urls, into: b)
    }

    // MARK: Uploads, clipboard and bulk actions

    private var clipboardHasFiles: Bool {
        let pb = NSPasteboard.general
        return !PasteboardFiles.fileURLs(on: pb).isEmpty || PasteboardFiles.hasImageOnly(pb)
    }

    /// Uploads into the current folder without overwriting: clashing names get a suffix.
    /// Many files travel as one packed stream (see Settings ▸ Transfers).
    private func uploadSafely(_ urls: [URL], into b: FileBrowserModel) {
        guard !urls.isEmpty else { return }
        let dir = b.directory
        Task {
            do {
                let names = try await b.fs.uniqueNames(in: dir, for: urls.map(\.lastPathComponent))
                let size = await Task.detached { LocalFiles.measure(urls) }.value
                let made = model.transfers.uploadGroup(urls, names: names, to: dir, target: target,
                                                       fileCount: size.files, totalBytes: size.bytes) { items in
                    Task { await b.reload() }
                    let failed = items.filter { $0.state != .completed }.count
                    if failed > 0 { show("\(failed) upload(s) did not finish — see Transfers", isError: true) }
                }
                let renamed = zip(urls, names).filter { $0.0.lastPathComponent != $0.1 }.count
                let how = made.first?.method == .archive ? " as one stream" : ""
                show(renamed > 0 ? "Uploading \(size.files.formatted()) file(s)\(how) — \(renamed) renamed to avoid overwriting"
                                 : "Uploading \(size.files.formatted()) file(s)\(how) to \((dir as NSString).lastPathComponent)")
            } catch {
                show(error.localizedDescription, isError: true)
            }
        }
    }

    /// Pastes files copied in Finder into the current folder.
    private func pasteFromMac(_ b: FileBrowserModel) {
        guard let urls = PasteboardFiles.filesToPaste(from: NSPasteboard.general) else {
            show("The clipboard holds no files or images. Copy files in Finder, or take a screenshot with ⌃⇧⌘4.", isError: true)
            return
        }
        uploadSafely(urls, into: b)
    }

    /// Downloads the items to a local clipboard folder, then puts them on the Mac's clipboard so
    /// they can be pasted in Finder.
    private func copyToMac(_ items: [RemoteFile]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TetherClipboard/\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        show("Preparing \(items.count) item(s) for the clipboard…")
        downloadItems(items, to: dir) { urls, failed in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
            show(failed == 0 ? "\(urls.count) item(s) copied — paste them in Finder (⌘V)"
                             : "\(urls.count) copied, \(failed) failed", isError: failed > 0)
        }
    }

    private func compress(_ items: [RemoteFile], _ b: FileBrowserModel) {
        let name = (items.count == 1 ? items[0].name : (b.directory as NSString).lastPathComponent) + ".tar.gz"
        show("Compressing \(items.count) item(s)…")
        Task {
            do {
                let path = try await b.fs.compress(items.map(\.name), in: b.directory, archiveName: name)
                show("Created \((path as NSString).lastPathComponent)")
                await b.reload()
            } catch { show(error.localizedDescription, isError: true) }
        }
    }

    private func perform(_ action: BulkAction, _ b: FileBrowserModel) {
        let paths = action.items.map(\.path)
        Task {
            do {
                switch action.kind {
                case .move:
                    let skipped = try await b.fs.move(paths, to: action.value)
                    show(skipped.isEmpty ? "Moved \(paths.count) item(s)" : "Moved; skipped existing: \(skipped.joined(separator: ", "))",
                         isError: !skipped.isEmpty)
                case .copy:
                    let skipped = try await b.fs.copy(paths, to: action.value)
                    show(skipped.isEmpty ? "Copied \(paths.count) item(s)" : "Copied; skipped existing: \(skipped.joined(separator: ", "))",
                         isError: !skipped.isEmpty)
                case .permissions:
                    try await b.fs.setPermissions(paths, mode: action.value, recursive: action.recursive)
                    show("Permissions set to \(action.value)")
                }
                await b.reload()
            } catch {
                show(error.localizedDescription, isError: true)
            }
        }
    }

    private func show(_ text: String, isError: Bool = false) {
        withAnimation(.snappy) { notice = Notice(text: text, isError: isError) }
        let current = notice?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if notice?.id == current { withAnimation(.snappy) { notice = nil } }
        }
    }
}

struct RemoteErrorBox: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

struct OpenFilesWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    let target: ConnectionTarget
    var path: String?
    var body: some View {
        Button("Open in Window") { openWindow(id: "files", value: FilesRequest(target: target, path: path)) }
    }
}

/// Value for a file browser window: which host, and where to start.
struct FilesRequest: Codable, Hashable {
    var target: ConnectionTarget
    var path: String?
}

/// Live transfers for this host with speed and progress, shown at the top of the file browser.
struct TransferStatusBar: View {
    @Environment(AppModel.self) private var model
    let target: ConnectionTarget

    var body: some View {
        let active = model.transfers.items.filter { $0.target == target && ($0.state == .running || $0.state == .queued) }
        if !active.isEmpty {
            VStack(spacing: 6) {
                ForEach(active) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(item.currentFile.isEmpty ? item.name : item.currentFile).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(item.state == .queued ? "Queued" : "\(item.transferred)  \(item.speed)  \(item.eta)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            ProgressView(value: item.progress).animation(.smooth, value: item.progress)
                        }
                        Button { model.transfers.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                    }
                    .font(.caption)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.4))
        }
    }
}

/// Details for the selected file(s).
struct FileDetailView: View {
    @Environment(AppModel.self) private var model
    let target: ConnectionTarget
    let files: [RemoteFile]
    let browser: FileBrowserModel
    @Binding var previewURL: URL?
    @State private var details: (description: String?, totalSize: Int64?) = (nil, nil)

    var body: some View {
        ScrollView {
            if let f = files.first, files.count == 1 {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(nsImage: f.isDirectory ? NSWorkspace.shared.icon(for: .folder)
                              : NSWorkspace.shared.icon(for: UTType(filenameExtension: f.fileExtension) ?? .data))
                            .resizable().frame(width: 44, height: 44)
                        VStack(alignment: .leading) {
                            Text(f.name).font(.headline).lineLimit(2).textSelection(.enabled)
                            Text(details.description ?? kindText(f)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                        row("Size", f.isDirectory ? (details.totalSize?.byteString ?? "Calculating…") : f.size.byteString)
                        row("Modified", f.modified.formatted(date: .abbreviated, time: .standard))
                        row("Permissions", "\(f.permissionString)  (\(String(f.permissions, radix: 8)))")
                        row("Owner", "\(f.owner):\(f.group)")
                        if let link = f.linkTarget { row("Link to", link) }
                        row("Path", f.path)
                    }
                    .font(.callout)
                    HStack {
                        Button("Download") { download(f) }.buttonStyle(.glassProminent)
                        if !f.isDirectory { Button("Quick Look") { quickLook(f) }.buttonStyle(.glass) }
                    }
                }
                .padding(12)
                .task(id: f.id) {
                    details = (nil, nil)
                    details = await browser.fs.details(f)
                }
            } else if files.count > 1 {
                VStack(spacing: 10) {
                    Image(systemName: "doc.on.doc").font(.largeTitle).foregroundStyle(.secondary)
                    Text("\(files.count) items · \(files.reduce(0) { $0 + $1.size }.byteString)")
                    Button("Download All") { files.forEach(download) }.buttonStyle(.glassProminent)
                }
                .frame(maxWidth: .infinity).padding(20)
            } else {
                EmptyStateView(symbol: "doc", title: "No Selection",
                               message: "Drop files here to upload. Drag files to Finder to download.")
            }
        }
    }

    private func kindText(_ f: RemoteFile) -> String {
        switch f.kind {
        case .directory: "Folder"
        case .symlink: "Symbolic link"
        case .file: (UTType(filenameExtension: f.fileExtension)?.localizedDescription) ?? "File"
        case .other: "Special file"
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled).lineLimit(3)
        }
    }

    private func download(_ f: RemoteFile) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        model.transfers.download(f.path, to: dir.appendingPathComponent(f.name), target: target) { item in
            if item.state == .completed { NSWorkspace.shared.activateFileViewerSelecting([item.localURL]) }
        }
    }

    private func quickLook(_ f: RemoteFile) {
        let dir = AppPaths.previewDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(f.name)
        model.transfers.download(f.path, to: dest, target: target) { item in
            if item.state == .completed { previewURL = dest }
        }
    }
}

/// A short message over the file list.
private struct Notice: Equatable {
    let id = UUID()
    var text: String
    var isError: Bool
}

/// Move / copy / chmod for one or more files.
struct BulkAction: Identifiable {
    enum Kind { case move, copy, permissions }
    let id = UUID()
    var kind: Kind
    var items: [RemoteFile]
    var value: String
    var recursive = false
}

private struct BulkActionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var action: BulkAction
    let perform: (BulkAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Text(action.items.prefix(4).map(\.name).joined(separator: ", ") + (action.items.count > 4 ? " and \(action.items.count - 4) more" : ""))
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            TextField(action.kind == .permissions ? "755 or u+x" : "Destination folder", text: $action.value)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit(run)
            if action.kind == .permissions {
                Toggle("Apply to folder contents too (-R)", isOn: $action.recursive)
            } else {
                Text("Items whose name already exists in the destination are skipped, never overwritten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(button) { run() }.keyboardShortcut(.defaultAction).buttonStyle(.glassProminent)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    private var title: String {
        let n = action.items.count
        switch action.kind {
        case .move: return "Move \(n) item\(n == 1 ? "" : "s") to…"
        case .copy: return "Copy \(n) item\(n == 1 ? "" : "s") to…"
        case .permissions: return "Permissions for \(n) item\(n == 1 ? "" : "s")"
        }
    }

    private var button: String {
        switch action.kind {
        case .move: "Move"
        case .copy: "Copy"
        case .permissions: "Apply"
        }
    }

    private func run() {
        guard !action.value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        perform(action)
        dismiss()
    }
}
