import AppKit
import Observation
import SwiftUI
import TetherCore
import SessionKit

/// How a new session should be shown.
enum OpenMode {
    /// As a new tab of this window.
    case tab
    /// In a new window.
    case window
}

/// One tab: a terminal or a file manager.
@MainActor
enum TabItem: @MainActor Identifiable {
    case terminal(TerminalSession)
    case files(FileTab)

    var id: UUID {
        switch self {
        case .terminal(let s): s.id
        case .files(let f): f.id
        }
    }

    var target: ConnectionTarget {
        switch self {
        case .terminal(let s): s.descriptor.target
        case .files(let f): f.target
        }
    }
}

/// UI state of one window. The window's tabs live in its `Workspace`.
@MainActor
@Observable
final class WindowState {
    var sidebarSelection: SidebarItem?
    var showQuickConnect = false
    var hostEditor: HostEditorRequest?
    var keySetupTarget: KeySetupRequest?
    var showConfigEditor = false
    var showSwitcher = false
    var inspectorTab: InspectorTab = .overview
    /// Set by views that want the host panel shown (the window owns the visibility state).
    var showInspectorRequest = false
    /// Flipped by View ▸ Show or Hide Host Panel.
    var toggleInspector = false
    var showTransfers = false
    /// Session being renamed (tab strip, sidebar or menu).
    var renamingSession: TerminalSession?
    /// Files dropped on a terminal, waiting for a destination.
    var uploadRequest: UploadRequest?
    /// Session whose password prompt the user wants to type into (secure sheet).
    var passwordEntry: TerminalSession?

    let workspaceID: UUID
    @ObservationIgnored weak var window: NSWindow?

    init(workspaceID: UUID) {
        self.workspaceID = workspaceID
    }

    private var model: AppModel { AppModel.shared }

    var workspace: Workspace { model.workspaces.workspace(workspaceID) }

    /// The selected tab's session (nil when a file tab or nothing is selected).
    var session: TerminalSession? { workspace.selected.flatMap { model.sessions.session($0) } }

    /// Terminal tabs only.
    var tabs: [TerminalSession] { workspace.tabs.compactMap { model.sessions.session($0) } }

    func item(_ id: UUID) -> TabItem? {
        if let s = model.sessions.session(id) { return .terminal(s) }
        if let f = model.fileTabs.tab(id) { return .files(f) }
        return nil
    }

    /// All tabs of this window in order.
    var items: [TabItem] { workspace.tabs.compactMap(item) }

    var selectedItem: TabItem? { workspace.selected.flatMap(item) }

    /// Opens a file manager tab for a host, in a directory (nil = last used / home).
    func openFiles(_ target: ConnectionTarget, path: String? = nil, mode: OpenMode = .tab) {
        let tab = model.fileTabs.open(target, path: path ?? model.metadata(for: target.key).lastRemoteDirectory)
        present(tab.id, mode: mode)
    }

    /// Shows a file tab: selects it where it is open, or brings it here from the background.
    func show(_ tab: FileTab) {
        if !model.workspaces.focus(tab.id) { present(tab.id, mode: .tab) }
    }

    /// Closes any tab. File tabs close immediately; terminals may ask first.
    func close(_ item: TabItem) {
        switch item {
        case .terminal(let s): closeTab(s)
        case .files(let f):
            model.workspaces.detach(f.id)
            model.fileTabs.close(f.id)
        }
    }

    /// Keeps a tab's content alive but removes it from the window (listed in the sidebar).
    func moveToBackground(_ item: TabItem) {
        model.workspaces.detach(item.id)
        if case .terminal(let s) = item { model.sessions.setBackground(s.id, true) }
    }

    /// The host shown in the inspector: the sidebar selection, else the selected tab's host.
    var inspectedTarget: ConnectionTarget? {
        if case .host(let key) = sidebarSelection { return model.target(forKey: key) }
        if case .session(let id) = sidebarSelection, let item = item(id) { return item.target }
        return selectedItem?.target
    }

    /// Opens a new session to `target`.
    @discardableResult
    func connect(_ target: ConnectionTarget, mode: OpenMode = .tab, remoteSessionName: String? = nil,
                 persistence: PersistenceMode? = nil, directory: String? = nil) -> TerminalSession {
        let meta = model.metadata(for: target.key)
        let session = model.sessions.open(target, color: meta.color, persistence: persistence ?? meta.persistence,
                                          remoteSessionName: remoteSessionName, directory: directory)
        present(session.id, mode: model.settings.openNewSessionsInWindow ? .window : mode)
        return session
    }

