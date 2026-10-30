import AppKit
import TetherCore

/// Brings windows back as they were: which windows were open (front to back), each one's frame
/// and screen, whether it was in full screen, and its side panels (shown or not, their widths, the
/// host panel's tab). Each window's tabs and selected tab are in its
/// workspace. This does not depend on macOS window restoration, which is off whenever the system
/// setting "Close windows when quitting an application" is on.
@MainActor
enum WindowLayout {
    struct Entry: Codable, Equatable {
        var workspaceID: UUID
        var frame: CGRect
        var fullScreen: Bool
        /// nil: saved by a version without it (the window opens with the panels last used).
        var panels: Panels?
    }

    /// A window's sidebar and host panel.
    struct Panels: Codable, Equatable {
        var sidebar: Bool
        /// nil: not measured yet (the column's own width).
        var sidebarWidth: Double?
        var inspector: Bool
        var inspectorWidth: Double
        /// `InspectorTab.rawValue`.
        var inspectorTab: String?
    }

    /// Each open window's panels as they are now.
    private static var panels: [UUID: Panels] = [:]

    /// The panels a window had when it was saved (nil: a new window).
    static func savedPanels(for id: UUID) -> Panels? {
        loadIfNeeded()
        return panels[id] ?? pending.first { $0.workspaceID == id }?.panels
    }

    /// A window's panels changed: saved with its layout.
    static func update(_ p: Panels, for id: UUID) {
        guard panels[id] != p else { return }
        panels[id] = p
        scheduleSave()
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
        return Entry(workspaceID: id, frame: full ? (lastNormalFrame[id] ?? w.frame) : w.frame, fullScreen: full, panels: panels[id])
    }

    /// Frames before entering full screen (to restore the window's normal size later).
    static var lastNormalFrame: [UUID: CGRect] = [:]

    /// Saves the open windows (at quit). With none open (closed to the menu bar), the layout saved
    /// when the last one closed stays.
    static func saveOpenWindows() {
        let open = openWindows()
        guard !open.isEmpty else { return }
        store.saveSoon(open.map { entry($0.0, $0.1) }, within: DeferredWrites.relaxedDelay)
    }

    /// The last window is closing: remember it, so quitting from the menu bar brings it back.
    static func lastWindowClosing(_ id: UUID, _ window: NSWindow) {
        let e = entry(id, window)
        store.saveSoon([e], within: DeferredWrites.relaxedDelay)
        // The next window that opens without a workspace gets this one back.
        loaded = true
        pending = [e]
        firstHandedOut = false
    }

    private static var firstHandedOut = false
    private static var watched: Set<ObjectIdentifier> = []
    private static var observers: [ObjectIdentifier: [NSObjectProtocol]] = [:]

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
        pending.append(Entry(workspaceID: id, frame: frame, fullScreen: false, panels: panels[id]))
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

    /// Gives a window's sidebar its saved width. SwiftUI's column width is only a suggestion that
    /// AppKit's own per-window memory overrides (kept by scene number, so windows reopening in
    /// another order swapped widths); that memory is turned off and the divider is set directly,
    /// once laid out and again after AppKit's own first pass.
    static func applySidebarWidth(_ width: Double, in window: NSWindow) {
        func split(_ v: NSView) -> NSSplitView? {
            if let s = v as? NSSplitView, s.isVertical, s.arrangedSubviews.count >= 2 { return s }
            for sub in v.subviews { if let s = split(sub) { return s } }
            return nil
        }
        for delay in [0.0, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let content = window.contentView, let s = split(content) else { return }
                s.autosaveName = nil
                // Hidden (collapsed): it gets the width when shown again from AppKit's last value.
                guard let side = s.arrangedSubviews.first, !s.isSubviewCollapsed(side), side.frame.width > 0,
                      abs(side.frame.width - width) > 1 else { return }
                s.setPosition(width, ofDividerAt: 0)
            }
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
        let key = ObjectIdentifier(window)
        guard watched.insert(key).inserted else { return }
        let center = NotificationCenter.default
        // A closed window's observers go, and its identity is free again: a new window can reuse
        // the address, and must be watched.
        observers[key, default: []].append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                watched.remove(key)
                for t in observers.removeValue(forKey: key) ?? [] { center.removeObserver(t) }
            }
        })
        observers[key, default: []].append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main) { n in
            MainActor.assumeIsolated {
                if let w = n.object as? NSWindow { lastNormalFrame[id] = w.frame }
            }
        })
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers[key, default: []].append(center.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { scheduleSave() }
            })
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
