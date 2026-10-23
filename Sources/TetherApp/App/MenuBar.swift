import SwiftUI
import TetherCore
import SessionKit

/// Keeps Tether in the menu bar: closing the last window hides the Dock icon while every session
/// keeps running; opening a window (from the menu bar, the Dock or ⌘N) brings the icon back.
@MainActor
enum MenuBarState {
    static func lastWindowClosed() {
        guard AppModel.shared.settings.keepRunningInMenuBar, !AppModel.shared.isTerminating else { return }
        // Let the window finish closing first.
        DispatchQueue.main.async {
            let visible = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
            if !visible { NSApp.setActivationPolicy(.accessory) }
        }
    }

    static func windowOpened() {
        // Only undo what lastWindowClosed did, and not in the middle of the window's first layout.
        guard NSApp.activationPolicy() == .accessory else { return }
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
    }
}

/// The menu bar item: open Tether, jump to a session, start a connection, quit.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var live: [TerminalSession] {
        model.sessions.sessions.filter { !$0.phase.isDead }
            .sorted { rank($0) < rank($1) }
    }

    private func rank(_ s: TerminalSession) -> Int {
        switch s.phase {
        case .online: 0
        case .connecting, .waiting: 1
        case .suspended: 2
        case .dead: 3
        }
    }

    var body: some View {
        if AppLock.shared.isLocked {
            Button("Unlock Tether…") { open() }
            Divider()
            Button("Quit Tether") { NSApp.terminate(nil) }
        } else {
            unlockedMenu
        }
    }

    @ViewBuilder
    private var unlockedMenu: some View {
        Button("Open Tether") { open() }
            .keyboardShortcut("o")
        Button("New Connection…") {
            open()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                model.workspaces.frontState?.showQuickConnect = true
            }
        }
        .keyboardShortcut("n")
        Divider()
        let sessions = live
        if sessions.isEmpty {
            Text("No sessions")
        } else {
            let online = sessions.filter(\.phase.isOnline).count
            Text("\(online) of \(sessions.count) session\(sessions.count == 1 ? "" : "s") online")
            ForEach(sessions.prefix(20)) { s in
                Button {
                    open(session: s)
                } label: {
                    Text("\(symbol(s)) \(s.displayTitle) — \(s.descriptor.target.displayName)")
                }
            }
            if sessions.count > 20 { Text("and \(sessions.count - 20) more…") }
        }
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit Tether") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func symbol(_ s: TerminalSession) -> String {
        switch s.phase {
        case .online: "●"
        case .connecting, .waiting: "◐"
        case .suspended: "‖"
        case .dead: "○"
        }
    }

    /// Brings a window to the front, opening one if none is open.
    private func open(session: TerminalSession? = nil) {
        MenuBarState.windowOpened()
        if let session, model.workspaces.focus(session.id) {
            NSApp.activate()
            return
        }
        if let state = model.workspaces.frontState, let window = state.window {
            window.makeKeyAndOrderFront(nil)
            if let session { state.show(session) }
        } else {
            // No value: the window gets the last closed workspace back (tabs, size, position).
            openWindow(id: "workspace")
            if let session {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.workspaces.frontState?.show(session) }
            }
        }
        NSApp.activate()
    }
}
