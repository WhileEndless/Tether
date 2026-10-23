import AppKit
import TetherCore

/// Brings windows back as they were: which windows were open (front to back), each one's frame
/// and screen, and whether it was in full screen. Each window's tabs and selected tab are in its
/// workspace. This does not depend on macOS window restoration, which is off whenever the system
/// setting "Close windows when quitting an application" is on.
@MainActor
enum WindowLayout {
    struct Entry: Codable, Equatable {
        var workspaceID: UUID
        var frame: CGRect
        var fullScreen: Bool
    }

    private static let store = JSONStore<[Entry]>(filename: "window-layout.json")
    /// Saved entries not yet reopened at launch.
    private static var pending: [Entry] = []
    private static var loaded = false

    /// Workspace windows, front to back.
    private static func openWindows() -> [(UUID, NSWindow)] {
        NSApp.orderedWindows.compactMap { w in
            AppModel.shared.workspaces.workspace(of: w).map { ($0, w) }
        }.filter { $0.1.isVisible || $0.1.isMiniaturized }
    }

    private static func entry(_ id: UUID, _ w: NSWindow) -> Entry {
        let full = w.styleMask.contains(.fullScreen)
        return Entry(workspaceID: id, frame: full ? (lastNormalFrame[id] ?? w.frame) : w.frame, fullScreen: full)
    }

    /// Frames before entering full screen (to restore the window's normal size later).
    static var lastNormalFrame: [UUID: CGRect] = [:]

    /// Saves the open windows (at quit). With none open (closed to the menu bar), the layout saved
    /// when the last one closed stays.
    static func saveOpenWindows() {
        let open = openWindows()
        guard !open.isEmpty else { return }
        store.saveSoon(open.map { entry($0.0, $0.1) })
    }

    /// The last window is closing: remember it, so quitting from the menu bar brings it back.
    static func lastWindowClosing(_ id: UUID, _ window: NSWindow) {
        let e = entry(id, window)
        store.saveSoon([e])
        // The next window that opens without a workspace gets this one back.
        loaded = true
        pending = [e]
        firstHandedOut = false
    }

    private static var firstHandedOut = false
    private static var watched: Set<ObjectIdentifier> = []

    /// The workspace for the window SwiftUI opens at launch: the frontmost saved one (once).
    static func firstWorkspaceAtLaunch() -> UUID {
        loadIfNeeded()
        guard !firstHandedOut, let first = pending.first else { return UUID() }
        firstHandedOut = true
        return first.workspaceID
    }

    /// Opens the next window for `id` at a given frame (a tab dragged out lands where it is dropped).
    static func place(_ id: UUID, frame: CGRect) {
        loadIfNeeded()
        pending.removeAll { $0.workspaceID == id }
        pending.append(Entry(workspaceID: id, frame: frame, fullScreen: false))
        firstHandedOut = true   // not the launch window
    }

    /// Windows that did not come back in time are given up (their tabs go to the first window).
    static func finishReopening() {
        pending = []
    }

    /// Opens the other saved windows (back to front, so the front one ends up in front).
    static func openRemaining(using open: (UUID) -> Void) {
        loadIfNeeded()
        let alreadyOpen = Set(openWindows().map(\.0))
        for e in pending.dropFirst().reversed() where !alreadyOpen.contains(e.workspaceID) {
            open(e.workspaceID)
        }
    }

    /// Workspaces whose windows are still being reopened (their tabs must not be moved elsewhere).
    static var reopening: Set<UUID> {
        loadIfNeeded()
        return Set(pending.map(\.workspaceID))
    }

    /// A window appeared: give it its saved size, position and full-screen state.
    static func apply(to window: NSWindow, workspace id: UUID) {
        loadIfNeeded()
        // Tether restores windows itself; macOS restoration would bring back duplicates.
        window.isRestorable = false
        guard let i = pending.firstIndex(where: { $0.workspaceID == id }) else { return }
        let e = pending.remove(at: i)
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(e.frame) }), e.frame.width > 300 {
            window.setFrame(e.frame, display: true)
        }
        if e.fullScreen && !window.styleMask.contains(.fullScreen) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { window.toggleFullScreen(nil) }
        }
    }

    private static func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard AppModel.shared.settings.restoreSessionsOnLaunch else { return }
        let saved = store.load() ?? []
        let known = Set(AppModel.shared.workspaces.all.keys)
        pending = saved.filter { known.contains($0.workspaceID) }
    }

    /// Keeps the saved layout current as windows move, resize and enter or leave full screen,
    /// so it is right even after a crash. Normal frames are kept for full-screen windows.
    static func watch(_ window: NSWindow, workspace id: UUID) {
        guard watched.insert(ObjectIdentifier(window)).inserted else { return }
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { n in
            MainActor.assumeIsolated {
                if let w = n.object as? NSWindow { lastNormalFrame[id] = w.frame }
            }
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            center.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { scheduleSave() }
            }
        }
        scheduleSave()
    }

    private static var saveWork: DispatchWorkItem?

    /// Saves the open windows a second after the last change (one small write, not one per pixel).
    static func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { saveOpenWindows() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}
