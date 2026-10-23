import AppKit
import Observation
import TetherCore
import SessionKit

/// The tabs of one window: an ordered list of sessions and the selected one.
struct Workspace: Codable, Identifiable, Equatable {
    var id: UUID
    var tabs: [UUID]
    var selected: UUID?

    init(id: UUID = UUID(), tabs: [UUID] = [], selected: UUID? = nil) {
        self.id = id
        self.tabs = tabs
        self.selected = selected
    }
}

/// All windows' tab lists. A session is in at most one workspace; sessions in none run in the
/// background. Switching tabs only changes `selected`, so the window itself never rebuilds.
@MainActor
@Observable
final class WorkspaceStore {
    private(set) var all: [UUID: Workspace] = [:]
    @ObservationIgnored private var windows: [UUID: WeakWindow] = [:]
    @ObservationIgnored private var states: [UUID: WeakState] = [:]
    private struct WeakState { weak var state: WindowState? }
    @ObservationIgnored private let store = JSONStore<[Workspace]>(filename: "workspaces.json")
    /// Opens a window for a workspace (installed by any open window, which has `openWindow`).
    @ObservationIgnored var openWindow: ((UUID) -> Void)?

    private struct WeakWindow { weak var window: NSWindow? }

    init() {
        for w in store.load() ?? [] { all[w.id] = w }
    }

    func workspace(_ id: UUID) -> Workspace {
        all[id] ?? Workspace(id: id)
    }

    func workspace(containing session: UUID) -> UUID? {
        all.values.first { $0.tabs.contains(session) }?.id
    }

    /// Adds a session as a tab (moving it out of any other window) and optionally selects it.
    func add(_ session: UUID, to id: UUID, select: Bool = true, before: UUID? = nil) {
        detach(session)
        var w = workspace(id)
        if let before, let i = w.tabs.firstIndex(of: before) { w.tabs.insert(session, at: i) } else { w.tabs.append(session) }
        if select || w.selected == nil { w.selected = session }
        all[id] = w
        AppModel.shared.sessions.setBackground(session, false)
        save()
    }

    /// Removes a session from whatever window shows it. Returns that window's id.
    @discardableResult
    func detach(_ session: UUID) -> UUID? {
        guard let id = workspace(containing: session), var w = all[id] else { return nil }
        let index = w.tabs.firstIndex(of: session) ?? 0
        w.tabs.removeAll { $0 == session }
        if w.selected == session {
            w.selected = w.tabs.isEmpty ? nil : w.tabs[min(index, w.tabs.count - 1)]
        }
        all[id] = w
        save()
        return id
    }

    func select(_ session: UUID, in id: UUID) {
        guard var w = all[id], w.tabs.contains(session), w.selected != session else { return }
        w.selected = session
        all[id] = w
        save()
    }

    func selectNeighbour(in id: UUID, offset: Int) {
        guard let w = all[id], !w.tabs.isEmpty else { return }
        let i = w.selected.flatMap { w.tabs.firstIndex(of: $0) } ?? 0
        select(w.tabs[(i + offset + w.tabs.count) % w.tabs.count], in: id)
    }

    func select(index: Int, in id: UUID) {
        guard let w = all[id], !w.tabs.isEmpty else { return }
        let i = index < 0 ? w.tabs.count - 1 : min(index, w.tabs.count - 1)
        select(w.tabs[i], in: id)
    }

    /// The window is closing: its sessions keep running in the background.
    func windowClosed(_ id: UUID) {
        let closingWindow = windows[id]?.window
        let isLast = windows.filter { $0.key != id && $0.value.window?.isVisible == true }.isEmpty
        windows[id] = nil
        if isLast, !AppModel.shared.isTerminating {
            // The last window keeps its workspace (tabs, selection): the next window — from the menu
            // bar, the Dock or after relaunch — opens it again, with the same size and position.
            if let closingWindow { WindowLayout.lastWindowClosing(id, closingWindow) }
            MenuBarState.lastWindowClosed()
            save()
            return
        }
        guard let w = all.removeValue(forKey: id) else { return }
        for s in w.tabs { AppModel.shared.sessions.setBackground(s, true) }
        save()
        // Closed on purpose: it is not part of the layout that comes back after a crash or relaunch.
        WindowLayout.scheduleSave()
    }

    /// A session ended for good.
    func sessionRemoved(_ session: UUID) {
        detach(session)
    }

    /// Moves every tab of every window into `id` (Window ▸ Merge All Windows).
    func mergeAll(into id: UUID) {
        let others = all.keys.filter { $0 != id }
        for o in others {
            for s in all[o]?.tabs ?? [] { add(s, to: id, select: false) }
            window(of: o)?.close()
        }
    }

    // MARK: Windows

    func register(_ window: NSWindow, for id: UUID, state: WindowState) {
        if windows[id]?.window !== window { windows[id] = WeakWindow(window: window) }
        states[id] = WeakState(state: state)
        if all[id] == nil { all[id] = Workspace(id: id) }
    }

    func window(of id: UUID) -> NSWindow? { windows[id]?.window }

    func state(ofWorkspace id: UUID) -> WindowState? { states[id]?.state }

    /// The frontmost open window's state (key window first).
    var frontState: WindowState? {
        if let key = NSApp.keyWindow, let st = state(of: key) { return st }
        for w in NSApp.orderedWindows { if let st = state(of: w) { return st } }
        return states.values.compactMap(\.state).first { $0.window?.isVisible == true }
    }

    func workspace(of window: NSWindow) -> UUID? {
        windows.first { $0.value.window === window }?.key
    }

    func state(of window: NSWindow) -> WindowState? {
        workspace(of: window).flatMap { states[$0]?.state }
    }

    /// Brings a session's tab to the front. Returns false if it is not shown in any window.
    @discardableResult
    func focus(_ session: UUID) -> Bool {
        guard let id = workspace(containing: session) else { return false }
        select(session, in: id)
        window(of: id)?.makeKeyAndOrderFront(nil)
        return true
    }

    /// Workspaces restored from disk whose windows did not come back (e.g. after a crash) are
    /// dropped at launch. Returns their tabs in order so they can be reopened in a window.
    func pruneWithoutWindows() -> [UUID] {
        var orphaned: [UUID] = []
        for (id, w) in all.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where windows[id]?.window == nil {
            all[id] = nil
            orphaned += w.tabs
        }
        save()
        return orphaned
    }

    /// At launch: closes restored windows that ended up empty when another window has tabs
    /// (e.g. windows left over from an older version), keeping at least one window.
    func closeRedundantEmptyWindows(keeping: UUID) {
        let open = windows.compactMap { id, w in w.window.map { (id, $0) } }
        guard open.count > 1 else { return }
        for (id, window) in open where id != keeping && (all[id]?.tabs.isEmpty ?? true) {
            window.close()
        }
    }

    /// Drops tabs whose sessions no longer exist (e.g. plain shells after a relaunch).
    func removeMissing(existing: Set<UUID>) {
        for (id, var w) in all {
            let kept = w.tabs.filter { existing.contains($0) }
            if kept != w.tabs {
                w.tabs = kept
                if let s = w.selected, !kept.contains(s) { w.selected = kept.first }
                all[id] = w
            }
        }
        save()
    }

    private func save() {
        store.saveSoon(Array(all.values))
    }
}
