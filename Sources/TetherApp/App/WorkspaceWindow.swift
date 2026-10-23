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
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @SceneStorage("showInspector") private var showInspector = true
    @State private var renameText = ""

    init(workspaceID: UUID) {
        self.workspaceID = workspaceID
        _state = State(initialValue: WindowState(workspaceID: workspaceID))
    }

    var body: some View {
        @Bindable var state = state
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                // Content never dictates the column's minimum size (see the detail column below).
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        } detail: {
            VStack(spacing: 0) {
                TabStrip()
                Divider()
                WorkspaceView()
            }
            // A fixed minimum keeps the split view from re-measuring whenever the content changes
            // (terminal ↔ welcome screen), which otherwise can loop in AppKit's constraint pass.
            .frame(minWidth: 320, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
            .inspector(isPresented: $showInspector) {
                InspectorContainer()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .inspectorColumnWidth(min: 340, ideal: 420, max: 640)
            }
        }
        .toolbar { WorkspaceToolbar(showInspector: $showInspector) }
        .navigationTitle(windowTitle)
        .navigationSubtitle(state.selectedItem?.target.displayName ?? "")
        .focusedSceneValue(\.windowState, state)
        .focusedSceneValue(\.activeSessionID, state.session?.id)
        .background(WindowAccessor { window in
            window.tabbingMode = .disallowed
            state.window = window
            model.workspaces.register(window, for: workspaceID, state: state)
        })
        .sheet(isPresented: $state.showQuickConnect) { QuickConnectView() }
        .sheet(item: $state.hostEditor) { HostEditorView(request: $0) }
        .sheet(item: $state.keySetupTarget) { KeySetupView(request: $0) }
        .sheet(isPresented: $state.showConfigEditor) { ConfigFileEditorView() }
        .sheet(isPresented: $state.showSwitcher) { SessionSwitcherView() }
        .sheet(item: $state.uploadRequest) { UploadSheet(request: $0) }
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
            model.adoptOrphanSessions(into: state)
            #if DEBUG
            SelfTest.runIfRequested(state: state)
            #endif
        }
        .onDisappear {
            // Closing a window keeps its sessions running in the background.
            if !model.isTerminating { model.workspaces.windowClosed(workspaceID) }
        }
        .onChange(of: state.session?.id) { _, id in
            if model.sessions.selectedID != id { model.sessions.selectedID = id }
        }
        .onChange(of: model.settings) { _, _ in model.settingsChanged() }
        .onChange(of: state.toggleInspector) { withAnimation(.smooth) { showInspector.toggle() } }
        .onChange(of: state.showInspectorRequest) { _, show in
            if show { withAnimation(.smooth) { showInspector = true }; state.showInspectorRequest = false }
        }
        // Outermost, so the toolbar, sheets and alerts see this window's state too.
        .environment(state)
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
                Label("New Connection", systemImage: "plus")
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
                Label("Transfers", systemImage: "arrow.up.arrow.down.circle")
                    .symbolEffect(.pulse, isActive: model.transfers.activeCount > 0)
            }
            .badge(model.transfers.activeCount)
            .help("File transfers (⌥⌘L)")
            .popover(isPresented: Bindable(state).showTransfers, arrowEdge: .bottom) {
                TransfersView().frame(width: 380, height: 360)
            }

            Button {
                guard let session = state.session else { return }
                state.openFiles(session.descriptor.target, path: session.currentDirectory)
            } label: {
                Label("Browse Files Here", systemImage: "folder")
            }
            .disabled(state.session == nil)
            .help("Open a file manager tab in the terminal's current directory (⇧⌘O)")

            Button {
                withAnimation(.smooth) { showInspector.toggle() }
            } label: {
                Label("Host Panel", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the host panel (⌥⌘I)")
        }
    }
}
