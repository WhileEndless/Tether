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
    /// Quick Connect was opened with ⌘↩: start in the host search.
    var quickConnectSearch = false
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

    /// Opens a file manager tab for a host, in a directory (nil = the home folder).
    func openFiles(_ target: ConnectionTarget, path: String? = nil, mode: OpenMode = .tab) {
        // Without a folder (sidebar, menu) the file manager starts in the home folder.
        let tab = model.fileTabs.open(target, path: path)
        present(tab.id, mode: mode)
    }

    /// "Browse" a terminal's folder: on this Mac in Finder (Settings ▸ General ▸ Tabs & Windows ▸
    /// Browse folders of this Mac in Finder), elsewhere in a file manager tab.
    func browse(_ target: ConnectionTarget, path: String? = nil) {
        guard target.isLocal, model.settings.browseLocalInFinder else { openFiles(target, path: path); return }
        // The folder itself in a Finder window (also for packages such as Foo.app, which `open`
        // would launch); a folder that is gone gives its nearest existing parent.
        var folder = URL(fileURLWithPath: ((path ?? "~") as NSString).expandingTildeInPath, isDirectory: true)
        var isDir: ObjCBool = false
        while !(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue), folder.path != "/" {
            folder.deleteLastPathComponent()
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
    }

    /// Whether `browse` opens Finder for this target.
    func browsesInFinder(_ target: ConnectionTarget) -> Bool { target.isLocal && model.settings.browseLocalInFinder }

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

    /// Opens the host panel on what runs in the selected terminal (an explicit request: the panel
    /// is shown even when it was closed).
    func showRunningCommand(_ session: TerminalSession? = nil) {
        guard let s = session ?? self.session else { return }
        sidebarSelection = .session(s.id)
        inspectorTab = .command
        showInspectorRequest = true
    }

    /// The user went back to a terminal (clicked into it, or on its tab while it was already in
    /// front): a host row clicked in the sidebar meanwhile no longer decides what the sidebar and
    /// the host panel show — the terminal in front does.
    func follow(_ session: TerminalSession) {
        guard selectedItem?.id == session.id, sidebarSelection != .session(session.id) else { return }
        sidebarSelection = .session(session.id)
    }

    /// The same for a file manager tab.
    func follow(_ fileTab: UUID) {
        guard selectedItem?.id == fileTab, sidebarSelection != .files(fileTab) else { return }
        sidebarSelection = .files(fileTab)
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
                 persistence: PersistenceMode? = nil, directory: String? = nil, isPrivate: Bool = false) -> TerminalSession {
        let meta = model.metadata(for: target.key)
        let session = model.sessions.open(target, color: meta.color, persistence: persistence ?? meta.persistence,
                                          remoteSessionName: remoteSessionName, directory: directory, isPrivate: isPrivate)
        present(session.id, mode: model.settings.openNewSessionsInWindow ? .window : mode)
        return session
    }

    /// A new session to the same host as `session` — in the folder its shell is in now, unless
    /// Settings ▸ General says new tabs start in the home folder. A private tab's new tab is private
    /// too, as is every tab when `isPrivate` is set.
    func newSession(like session: TerminalSession, mode: OpenMode = .tab, isPrivate: Bool = false) {
        let target = session.descriptor.target
        let isPrivate = isPrivate || session.descriptor.isPrivate
        guard model.settings.newTabDirectory == .current else {
            connect(target, mode: mode, isPrivate: isPrivate)
            return
        }
        Task {
            let directory = await session.workingDirectory()
            connect(target, mode: mode, directory: directory, isPrivate: isPrivate)
        }
    }

    /// Shows a session as a tab here, or in a new window.
    func present(_ id: UUID, mode: OpenMode) {
        // Opening a suspended session reconnects it.
        model.sessions.session(id)?.resume()
        switch mode {
        case .tab:
            // Next to the tab being worked in (Settings ▸ General), like browsers and Terminal.app.
            let current = model.settings.newTabPosition == .afterCurrent ? model.workspaces.workspace(workspaceID).selected : nil
            model.workspaces.add(id, to: workspaceID, after: current)
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
        // Brought back to work in: it is no longer to be ended when connected.
        model.sessions.keepRunning(session.id)
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
                "The shell and anything running in it on the server will be stopped.") { [weak self] in
            self?.endOnServer(session)
        }
    }

    /// Ends the session on the server. Not connected: the server is reached first (one sign-in for
    /// it if needed); if it cannot be reached, the user chooses to keep the session disconnected or
    /// to have it ended as soon as the server can be reached again.
    private func endOnServer(_ session: TerminalSession) {
        let persistent = session.persistence == .tmux || session.persistence == .screen
        guard !session.phase.isOnline, persistent, !session.descriptor.target.isLocal else {
            model.sessions.close(session.id, killRemote: true)
            return
        }
        Task { @MainActor [weak self, model] in
            if await model.sessions.endOnServer(session.id) { return }
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "\(session.descriptor.target.displayName) cannot be reached"
            alert.informativeText = "The session \u{201C}\(session.displayTitle)\u{201D} keeps running on the server until it can be ended there.\n\nEnd When Connected moves the tab to the background and ends the session as soon as the server can be reached (if the server asks for a password and none is remembered, it waits until you open one of its tabs). Keep in Background keeps it for you to close later. Opening it again takes the request back."
            alert.addButton(withTitle: "End When Connected")
            alert.addButton(withTitle: "Keep in Background")
            alert.addButton(withTitle: "Cancel")
            let handle: (NSApplication.ModalResponse) -> Void = { response in
                switch response {
                case .alertFirstButtonReturn:
                    model.workspaces.detach(session.id)
                    model.sessions.endWhenConnected(session.id)
                case .alertSecondButtonReturn:
                    self.disconnectToBackground(session)
                default:
                    break
                }
            }
            if let window = self.window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
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

    /// Tether's sessions on a host that no tab here has open (detached): they may be tabs the last
    /// run left behind, still running. Asked first, naming them: opened again as tabs, or ended.
    func cleanUpLeftovers(on target: ConnectionTarget, done: @escaping () -> Void = {}) {
        let monitor = model.monitor(for: target)
        let open = Set(model.sessions.sessions(for: target.key).filter { !$0.phase.isDead }.map(\.descriptor.remoteSessionName))
        let leftovers = monitor.remoteSessions.filter { $0.isTether && !open.contains($0.name) && !$0.attached }
        guard !leftovers.isEmpty else { done(); return }
        let alert = NSAlert()
        alert.messageText = "\(leftovers.count) Tether session\(leftovers.count == 1 ? " is" : "s are") not open in any tab on \(target.displayName)"
        let listed = leftovers.prefix(8).map { e -> String in
            var line = "• " + e.name
            if let at = e.lastActivity ?? e.created { line += " — last used " + at.formatted(date: .abbreviated, time: .shortened) }
            if let w = e.windows, w > 1 { line += ", \(w) windows" }
            return line
        }
        alert.informativeText = (listed + (leftovers.count > 8 ? ["and \(leftovers.count - 8) more"] : [])).joined(separator: "\n")
            + "\n\nThey may still hold work (a tab the last run did not bring back). Open them as tabs, or end them and what runs in them."
        alert.addButton(withTitle: "Open as Tabs")
        alert.addButton(withTitle: "End Them")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[1].hasDestructiveAction = true
        let answer: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                for e in leftovers { self?.connect(target, remoteSessionName: e.name, persistence: e.kind == .tmux ? .tmux : .screen) }
                done()
            case .alertSecondButtonReturn:
                Task { _ = await monitor.cleanUpOrphans(keeping: open); done() }
            default:
                done()
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: answer) } else { answer(alert.runModal()) }
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
            // A session that was online and lost its connection, or one restored or opened to
            // attach to an existing server session, keeps running there.
            model.sessions.close(session.id, killRemote: !session.mayHoldServerWork)
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

extension WindowState {
    /// Closing a window (its close button or ⇧⌘W). While another Tether window is open, a window with
    /// tabs asks first: keep its tabs running in the background (the default — they stay connected and
    /// listed in the sidebar), or move them all to the other window. The last window just closes;
    /// Tether keeps everything and brings the window back from the menu bar.
    /// Closes `window`, ending what is still shown over it (a sheet, a password panel) first.
    static func close(_ window: NSWindow) {
        while let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.close()
    }

    func requestCloseWindow() {
        guard let window else { return }
        // Already asking (a second click, ⇧⌘W again): one question at a time.
        guard window.attachedSheet == nil else { NSSound.beep(); return }
        let store = model.workspaces
        let tabs = workspace.tabs
        guard !tabs.isEmpty, let other = store.otherOpenWorkspaces(than: workspaceID).first,
              model.settings.confirmCloseOnlineSessions else {
            window.close()
            return
        }
        let alert = NSAlert()
        alert.messageText = tabs.count == 1 ? "Close this window and its tab?" : "Close this window and its \(tabs.count) tabs?"
        alert.informativeText = "In the background they keep running and stay connected; they are listed in the sidebar, "
            + "ready to reopen. Or move them to the other window."
        alert.addButton(withTitle: "Keep in Background")
        alert.addButton(withTitle: "Move Tabs to Other Window")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            // Closed once the sheet is gone: closing the window from inside the sheet's own ending
            // could leave the window half closed — on screen, drawing nothing, not answering.
            switch response {
            case .alertFirstButtonReturn:
                DispatchQueue.main.async { Self.close(window) }   // its sessions go to the background (WorkspaceStore.windowClosed)
            case .alertSecondButtonReturn:
                let selected = self.workspace.selected
                for id in tabs { store.add(id, to: other, select: id == selected) }
                DispatchQueue.main.async {
                    Self.close(window)
                    store.activate(other)
                }
            default:
                break
            }
        }
    }
}

/// Sends a window's close button to `WindowState.requestCloseWindow` (SwiftUI owns the window's
/// delegate, so the button is redirected instead).
@MainActor
final class WindowCloseGuard: NSObject {
    private weak var state: WindowState?
    private static var key = 0

    static func install(on window: NSWindow, state: WindowState) {
        guard let button = window.standardWindowButton(.closeButton) else { return }
        let guardian = WindowCloseGuard()
        guardian.state = state
        objc_setAssociatedObject(window, &key, guardian, .OBJC_ASSOCIATION_RETAIN)
        button.target = guardian
        button.action = #selector(closeClicked(_:))
    }

    @objc private func closeClicked(_ sender: Any?) {
        state?.requestCloseWindow()
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

extension WindowState {
    /// ⌘T and the tab bar's "+": another tab like the one in front — a terminal to the same host,
    /// or in a file manager another file manager there (like a Finder window). Without either,
    /// the host shown in the panel, else Quick Connect.
    func newTabLikeCurrent() {
        if case .files(let f)? = selectedItem {
            let dir = model.fileTabs.browser(for: f).directory
            openFiles(f.target, path: dir.isEmpty ? f.path : dir)
        } else if let session {
            newSession(like: session)
        } else if let t = inspectedTarget {
            connect(t, mode: .tab)
        } else {
            showQuickConnect = true
        }
    }

    /// What `newTabLikeCurrent` opens, for its button's tooltip.
    var newTabHelp: String {
        if case .files(let f)? = selectedItem { return "New file manager tab on \(f.target.displayName) (⌘T)" }
        if let session { return "New tab to \(session.descriptor.target.displayName) (⌘T)" }
        if let t = inspectedTarget { return "New tab to \(t.displayName) (⌘T)" }
        return "New connection (⌘T)"
    }
}