    /// Shows a session as a tab here, or in a new window.
    func present(_ id: UUID, mode: OpenMode) {
        // Opening a suspended session reconnects it.
        model.sessions.session(id)?.resume()
        switch mode {
        case .tab:
            model.workspaces.add(id, to: workspaceID)
        case .window:
            let ws = UUID()
            model.workspaces.add(id, to: ws)
            if let frame = window?.frame {
                WindowLayout.place(ws, frame: frame.offsetBy(dx: 32, dy: -32))
            }
            model.workspaces.openWindow?(ws)
        }
    }

    /// Shows an existing session: selects its tab (in whichever window) or brings it here from the background.
    func show(_ session: TerminalSession) {
        session.resume()
        if !model.workspaces.focus(session.id) { present(session.id, mode: .tab) }
    }

    /// Drops the connection now (the tmux/screen session keeps running) and moves the tab to the background.
    func disconnectToBackground(_ session: TerminalSession) {
        model.workspaces.detach(session.id)
        model.sessions.suspend(session.id)
    }

    func select(_ session: TerminalSession) {
        model.workspaces.select(session.id, in: workspaceID)
    }

    func select(_ id: UUID) {
        model.workspaces.select(id, in: workspaceID)
    }

    /// Ends a session and its shell on the server (tmux/screen session included), after one confirmation.
    func terminate(_ session: TerminalSession) {
        confirm("Terminate \u{201C}\(session.displayTitle)\u{201D}?",
                "The shell and anything running in it on the server will be stopped.") { [model] in
            model.sessions.close(session.id, killRemote: true)
        }
    }

    /// Ends every session to a host, including detached Tether sessions left on the server.
    func terminateAll(on target: ConnectionTarget) {
        let open = model.sessions.sessions(for: target.key).filter { !$0.phase.isDead }
        let monitor = model.monitor(for: target)
        confirm("Terminate all sessions on \(target.displayName)?",
                "\(open.count) open session\(open.count == 1 ? "" : "s") and any detached Tether sessions on the server will be stopped. Your own tmux sessions are not touched.") { [model] in
            for s in open { model.sessions.close(s.id, killRemote: true) }
            Task { _ = await monitor.cleanUpOrphans(keeping: []) }
        }
    }

    private func confirm(_ title: String, _ message: String, action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        if let window {
            alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { action() } }
        } else if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }

    /// Closes a tab, asking first when the session is online. A session that is not connected
    /// (still connecting, or failing to reconnect) just closes: keeping it would only keep it
    /// retrying. A tmux/screen session it had on the server stays there and is listed under the
    /// host, ready to attach.
    func closeTab(_ session: TerminalSession) {
        // Nothing was done in it: close without asking and leave nothing behind on the server.
        if session.phase.isOnline && session.isUnused {
            model.sessions.close(session.id, killRemote: true)
            return
        }
        if !session.phase.isOnline {
            // Never connected: nothing to keep, so nothing is left behind on the server either.
            // (A session that was online and lost its connection keeps running there.)
            model.sessions.close(session.id, killRemote: !session.wasOnline)
            return
        }
        if !model.settings.confirmCloseOnlineSessions {
            model.sessions.close(session.id, killRemote: false)
            return
        }
        guard let window else { return }
        CloseConfirmation.ask(for: session, in: window) { [model] choice in
            switch choice {
            case .background?:
                model.workspaces.detach(session.id)
                model.sessions.setBackground(session.id, true)
            case .terminate?:
                model.sessions.close(session.id, killRemote: true)
            case nil:
                break
            }
        }
    }
}

struct WindowStateKey: FocusedValueKey { typealias Value = WindowState }

extension FocusedValues {
    var windowState: WindowState? {
        get { self[WindowStateKey.self] }
        set { self[WindowStateKey.self] = newValue }
    }
}

/// Asks whether to keep a session running in the background or terminate it.
@MainActor
enum CloseConfirmation {
    enum Choice { case background, terminate }

    static func ask(for session: TerminalSession, in window: NSWindow, completion: @escaping (Choice?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Close \u{201C}\(session.displayTitle)\u{201D}?"
        alert.informativeText = "Keep it running in the background — it stays connected and listed in the sidebar, "
            + "so you can reopen it any time — or terminate the shell on the server."
        alert.addButton(withTitle: "Keep in Background")
        alert.addButton(withTitle: "Terminate")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: completion(.background)
            case .alertSecondButtonReturn: completion(.terminate)
            default: completion(nil)
            }
        }
    }
}

/// Reports the NSWindow hosting a SwiftUI view.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = AccessorView()
        v.onWindow = onWindow
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class AccessorView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

extension View {
    /// Utility windows (transcripts, file browsers, search) never take part in window tabbing.
    func standaloneWindow() -> some View {
        background(WindowAccessor { $0.tabbingMode = .disallowed })
    }
}
