import SwiftUI
import TetherCore
import SessionKit
import TerminalUI

/// A window: sidebar, Tether's tab bar with the selected terminal (or the welcome screen),
/// and the host panel. Switching tabs only swaps the terminal; the rest stays in place.
struct WorkspaceWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let workspaceID: UUID
    @State private var state: WindowState
    @State private var columnVisibility: NavigationSplitViewVisibility
    /// Each window keeps its own sidebar and host panel (shown or not, widths, the panel's tab),
    /// saved with its layout and brought back after relaunching (`WindowLayout.Panels`; a scene's
    /// own storage is not kept for windows Tether reopens). A new window opens with them as they
    /// were last left in any window (these defaults).
    @AppStorage("showSidebar") private var lastShowSidebar = true
    @AppStorage("showInspector") private var lastShowInspector = true
    @AppStorage("inspectorWidth") private var lastInspectorWidth = 420.0
    @AppStorage("sidebarWidth") private var lastSidebarWidth = 260.0
    @State private var showInspector: Bool
    @State private var inspectorWidth: Double
    /// Kept while the sidebar is hidden (shown again, it comes back at this width).
    @State private var sidebarWidth: Double?
    /// The sidebar's width when the window opened (set on the split view once it is laid out).
    private let sidebarStartWidth: Double
    @State private var detailWidth: CGFloat = 1200

    /// Shown when wanted and when the terminal still gets at least 380 points beside it.
    private var inspectorVisible: Bool {
        showInspector && detailWidth >= inspectorWidth + 380
    }
    @State private var renameText = ""
    /// The first-launch setup opens with the first window only.
    @MainActor private static var setupShown = false

    init(workspaceID: UUID) {
        self.workspaceID = workspaceID
        let defaults = AppPaths.defaults
        let saved = WindowLayout.savedPanels(for: workspaceID)
        let state = WindowState(workspaceID: workspaceID)
        if let tab = saved?.inspectorTab.flatMap(InspectorTab.init(rawValue:)) { state.inspectorTab = tab }
        _state = State(initialValue: state)
        let sidebar = saved?.sidebar ?? defaults.object(forKey: "showSidebar") as? Bool ?? true
        _columnVisibility = State(initialValue: sidebar ? .all : .detailOnly)
        _showInspector = State(initialValue: saved?.inspector ?? defaults.object(forKey: "showInspector") as? Bool ?? true)
        _inspectorWidth = State(initialValue: min(max(saved?.inspectorWidth ?? defaults.object(forKey: "inspectorWidth") as? Double ?? 420, 340), 640))
        let width = saved?.sidebarWidth ?? defaults.object(forKey: "sidebarWidth") as? Double ?? 260
        sidebarStartWidth = min(max(width, 220), 380)
        _sidebarWidth = State(initialValue: sidebarStartWidth)
    }

    private var panels: WindowLayout.Panels {
        WindowLayout.Panels(sidebar: columnVisibility != .detailOnly, sidebarWidth: sidebarWidth, inspector: showInspector,
                            inspectorWidth: inspectorWidth, inspectorTab: state.inspectorTab.rawValue)
    }

    var body: some View {
        @Bindable var state = state
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                // Content never dictates the column's minimum size (see the detail column below).
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .onGeometryChange(for: Double.self) { $0.size.width.rounded() } action: { w in
                    // Only while shown (a hidden column measures nothing useful).
                    if w >= 220, columnVisibility != .detailOnly { sidebarWidth = w }
                }
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            // The host panel is drawn here rather than as a split-view inspector column: AppKit's
            // three-column split view loops forever (and crashes) when the window is narrower than
            // the columns' ideal widths. Here nothing has a minimum width that can conflict, and
            // the panel simply steps aside while the window is too narrow for it.
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    TabStrip()
                    Divider()
                    WorkspaceView()
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                if inspectorVisible {
                    PanelDivider(width: $inspectorWidth, range: 340...640)
                    InspectorContainer()
                        .frame(width: inspectorWidth)
                        .frame(maxHeight: .infinity)
                        .background(.background)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .clipped()
            .frame(minWidth: 320, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { detailWidth = $0 }
        }
        .toolbar { WorkspaceToolbar(showInspector: $showInspector) }
        // In a small view of its own: a program animating its title (Claude Code's spinner) then
        // redraws only the title, not the whole window several times a second.
        .background(WindowTitles(state: state, workspaceID: workspaceID))
        .focusedSceneValue(\.windowState, state)
        .focusedSceneValue(\.activeSessionID, state.session?.id)
        .background(WindowAccessor { window in
            window.tabbingMode = .disallowed
            state.window = window
            WindowCloseGuard.install(on: window, state: state)
            model.workspaces.register(window, for: workspaceID, state: state)
            WindowLayout.apply(to: window, workspace: workspaceID)
            WindowLayout.watch(window, workspace: workspaceID)
            WindowLayout.applySidebarWidth(sidebarStartWidth, in: window)
        })
        .sheet(isPresented: $state.showQuickConnect) { QuickConnectView().appLockCover() }
        .sheet(item: $state.hostEditor) { HostEditorView(request: $0).appLockCover() }
        .sheet(item: $state.keySetupTarget) { KeySetupView(request: $0).appLockCover() }
        .sheet(isPresented: $state.showConfigEditor) { ConfigFileEditorView().appLockCover() }
        .sheet(isPresented: $state.showSwitcher) { SessionSwitcherView().appLockCover() }
        .sheet(item: $state.uploadRequest) { UploadSheet(request: $0).appLockCover() }
        .sheet(item: $state.passwordEntry) { PasswordEntrySheet(session: $0).appLockCover() }
        .alert("Rename", isPresented: Binding(get: { state.renamingSession != nil },
                                              set: { if !$0 { state.renamingSession = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let s = state.renamingSession { model.sessions.rename(s.id, to: renameText) } }
            Button("Use Automatic Name") { if let s = state.renamingSession { model.sessions.rename(s.id, to: "") } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Leave empty to name it after the running command.")
        }
        .onChange(of: state.renamingSession?.id) { _, _ in
            renameText = state.renamingSession.map { $0.descriptor.customTitle ? $0.descriptor.title : "" } ?? ""
        }
        .onAppear {
            model.workspaces.openWindow = { id in openWindow(id: "workspace", value: id) }
            model.openSearch = { openWindow(id: "search") }
            WindowLayout.openRemaining { id in openWindow(id: "workspace", value: id) }
            model.adoptOrphanSessions(into: state)
            MenuBarState.windowOpened()
            if model.settingsStore.wantsFirstLaunchSetup, !Self.setupShown {
                Self.setupShown = true
                DispatchQueue.main.async { openWindow(id: "setup") }
            }
            #if DEBUG
            SelfTest.runIfRequested(state: state)
            DemoMode.runIfRequested(state: state)
            #endif
        }
        .onDisappear {
            // Closing a window keeps its sessions running in the background.
            if !model.isTerminating { model.workspaces.windowClosed(workspaceID) }
        }
        .onChange(of: state.session?.id, initial: true) { _, id in
            if model.sessions.selectedID != id { model.sessions.selectedID = id }
            if let session = state.session { model.sessionShown(session) } else { model.refreshPromptPanel() }
        }
        .onChange(of: model.settings) { _, _ in model.settingsChanged() }
        .onChange(of: columnVisibility) { _, visibility in lastShowSidebar = visibility != .detailOnly }
        .onChange(of: showInspector) { _, shown in lastShowInspector = shown }
        .onChange(of: inspectorWidth) { _, w in lastInspectorWidth = w }
        .onChange(of: sidebarWidth) { _, w in if let w { lastSidebarWidth = w } }
        .onChange(of: panels, initial: true) { _, p in WindowLayout.update(p, for: workspaceID) }
        .onChange(of: state.toggleInspector) {
            withAnimation(.smooth) {
                // Wanted but stepped aside for lack of room: make room by hiding the sidebar.
                if showInspector && !inspectorVisible && columnVisibility != .detailOnly {
                    columnVisibility = .detailOnly
                } else {
                    showInspector.toggle()
                }
            }
        }
        .onChange(of: state.showInspectorRequest) { _, show in
            if show { withAnimation(.smooth) { showInspector = true }; state.showInspectorRequest = false }
        }
        // Outermost, so the toolbar, sheets and alerts see this window's state too.
        .environment(state)
    }
}

/// The window's title (the shown tab) and subtitle (its host, and "Window 2" with several windows).
private struct WindowTitles: View {
    @Environment(AppModel.self) private var model
    let state: WindowState
    let workspaceID: UUID

    var body: some View {
        Color.clear
            .navigationTitle(windowTitle)
            .navigationSubtitle(windowSubtitle)
    }

    /// The host, and "Window 2" while several windows are open (the sidebar names them so).
    private var windowSubtitle: String {
        let host = state.selectedItem?.target.displayName ?? ""
        guard model.workspaces.hasSeveralWindows, let n = model.workspaces.numbers[workspaceID] else { return host }
        return host.isEmpty ? "Window \(n)" : "\(host) · Window \(n)"
    }

    private var windowTitle: String {
        switch state.selectedItem {
        case .terminal(let s)?: s.displayTitle
        case .files(let f)?: model.fileTabs.title(of: f)
        case nil: "Tether"
        }
    }
}

struct WorkspaceToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    @Binding var showInspector: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                state.showQuickConnect = true
            } label: {
                Label("New Connection", systemImage: "bolt.horizontal")
            }
            .help("New connection (⌘N)")

            Button {
                model.openSearch?()
            } label: {
                Label("Search", systemImage: "text.magnifyingglass")
            }
            .help("Search all sessions and the archive (⇧⌘F)")

            Button {
                state.showTransfers.toggle()
            } label: {
                // Still: a looping symbol effect in the toolbar redraws the window on every frame
                // for as long as a transfer runs (the badge says how many run).
                Label("Transfers", systemImage: model.transfers.activeCount > 0 ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
            }
            .badge(model.transfers.activeCount)
            .help("File transfers (⌥⌘L)")
            .popover(isPresented: Bindable(state).showTransfers, arrowEdge: .bottom) {
                TransfersView()
            }

            Button {
                guard let session = state.session else { return }
                state.browse(session.descriptor.target, path: session.currentDirectory)
            } label: {
                Label("Browse Files Here", systemImage: "folder")
            }
            .disabled(state.session == nil)
            .help("Open a file manager tab in the terminal's current directory (⌘E)")

            // Only with App Lock on: lock Tether now (sessions keep running). Left of the panel toggle,
            // which stays last, above the panel it opens.
            if model.settings.appLockMode != .off {
                Button {
                    AppLock.shared.lock()
                } label: {
                    Label("Lock", systemImage: "lock")
                }
                .help("Lock Tether (⌃⌘L) — sessions keep running")
            }

            Button {
                state.toggleInspector.toggle()
            } label: {
                Label("Host Panel", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the host panel (⌥⌘I)")
        }
    }
}
