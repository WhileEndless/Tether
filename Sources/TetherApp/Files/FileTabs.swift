import Foundation
import Observation
import TetherCore
import FileTransferKit

/// A file manager opened as a tab (like a terminal). Its browser state lives on while it is
/// in the background or in another window.
struct FileTab: Codable, Identifiable, Hashable {
    var id: UUID
    var target: ConnectionTarget
    /// Last directory, used to restore the tab after a relaunch.
    var path: String?
}

@MainActor
@Observable
final class FileTabStore {
    private(set) var tabs: [UUID: FileTab] = [:]
    @ObservationIgnored private var browsers: [UUID: FileBrowserModel] = [:]
    @ObservationIgnored private let store = JSONStore<[FileTab]>(filename: "file-tabs.json")

    init() {
        for t in store.load() ?? [] { tabs[t.id] = t }
    }

    func tab(_ id: UUID) -> FileTab? { tabs[id] }

    func tabs(for targetKey: String) -> [FileTab] {
        tabs.values.filter { $0.target.key == targetKey }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    @discardableResult
    func open(_ target: ConnectionTarget, path: String?) -> FileTab {
        let tab = FileTab(id: UUID(), target: target, path: path)
        tabs[tab.id] = tab
        save()
        return tab
    }

    func close(_ id: UUID) {
        tabs[id] = nil
        // What it had under way on the server (a listing, a search) stops with it.
        browsers.removeValue(forKey: id)?.stopWork()
        save()
    }

    /// The browser of a tab, created on first use and kept for the tab's lifetime.
    func browser(for tab: FileTab) -> FileBrowserModel {
        if let b = browsers[tab.id] { return b }
        let b = FileBrowserModel(target: tab.target, fs: RemoteFileSystem(executor: AppModel.shared.executor(for: tab.target)))
        browsers[tab.id] = b
        return b
    }

    /// The ssh settings changed (program, connection sharing): open file tabs use them from now on.
    func settingsChanged() {
        for b in browsers.values {
            let executor = AppModel.shared.executor(for: b.target)
            if b.fs.executor.options != executor.options { b.fs = RemoteFileSystem(executor: executor) }
        }
    }

    /// Title for tab bars and the sidebar: the directory name.
    func title(of tab: FileTab) -> String {
        let dir = browsers[tab.id]?.directory ?? tab.path ?? ""
        let name = (dir as NSString).lastPathComponent
        return name.isEmpty ? "Files" : name
    }

    /// Remembers the current directory of every tab (called before quitting).
    func saveDirectories() {
        for (id, b) in browsers where !b.directory.isEmpty { tabs[id]?.path = b.directory }
        save()
    }

    private func save() { store.save(Array(tabs.values)) }
}
