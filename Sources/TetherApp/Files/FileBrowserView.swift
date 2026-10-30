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
    /// The search field: while typing it filters the folder shown (names containing it, or
    /// matching it as a pattern); ↩ searches the folders below too (`search`).
    var filterText = "" { didSet { if filterText != oldValue { recomputeVisible() } } }
    var searchMode: FileSearchQuery.Mode = .name { didSet { recomputeVisible() } }
    /// A search of the folder and the folders below it, shown instead of the folder's listing.
    private(set) var search: SearchState? { didSet { recomputeVisible() } }
    private var searchTask: Task<Void, Never>?

    struct SearchState: Equatable {
        var query: FileSearchQuery
        /// The folder searched (the one shown).
        var folder: String
        var running = true
        var results: [RemoteFile] = []
        var truncated = false
        var stopped = false
        var error: String?
    }
    private(set) var history: [String] = []
    /// Folders left with Back, for Forward.
    private(set) var forwardHistory: [String] = []
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
        if let search {
            // Grouped by folder, as found below the one searched.
            visibleFiles = search.results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            return
        }
        var list = showHidden ? files : files.filter { !$0.isHidden }
        let text = filterText.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            switch searchMode {
            case .name: list = list.filter { $0.name.localizedCaseInsensitiveContains(text) }
            case .pattern: list = list.filter { fnmatch(text, $0.name, FNM_CASEFOLD) == 0 }
            case .content: break   // only the server can tell (↩)
            }
        }
        visibleFiles = list.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The rows shown with these ids (the folder's, or the search's).
    func items(_ ids: Set<RemoteFile.ID>) -> [RemoteFile] { visibleFiles.filter { ids.contains($0.id) } }

    /// Searches the folder shown and the folders below it for the search field's text.
    func runSearch() {
        let text = filterText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { endSearch(); return }
        // No folder yet (its first listing is on the way): ↩ again once it is shown.
        guard !directory.isEmpty else { NSSound.beep(); return }
        searchTask?.cancel()
        let query = FileSearchQuery(text: text, mode: searchMode, includeHidden: showHidden)
        let folder = directory
        selection = []
        search = SearchState(query: query, folder: folder)
        let fs = self.fs
        searchTask = Task { [weak self] in
            do {
                let found = try await fs.search(query, in: folder)
                guard let self, self.search?.query == query, self.search?.folder == folder, self.search?.running == true else { return }
                self.search?.results = found.files
                self.search?.truncated = found.truncated
                self.search?.running = false
            } catch is CancellationError {
            } catch {
                guard let self, self.search?.query == query, self.search?.running == true else { return }
                self.search?.error = error.localizedDescription
                self.search?.running = false
            }
        }
    }

    /// Stops a search under way (on the server too).
    func stopSearch() {
        searchTask?.cancel()
        searchTask = nil
        guard search?.running == true else { return }
        search?.running = false
        search?.stopped = true
    }

    /// Back to the folder's listing (the field emptied).
    func endSearch() {
        searchTask?.cancel()
        searchTask = nil
        if search != nil { selection = [] }
        search = nil
        filterText = ""
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
            // Bounded: a listing of a big folder can be megabytes, and every folder visited on every
            // host would otherwise stay for as long as Tether runs.
            if Self.cache.count > 64 { Self.cache.removeAll() }
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
        if pushHistory, !previous.isEmpty, previous != dir, history.last != previous {
            history.append(previous)
            forwardHistory.removeAll()   // a new path forgets where Forward would have gone
        }
        if dir != directory {
            let first = directory.isEmpty
            directory = dir
            selection = []
            // A search belongs to the folder it was made in (what was typed before the first
            // listing arrived stays: it filters that listing).
            if !first { endSearch() }
        }
        // Only replace the list when it changed, so the table keeps its scroll position.
        if list != files {
            files = list
            if search == nil {
                let ids = Set(list.map(\.id))
                selection = selection.filter { ids.contains($0) }
            }
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
        if !directory.isEmpty { forwardHistory.append(directory) }
        await load(prev, pushHistory: false)
    }

    func forward() async {
        guard let next = forwardHistory.popLast() else { return }
        if !directory.isEmpty { history.append(directory) }
        await load(next, pushHistory: false)
    }

    /// The folders leading to the current one, for the clickable path ("/", "home", "user", …).
    var pathComponents: [(name: String, path: String)] {
        guard !directory.isEmpty else { return [] }
        var result: [(String, String)] = []
        var path = directory
        while true {
            let name = path == "/" ? "/" : (path as NSString).lastPathComponent
            result.insert((name.isEmpty ? path : name, path), at: 0)
            let up = (path as NSString).deletingLastPathComponent
            if path == "/" || up == path || up.isEmpty { break }
            if path.range(of: #"^[A-Za-z]:/?$"#, options: .regularExpression) != nil { break }
            path = up.range(of: #"^[A-Za-z]:$"#, options: .regularExpression) != nil ? up + "/" : up
        }
        return result.map { (name: $0.0, path: $0.1) }
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
    @State private var width: CGFloat = 1000
    @FocusState private var searchFocused: Bool

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
            Task { await b.load(initialPath ?? requested) }   // nil: the home folder
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
        let selected = b.items(b.selection)
        VStack(spacing: 0) {
            toolbar(b)
            Divider()
            TransferStatusBar(target: target)
            // The details column only stays beside the list while the list keeps room for all its
            // columns; on a small screen the details move below the list and show up only for a selection.
            // One pane either way: the list must stay the same view when the details come and go,
            // or a click that selects the first row rebuilds it and the keyboard focus is lost
            // (⌘C, ⌘V and the arrow keys then reach nothing).
            let beside = standalone && width >= detailWidth + 620
            ResizablePane(axis: beside ? .horizontal : .vertical, size: beside ? $detailWidth : $detailHeight,
                          range: beside ? 220...520 : 120...420, showsSecondary: beside || !selected.isEmpty) {
                table(b)
            } secondary: {
                FileDetailView(target: target, files: selected, browser: b, previewURL: $previewURL)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width = $0 }
        .quickLookPreview($previewURL)
        .overlay(alignment: .bottom) {
            if let notice {
                GlassPill {
                    if notice.busy {
                        Label { Text(notice.text).lineLimit(2) } icon: { ProgressView().controlSize(.small) }
                    } else {
                        Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(notice.isError ? Color.orange : .primary)
                            .lineLimit(2)
                    }
                }
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $bulk) { action in
            BulkActionSheet(action: action) { perform($0, b) }.appLockCover()
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
            HStack(spacing: 4) {
                NavButton(symbol: "chevron.left", help: "Back (⌘[ or the mouse's back button)", enabled: !b.history.isEmpty) {
                    Task { await b.back() }
                }
                NavButton(symbol: "chevron.right", help: "Forward (⌘])", enabled: !b.forwardHistory.isEmpty) {
                    Task { await b.forward() }
                }
                NavButton(symbol: "arrow.up", help: "Enclosing folder (⌘↑)", enabled: b.directory != "/") {
                    Task { await b.load(b.parent) }
                }
                NavButton(symbol: "house", help: "Home folder", enabled: true) { Task { await b.load(nil) } }
                TextField("Path", text: $pathText)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .controlSize(.large)
                    .onSubmit { Task { await b.load(pathText) } }
                NavButton(symbol: "arrow.clockwise", help: "Refresh", enabled: true) { Task { await b.reload() } }
                if let openTerminal {
                    NavButton(symbol: "apple.terminal", help: "Open Terminal Here", enabled: true) { openTerminal(b.directory) }
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
                    Image(systemName: "ellipsis.circle").font(.system(size: 15)).frame(width: 30, height: 28)
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .buttonStyle(.borderless)
            // Click any part of the path to go there.
            HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(b.pathComponents.enumerated()), id: \.offset) { i, c in
                        if i > 0 { Image(systemName: "chevron.compact.right").font(.caption).foregroundStyle(.tertiary) }
                        Button { Task { await b.load(c.path) } } label: {
                            Text(c.name)
                                .font(.callout)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(i == b.pathComponents.count - 1 ? Color.accentColor.opacity(0.15) : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            searchField(b)
            }
            searchStatus(b)
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
                    Image(nsImage: icon(for: f)).resizable().frame(width: 22, height: 22)
                    Text(f.name).lineLimit(1).foregroundStyle(f.isHidden ? .secondary : .primary)
                    if f.kind == .symlink { Image(systemName: "arrow.turn.up.right").font(.caption2).foregroundStyle(.secondary) }
                    if let s = b.search, let place = Self.place(of: f, below: s.folder) {
                        Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            .help(f.path)
                    }
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
            // Owner and permissions join once the list is wide enough to show them without scrolling;
            // narrower, they stay in the details shown for the selection.
            if width >= 600 {
                TableColumn("Owner") { (f: RemoteFile) in
                    Text(f.owner == "-" || f.owner.isEmpty ? "—" : (f.group.isEmpty || f.group == "-" || f.group == f.owner ? f.owner : "\(f.owner):\(f.group)"))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 60, ideal: 110)
                TableColumn("Permissions") { (f: RemoteFile) in
                    Text(f.permissionString).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 90)
            }
        } rows: {
            ForEach(b.visibleFiles) { f in
                TableRow(f).itemProvider { dragProvider(for: f) }
            }
        }
        .environment(\.defaultMinListRowHeight, 30)
        .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
            let items = b.items(ids)
            if let openTerminal, items.count == 1, let f = items.first, f.isDirectory {
                Button("Open Terminal Here") { openTerminal(f.path) }
                Divider()
            }
            if items.count == 1, let f = items.first, !f.isDirectory {
                Button("Quick Look") { quickLook(f) }
            }
            if b.search != nil, items.count == 1, let f = items.first {
                Button("Show in Enclosing Folder") {
                    Task {
                        await b.load((f.path as NSString).deletingLastPathComponent)
                        b.selection = [f.id]
                    }
                }
            }
            if !items.isEmpty {
                Button(items.count > 1 ? "Copy \(items.count) Items" : "Copy") { copyItems(items) }
                    .help("Paste them in another folder here or on another server, in a terminal, or in Finder")
            }
            Button("Paste Here") { paste(into: b) }
                .help("Files copied here or on another server, or in Finder (or an image) — nothing is replaced")
                .disabled(!clipboardHasFiles)
            if clipboardFromThisServer {
                Button("Move Here") { paste(into: b, move: true) }
                    .help("Moves the items copied on this server into this folder (free names, nothing replaced)")
            }
            Button("Copy Path\(items.count > 1 ? "s" : "")") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button(model.settings.askWhereToDownload ? "Download…" : "Download to \(model.downloadFolderName)") { download(items) }
            if !model.settings.askWhereToDownload {
                Button("Download To…") { download(items, ask: true) }
            }
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
            guard let f = b.items(ids).first else { return }
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
                            .font(.headline).padding().glassBackground()
                    }
                    .padding(6)
            }
        }
        // Files from Finder are uploaded; rows dragged from a file manager (this one, another tab or
        // window, another server's) are pasted like a copy — nothing is downloaded for a drag that
        // ends in the folder it began in, and on the same server they are copied there.
        .onDrop(of: [.tetherRemoteFiles, .fileURL], isTargeted: $dropTargeted) { providers in
            drop(providers, into: b)
        }
        // ⌘C / ⌘V (and Edit ▸ Copy / Paste) while the file list has focus; text fields (the path,
        // a rename) keep their own copy and paste.
        .onCopyCommand {
            let items = b.items(b.selection)
            guard !items.isEmpty else { return [] }
            copyItems(items)
            // What SwiftUI writes then replaces the pasteboard: the clip again, with its paths as text.
            let clip = RemoteClip(items, from: target)
            let provider = NSItemProvider(object: clip.text as NSString)
            if let data = RemoteClipboard.encode(clip) {
                provider.registerDataRepresentation(forTypeIdentifier: RemoteClipboard.typeIdentifier, visibility: .all) { done in
                    done(data, nil)
                    return nil
                }
            }
            return [provider]
        }
        .onPasteCommand(of: [.fileURL, .png, .tiff, .utf8PlainText]) { _ in   // a remote clip always has its paths as text
            paste(into: b)
        }
        // The keys themselves (Edit ▸ Copy / Paste come through the commands above).
        .background(FileListKeys(copy: {
            let items = b.items(b.selection)
            if items.isEmpty { NSSound.beep() } else { copyItems(items) }
        }, paste: { paste(into: b) }, find: { searchFocused = true }, standalone: standalone))
        .onKeyPress(.delete) {
            let items = b.items(b.selection)
            if !items.isEmpty { deleting = items }
            return .handled
        }
        // Finder keys: ⌘↓ opens, ⌘↑ goes to the parent, ⌘[ / ⌘] go back and forward.
        .onKeyPress(keys: [.downArrow, .upArrow, "[", "]"]) { press in
            switch (press.key, press.modifiers) {
            case (.downArrow, .command):
                guard let f = b.items(b.selection).first else { return .ignored }
                if f.isDirectory || f.kind == .symlink { Task { await b.load(f.path) } } else { quickLook(f) }
            case (.upArrow, .command): Task { await b.load(b.parent) }
            case ("[", .command): Task { await b.back() }
            case ("]", .command): Task { await b.forward() }
            default: return .ignored
            }
            return .handled
        }
        // The mouse's side buttons go back and forward, as in Finder.
        .background(MouseNavigationButtons(back: { Task { await b.back() } }, forward: { Task { await b.forward() } }))
        .onKeyPress(.space) {
            if let f = b.items(b.selection).first, !f.isDirectory { quickLook(f) }
            return .handled
        }
    }

    /// The search field: filters the folder as you type; ↩ searches the folders below it too.
    private func searchField(_ b: FileBrowserModel) -> some View {
        HStack(spacing: 4) {
            Menu {
                Picker("Search For", selection: Binding(get: { b.searchMode }, set: { b.searchMode = $0 })) {
                    ForEach(FileSearchQuery.Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Include Hidden Files", isOn: Binding(get: { b.showHidden }, set: { b.showHidden = $0 }))
            } label: {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("What to search for: names containing the text, names matching a pattern (*.log), or files containing the text")
            TextField(searchPrompt(b.searchMode), text: Binding(get: { b.filterText }, set: { b.filterText = $0 }))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { b.runSearch() }
                .onExitCommand { b.endSearch() }
                .help("Typing filters this folder; ↩ searches the folders below it too (on the server). Esc ends the search.")
            if !b.filterText.isEmpty || b.search != nil {
                Button { b.endSearch() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help("End the search")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .frame(width: standalone ? 260 : 200)
    }

    private func searchPrompt(_ mode: FileSearchQuery.Mode) -> String {
        switch mode {
        case .name: "Search names"
        case .pattern: "Pattern, e.g. *.log"
        case .content: "Text in files"
        }
    }

    /// What the search is doing or found, below the path.
    @ViewBuilder
    private func searchStatus(_ b: FileBrowserModel) -> some View {
        let folder = (b.directory as NSString).lastPathComponent.isEmpty ? b.directory : (b.directory as NSString).lastPathComponent
        if let s = b.search {
            HStack(spacing: 8) {
                if s.running {
                    ProgressView().controlSize(.small)
                    Text("Searching \(folder) and the folders below it for “\(s.query.text)”…")
                        .lineLimit(1).truncationMode(.middle)
                    Button("Stop") { b.stopSearch() }.controlSize(.small)
                } else if let error = s.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).lineLimit(2)
                } else {
                    let n = s.results.count
                    Text(n == 0 ? "Nothing found in \(folder) or below for “\(s.query.text)”"
                         : s.truncated ? "More than \(n.formatted()) found — the first \(n.formatted()) are shown; narrow the search"
                         : "\(n.formatted()) found in \(folder) and below" + (s.stopped ? " before the search was stopped" : ""))
                        .lineLimit(1).truncationMode(.middle)
                    if s.stopped && n == 0 { Text("(stopped)").foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                Button("Done") { b.endSearch() }.controlSize(.small)
                    .help("Back to the folder's contents (Esc in the search field)")
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !b.filterText.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(b.searchMode == .content ? "Press ↩ to search the files in \(folder) and the folders below it"
                 : "Showing matches in \(folder) — press ↩ to search the folders below it too")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Where a search result lies below the folder searched ("in logs/2024"); nil right in it.
    static func place(of f: RemoteFile, below folder: String) -> String? {
        let parent = (f.path as NSString).deletingLastPathComponent
        let base = folder.hasSuffix("/") ? folder : folder + "/"
        guard parent.hasPrefix(base) else { return nil }
        return "in " + parent.dropFirst(base.count)
    }

    private func icon(for f: RemoteFile) -> NSImage {
        if f.isDirectory { return NSWorkspace.shared.icon(for: .folder) }
        let type = UTType(filenameExtension: f.fileExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    /// Lets the user drag remote files to Finder: they are downloaded when dropped. SwiftUI asks
    /// for one provider per dragged row; the rows dragged together share one `DragDownloadSession`,
    /// so the first item the drop asks for downloads them all together — many files as one packed
    /// stream, one row in Transfers — and each item is handed over once that download has ended
    /// (or fails then, when cancelled: nothing reaches the drop target).
    private func dragProvider(for f: RemoteFile) -> NSItemProvider {
        let provider = NSItemProvider()
        // The name as it is: a file is offered as plain data, not as the type its extension maps to
        // (macOS names the copy after that type's own extension: `go.mod` arrived as `go.mod.mod`,
        // a type the extension `mod` happens to belong to). A name starting with a dot is not
        // suggested at all (macOS turns `.env` into `_env`): the file's own name is used then.
        provider.suggestedName = f.name.hasPrefix(".") ? nil : f.name
        let type = f.isDirectory ? UTType.folder : UTType.data
        let session = dragSession(for: f)
        let path = f.path
        // Which server and paths, for a drop inside Tether (registered first: preferred there). It
        // costs nothing; only a drop that asks for the file itself downloads.
        if let data = DragSessions.clips[ObjectIdentifier(session)] {
            provider.registerDataRepresentation(forTypeIdentifier: RemoteClipboard.typeIdentifier, visibility: .all) { done in
                done(data, nil)
                return nil
            }
        }
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in
                session.request(path) { url, error in completion(url, false, error) }
            }
            return nil
        }
        return provider
    }

    /// The session of the drag `f` is part of: the selected rows when `f` is one of them (made once
    /// for the whole drag), otherwise `f` alone.
    private func dragSession(for f: RemoteFile) -> DragDownloadSession {
        let b = browser
        let dragged = b.flatMap { b in b.selection.contains(f.id) ? b.items(b.selection) : nil } ?? [f]
        // A row dragged without being selected gets selected, as in Finder (with ⌘: added). A click
        // that moves a pixel starts a drag; without this it selected nothing.
        if let b, !b.selection.contains(f.id) {
            let adding = NSEvent.modifierFlags.contains(.command)
            DispatchQueue.main.async {
                guard b.visibleFiles.contains(where: { $0.id == f.id }) else { return }
                if adding { b.selection.insert(f.id) } else { b.selection = [f.id] }
            }
        }
        let paths = dragged.map(\.path)
        if let current = DragSessions.current, current.matches(paths) { return current }
        let model = self.model
        let target = self.target
        let session = DragDownloadSession(paths: paths) { done in
            // Into a folder of its own; the drop target copies each item from there.
            let dir = AppPaths.previewDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            model.downloadRemoteItems(dragged, from: target, to: dir) { outcome in
                guard let outcome else { done(([:], "The download was cancelled.")); return }
                done((outcome.arrived, outcome.message))
            }
        }
        DragSessions.current = session
        // The whole drag's server and paths, once for all its rows.
        DragSessions.clips = [ObjectIdentifier(session): RemoteClipboard.encode(RemoteClip(dragged, from: target))].compactMapValues { $0 }
        return session
    }

    private func download(_ items: [RemoteFile], ask: Bool = false) {
        guard let folder = model.downloadFolder(ask: ask) else { return }
        show("Downloading \(items.count) item(s) to \(folder.lastPathComponent)…")
        downloadItems(items, to: folder) { urls, failed in
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            if failed > 0 { show("\(failed) item(s) could not be downloaded — see Transfers", isError: true) }
        }
    }

    private func downloadItems(_ items: [RemoteFile], to local: URL, completion: @escaping ([URL], Int) -> Void) {
        model.downloadRemote(items, from: target, to: local, completion: completion)
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
        return model.pastedRemoteClip != nil || !PasteboardFiles.fileURLs(on: pb).isEmpty || PasteboardFiles.hasImageOnly(pb)
    }

    private var clipboardFromThisServer: Bool {
        model.pastedRemoteClip?.targetKey == target.key
    }

    /// Uploads into the current folder without overwriting: clashing names get a suffix.
    /// Many files travel as one packed stream (see Settings ▸ Transfers).
    /// - Parameters:
    ///   - from: the server the files were copied on (a paste through this Mac), for the notices.
    ///   - missing: items of that paste that could not be downloaded (said with the outcome).
    ///   - after: runs once when the upload has ended or will not happen.
    private func uploadSafely(_ urls: [URL], into b: FileBrowserModel, from: String? = nil, missing: Int = 0,
                              after: (() -> Void)? = nil) {
        guard !urls.isEmpty else { after?(); return }
        let dir = b.directory
        let fs = b.fs
        let transfers = model.transfers
        // Checking names and counting a large folder can take a while: shown above the list
        // ("Counting files… 12,345 files, 3.2 GB so far") and cancellable.
        let prep = transfers.beginPreparation(.upload, target: target,
                                              title: "Upload \(urls.count) item\(urls.count == 1 ? "" : "s") to \((dir as NSString).lastPathComponent)")
        Task {
            defer { transfers.endPreparation(prep) }
            do {
                let wanted = urls.map(\.lastPathComponent)
                guard let names = try await transfers.untilCancelled(prep, step: .checkingNames(urls.count), {
                    try await fs.uniqueNames(in: dir, for: wanted)
                }), let size = await transfers.measureLocal(urls, in: prep) else {
                    show("Upload cancelled — nothing was sent")
                    after?()
                    return
                }
                var reported = false
                let renamed = zip(urls, names).filter { $0.0.lastPathComponent != $0.1 }.count
                let made = model.transfers.uploadGroup(urls, names: names, to: dir, target: target,
                                                       fileCount: size.files, totalBytes: size.bytes) { items in
                    if !reported { reported = true; after?() }
                    let folder = (dir as NSString).lastPathComponent
                    let notAll = missing > 0 ? " — \(missing) of \(urls.count + missing) could not be downloaded from \(from ?? "the server")" : ""
                    if items.allSatisfy({ $0.state == .completed }) {
                        let n = "\(urls.count) item\(urls.count == 1 ? "" : "s")"
                        show((from.map { "Pasted \(n) from \($0) into \(folder)" } ?? "Uploaded \(n) to \(folder)")
                             + (renamed > 0 ? " — \(renamed) under a new name, nothing replaced" : "") + notAll, isError: missing > 0, ended: true)
                        Task {
                            await b.reload()
                            select(names, in: b, folder: dir)
                        }
                    } else {
                        Task { await b.reload() }
                        if items.contains(where: { if case .failed = $0.state { return true } else { return false } }) {
                            show("Not everything arrived in \(folder) — see Transfers\(notAll)", isError: true, ended: true)
                        } else {
                            show("Cancelled — what had not arrived in \(folder) yet was not sent\(notAll)", isError: true)
                        }
                    }
                }
                let how = made.first?.method == .archive ? " as one stream" : ""
                show(renamed > 0 ? "Uploading \(size.files.formatted()) file(s)\(how) — \(renamed) renamed to avoid overwriting"
                                 : "Uploading \(size.files.formatted()) file(s)\(how) to \((dir as NSString).lastPathComponent)", busy: true)
            } catch {
                show(error.localizedDescription, isError: true)
                after?()
            }
        }
    }

    /// ⌘C: the items go on the clipboard (see `ClipboardCopy`).
    private func copyItems(_ items: [RemoteFile]) {
        let what = "\(items.count) item\(items.count == 1 ? "" : "s")"
        show("Copied \(what) — paste here, on another server or in a terminal; downloading for Finder…", busy: true)
        let shown = notice?.id
        model.copyRemoteFiles(items, from: target) { urls in
            // Something else was copied meanwhile: the spinner goes, nothing more is said.
            guard ClipboardCopy.current?.isOnPasteboard == true else {
                if notice?.id == shown { withAnimation(.snappy) { notice = nil } }
                return
            }
            if let urls {
                show(urls.count == items.count ? "\(what) ready to paste in Finder (⌘V)"
                     : "\(urls.count) of \(items.count) items ready to paste in Finder (⌘V) — the others could not be downloaded",
                     isError: urls.count != items.count)
            }
            else { show("\(what) could not be downloaded for Finder — see Transfers", isError: true) }
        }
    }

    /// ⌘V into the folder shown: files copied on this server are copied (or moved) there on the
    /// server; from another server they come through this Mac (the temporary copy is removed
    /// afterwards); files from Finder or an image are uploaded. Nothing is ever replaced.
    private func paste(into b: FileBrowserModel, move: Bool = false) {
        let pb = NSPasteboard.general
        let clip = model.pastedRemoteClip
        let local = clip == nil ? (PasteboardFiles.filesToPaste(from: pb) ?? []) : []
        perform(FilePaste.decide(clip: clip, localFiles: local, into: target), into: b, move: move)
    }

    /// A drop on the list: rows dragged from a file manager (Tether's own type, read before any
    /// file is asked for, so nothing is downloaded for it), otherwise files from Finder.
    private func drop(_ providers: [NSItemProvider], into b: FileBrowserModel) -> Bool {
        let remote = providers.filter { $0.hasItemConformingToTypeIdentifier(RemoteClipboard.typeIdentifier) }
        guard remote.isEmpty else {
            let group = DispatchGroup()
            let lock = NSLock()
            var clips: [Int: RemoteClip] = [:]
            for (i, provider) in remote.enumerated() {
                group.enter()
                _ = provider.loadDataRepresentation(forTypeIdentifier: RemoteClipboard.typeIdentifier) { data, _ in
                    if let clip = data.flatMap(RemoteClipboard.decode) { lock.withLock { clips[i] = clip } }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                guard let clip = RemoteClipboard.merge(clips.sorted { $0.key < $1.key }.map(\.value)) else { return }
                let action = FilePaste.decideDrop(clip, into: target, directory: b.directory)
                // Dropped back where they came from: nothing to do, and nothing to say.
                if case .nothing = action { return }
                perform(action, into: b)
            }
            return true
        }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [Int: URL] = [:]
        for (i, provider) in files.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.withLock { urls[i] = url } }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            uploadSafely(urls.sorted { $0.key < $1.key }.map(\.value), into: b)
        }
        return true
    }

    private func perform(_ action: FilePaste, into b: FileBrowserModel, move: Bool = false) {
        let dir = b.directory
        switch action {
        case .onServer(let paths):
            let fs = b.fs
            let verb = move ? "Moving" : "Copying"
            show("\(verb) \(paths.count) item\(paths.count == 1 ? "" : "s") on the server…", busy: true)
            Task {
                do {
                    let names = try await fs.copyWithFreeNames(paths, to: dir, move: move)
                    let renamed = zip(paths, names).filter { ($0.0 as NSString).lastPathComponent != $0.1 }.count
                    show("\(move ? "Moved" : "Pasted") \(names.count) item\(names.count == 1 ? "" : "s") into \((dir as NSString).lastPathComponent)"
                         + (renamed > 0 ? " — \(renamed) under a new name, nothing replaced" : ""), ended: true)
                    FileBrowserModel.invalidate(target)
                    await b.reload()
                    select(names, in: b, folder: dir)
                } catch {
                    show(error.localizedDescription, isError: true)
                }
            }
        case .fromOtherServer(let clip):
            if move { show("Moving works within one server; from \(clip.target.displayName) the items are copied.") }
            show("Copying \(clip.items.count) item\(clip.items.count == 1 ? "" : "s") from \(clip.target.displayName) through this Mac — downloading…",
                 busy: true)
            model.localCopies(of: clip) { urls, madeHere in
                guard let urls else {
                    show("Nothing arrived from \(clip.target.displayName), so nothing was pasted — see Transfers", isError: true, ended: true)
                    return
                }
                uploadSafely(urls, into: b, from: clip.target.displayName, missing: max(clip.items.count - urls.count, 0),
                             after: { AppModel.removeTemporaryCopy(madeHere) })
            }
        case .upload(let urls):
            uploadSafely(urls, into: b)
        case .nothing(let why):
            show(why, isError: true)
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

    /// A notice below the list. `busy`: work under way — it stays (with a spinner) until the next
    /// notice says how it ended; errors stay longer than other notices.
    /// `ended`: how a paste or upload ended — also told by a macOS notification while Tether is
    /// not in front (it may have taken minutes).
    private func show(_ text: String, isError: Bool = false, busy: Bool = false, ended: Bool = false) {
        if ended { Notifier.shared.fileWorkEnded(text, on: target.displayName, failed: isError) }
        withAnimation(.snappy) { notice = Notice(text: text, isError: isError, busy: busy) }
        let current = notice?.id
        // A busy one goes in any case after a long while (its work never reports here, e.g. when
        // this view was rebuilt meanwhile).
        DispatchQueue.main.asyncAfter(deadline: .now() + (busy ? 1800 : isError ? 10 : 6)) {
            if notice?.id == current { withAnimation(.snappy) { notice = nil } }
        }
    }

    /// Selects the items just pasted into `b`'s folder (once it was reloaded), as Finder does.
    private func select(_ names: [String], in b: FileBrowserModel, folder: String) {
        guard b.directory == folder, b.search == nil else { return }
        let wanted = Set(names)
        let ids = Set(b.files.filter { wanted.contains($0.name) }.map(\.id))
        if !ids.isEmpty { b.selection = ids }
    }
}

/// The drag being started (its rows' providers are made one after another).
@MainActor
enum DragSessions {
    static var current: DragDownloadSession?
    /// The current drag's clip (`RemoteClipboard`'s data), by session: only the latest is kept.
    static var clips: [ObjectIdentifier: Data] = [:]
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
        let preparing = model.transfers.preparations.filter { $0.target == target }
        if !active.isEmpty || !preparing.isEmpty {
            VStack(spacing: 6) {
                ForEach(preparing) { prep in
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(prep.title).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(prep.statusText).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        Button { model.transfers.cancel(prep) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .help("Cancel")
                    }
                    .font(.caption)
                }
                ForEach(active) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(item.currentFile.isEmpty ? item.name : item.currentFile).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(item.state == .queued ? "Queued" : item.isStopping ? "Stopping…" : "\(item.transferred)  \(item.speed)  \(item.eta)")
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
                        Button("Download") { download([f]) }.prominentGlassButtonStyle()
                        if !f.isDirectory { Button("Quick Look") { quickLook(f) }.glassButtonStyle() }
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
                    Button("Download All") { download(files) }.prominentGlassButtonStyle()
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

    /// Never replaces anything in the folder (the same safe path as the file list's Download).
    private func download(_ files: [RemoteFile]) {
        guard let folder = model.downloadFolder() else { return }
        model.downloadRemote(files, from: target, to: folder) { urls, _ in
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
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
    var busy = false
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
                Button(button) { run() }.keyboardShortcut(.defaultAction).prominentGlassButtonStyle()
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

/// A large, easy-to-hit navigation button for the file manager.
private struct NavButton: View {
    let symbol: String
    let help: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering && enabled ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Calls `back` / `forward` for the mouse's side buttons (3 and 4) pressed over this view.
private struct MouseNavigationButtons: NSViewRepresentable {
    var back: () -> Void
    var forward: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.back = back
        view.forward = forward
    }

    final class MonitorView: NSView {
        var back: () -> Void = {}
        var forward: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                switch event.buttonNumber {
                case 3: self.back(); return nil
                case 4: self.forward(); return nil
                default: return event
                }
            }
        }

        // Never takes clicks itself; it only watches.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// ⌘C and ⌘V for the file list straight from the keyboard (SwiftUI's copy and paste commands do
/// not reliably reach a table). They act only while this list's table has the keyboard focus, so
/// the path field, a rename and other text fields keep their own copy and paste. A click in the
/// list gives it the keyboard, as in Finder: SwiftUI's table selects the row but left the keyboard
/// with the window (a new tab) or the path field (⌘V then pasted the copied paths into it).
struct FileListKeys: NSViewRepresentable {
    var copy: () -> Void
    var paste: () -> Void
    /// ⌘F (Find…) for this list: its search field.
    var find: () -> Void
    /// A Files tab or window (not the host panel beside a terminal).
    var standalone: Bool

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.copy = copy
        view.paste = paste
        view.find = find
        view.standalone = standalone
    }

    static func dismantleNSView(_ view: KeyView, coordinator: ()) {
        view.stopWatching()
    }

    final class KeyView: NSView {
        var copy: (() -> Void)?
        var paste: (() -> Void)?
        var find: (() -> Void)?
        var standalone = false
        private var monitor: Any?
        private var clicks: Any?
        /// A click began in this list (its keyboard is given when the click ends).
        private var pressed = false
        /// The file lists in windows now (weakly).
        private static let live = NSHashTable<KeyView>.weakObjects()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            Self.live.add(self)
            TerminalHost.keepsFocus = { responder in Self.live.allObjects.contains { $0.contains(responder) } }
            clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if event.type == .leftMouseDown {
                    pressed = self.table(in: window).flatMap { $0.enclosingScrollView }
                        .map { $0.bounds.contains($0.convert(event.locationInWindow, from: nil)) } ?? false
                    return event
                }
                guard pressed else { return event }
                pressed = false
                // After the click is handled (it selects the row first; moving the keyboard during
                // the click could undo that).
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window, let table = self.table(in: window),
                          !self.contains(window.firstResponder) else { return }
                    window.makeFirstResponder(table)
                }
                return event
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      let key = event.charactersIgnoringModifiers?.lowercased(), key == "c" || key == "v",
                      self.listHasFocus(in: window) else { return event }
                if key == "c" { self.copy?() } else { self.paste?() }
                return nil
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let clicks { NSEvent.removeMonitor(clicks) }
            monitor = nil
            clicks = nil
            Self.live.remove(self)
        }

        /// Find… (⌘F) in `window`: the search field of the file list that has the keyboard, or —
        /// with no terminal shown (a Files tab or window) — of the list shown. false: none here
        /// (the terminal's find bar opens as usual).
        static func find(in window: NSWindow, terminalShown: Bool) -> Bool {
            let lists = live.allObjects.filter { $0.window === window && $0.table(in: window) != nil }
            if let list = lists.first(where: { $0.contains(window.firstResponder) }) { list.find?(); return true }
            guard !terminalShown, let list = lists.first(where: \.standalone) ?? lists.first else { return false }
            list.find?()
            return true
        }

        /// `responder` is this list's table (or inside it).
        func contains(_ responder: NSResponder?) -> Bool {
            var view = responder as? NSView
            while let v = view, !(v is NSTableView) { view = v.superview }
            guard let table = view as? NSTableView, table.window === window else { return false }
            return isOver(table)
        }

        /// The keyboard is in this list — or with nobody (the window itself) while this is the only
        /// file list shown in the window, as right after its tab opened.
        private func listHasFocus(in window: NSWindow) -> Bool {
            if contains(window.firstResponder) { return true }
            guard window.firstResponder == nil || window.firstResponder === window, table(in: window) != nil else { return false }
            return !Self.live.allObjects.contains { $0 !== self && $0.window === window && $0.table(in: window) != nil }
        }

        /// This list's table: the one this view lies under.
        private func table(in window: NSWindow) -> NSTableView? {
            func find(_ v: NSView) -> NSTableView? {
                if let t = v as? NSTableView, isOver(t) { return t }
                for sub in v.subviews { if let t = find(sub) { return t } }
                return nil
            }
            return window.contentView.flatMap(find)
        }

        private func isOver(_ table: NSTableView) -> Bool {
            guard !isHiddenOrHasHiddenAncestor, !table.isHiddenOrHasHiddenAncestor else { return false }
            let area = table.enclosingScrollView ?? table
            return convert(bounds, to: nil).intersects(area.convert(area.bounds, to: nil))
        }
    }
}
