import SwiftUI
import TetherCore
import SSHConfigKit
import SessionKit
import MonitorKit

/// How sidebar rows are drawn (Settings ▸ Appearance ▸ Sidebar).
struct SidebarLook {
    var style: SidebarStyle = .detailed
    var showDetails = true
    var showButtons = true
    var showCounts = true
    var scale: CGFloat = 1

    init() {}

    init(_ s: AppSettings, scale: CGFloat) {
        style = s.sidebarStyle
        showDetails = s.sidebarShowDetails
        showButtons = s.sidebarShowRowButtons
        showCounts = s.sidebarShowCounts
        self.scale = scale
    }

    var details: Bool { style.canShowDetails && showDetails }
    var buttons: Bool { style.canShowRowButtons && showButtons }
    var counts: Bool { style.canShowCounts && showCounts }
    /// Labels such as "background" and "Suspended", and the agent line under a session.
    var extras: Bool { style == .detailed || style == .flat }
    /// Rows under a host are indented by hand, except in the folder tree (which indents itself).
    var childIndent: CGFloat { style == .folders ? 0 : 22 * scale }
    /// "Local" and "Hosts" headers: Detailed and Compact keep their sections; Minimal shows only
    /// group names, and Flat is one list (headers that say "Hosts" over hosts add only noise there).
    var plainSectionHeaders: Bool { style == .detailed || style == .compact }
    var iconWidth: CGFloat { 18 * scale }
}

private struct SidebarLookKey: EnvironmentKey {
    static let defaultValue = SidebarLook()
}

extension EnvironmentValues {
    var sidebarLook: SidebarLook {
        get { self[SidebarLookKey.self] }
        set { self[SidebarLookKey.self] = newValue }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.uiScale) private var scale
    @Environment(WindowState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var newGroupName = ""
    @State private var showNewGroup = false
    @State private var renamingGroup: HostGroup?

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            list
            Divider()
            // Below the list (not laid over it), so rows never slide under the buttons.
            SidebarBottomBar(showNewGroup: $showNewGroup)
                .background(.bar)
        }
    }

    @ViewBuilder
    private var list: some View {
        ScrollViewReader { proxy in
            sidebarList
                // The tab selected at the top is also selected here, under its host, and scrolled into view.
                .onChange(of: state.workspace.selected, initial: true) { _, id in reveal(id, proxy: proxy) }
        }
    }

    /// A tab shown in another window was clicked: that window comes forward, and this sidebar keeps
    /// pointing at this window's own tab instead of a row that is not here.
    private func keepOwnSelection(_ clicked: UUID) {
        guard let ws = model.workspaces.workspace(containing: clicked), ws != state.workspaceID else { return }
        DispatchQueue.main.async {
            switch state.selectedItem {
            case .terminal(let s)?: state.sidebarSelection = .session(s.id)
            case .files(let f)?: state.sidebarSelection = .files(f.id)
            case nil: state.sidebarSelection = nil
            }
        }
    }

    /// Selects a tab's row in the sidebar, unfolding whatever hides it (its group, its host, "Show more").
    private func reveal(_ id: UUID?, proxy: ScrollViewProxy) {
        guard let id, let item = state.item(id) else {
            // The tab is gone: drop a selection that pointed at it.
            switch state.sidebarSelection {
            case .session(let s)? where model.sessions.session(s) == nil: state.sidebarSelection = nil
            case .files(let f)? where model.fileTabs.tab(f) == nil: state.sidebarSelection = nil
            default: break
            }
            return
        }
        let row: SidebarItem
        let key = item.target.key
        switch item {
        case .terminal(let s):
            row = .session(s.id)
            let live = HostChildren.ordered(model.sessions.sessions(for: key), by: model.settings.sessionSortOrder)
            let folding = SidebarFolding.shared
            if (live.firstIndex { $0.id == s.id } ?? 0) >= HostChildren.limit, !folding.expanded.contains(key) {
                folding.expanded.insert(key)
            }
        case .files(let f):
            row = .files(f.id)
        }
        let folding = SidebarFolding.shared
        for k in [key] + SidebarFolding.folderKeys where folding.collapsed.contains(k) { folding.collapsed.remove(k) }
        if case .alias(let alias) = item.target, let group = model.metadata(for: alias).groupID,
           model.groups.first(where: { $0.id == group })?.isExpanded == false {
            model.updateGroup(group) { $0.isExpanded = true }
        }
        if state.sidebarSelection != row { state.sidebarSelection = row }
        // After the unfolded rows exist; scrolls only as far as needed.
        DispatchQueue.main.async { withAnimation(.snappy) { proxy.scrollTo(row) } }
    }

    @ViewBuilder
    private var sidebarList: some View {
        @Bindable var state = state
        List(selection: $state.sidebarSelection) {
            switch model.settings.sidebarStyle {
            case .folders:
                SidebarFolderTree(search: search, adhocKeys: adhocKeys, onRename: rename)
            case .flat:
                LocalSection()
                flatSection
                quickConnectionsSection
                ArchiveSection()
            case .detailed, .compact, .minimal:
                LocalSection()
                favoritesSection
                ForEach(model.groups) { group in
                    GroupSection(group: group, search: search, onRename: { rename(group) })
                }
                ungroupedSection
                quickConnectionsSection
                ArchiveSection()
            }
        }
        .listStyle(.sidebar)
        .environment(\.sidebarLook, SidebarLook(model.settings, scale: scale))
        // Another style is another list: rebuilt, not diffed row by row (sections and folders do
        // not map onto each other, and reused rows could keep the old style's text).
        .id(model.settings.sidebarStyle)
        // Menus and double-click are handled by the list itself, so a single click selects at once
        // (a per-row double-click gesture makes every single click wait).
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            if let item = items.first { SidebarItemMenu(item: item) }
        } primaryAction: { items in
            guard let item = items.first else { return }
            switch item {
            case .host(let key): state.connect(model.target(forKey: key))
            case .session(let id): if let s = model.sessions.session(id) { state.renamingSession = s }
            case .files(let id): if let t = model.fileTabs.tab(id) { state.show(t) }
            case .archived(let id): openWindow(id: "transcript", value: TranscriptRequest(archiveID: id))
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Hosts and sessions")

        .onChange(of: state.sidebarSelection) { _, item in
            switch item {
            case .session(let id):
                if id != state.workspace.selected, let s = model.sessions.session(id) { state.show(s); keepOwnSelection(id) }
            case .files(let id):
                if id != state.workspace.selected, let t = model.fileTabs.tab(id) { state.show(t); keepOwnSelection(id) }
            case .host:
                // Clicking a host shows its details in the host panel — if it is open. A panel the
                // user closed stays closed (View ▸ Show or Hide Host Panel opens it again).
                state.inspectorTab = .overview
            default: break
            }
        }
        .alert("New Group", isPresented: $showNewGroup) {
            TextField("Name", text: $newGroupName)
            Button("Create") {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.addGroup(named: name) }
                newGroupName = ""
            }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        }
        .alert("Rename Group", isPresented: Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
            TextField("Name", text: $newGroupName)
            Button("Rename") {
                if let g = renamingGroup { model.updateGroup(g.id) { $0.name = newGroupName } }
                newGroupName = ""
            }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        }
    }

    private func rename(_ group: HostGroup) {
        newGroupName = group.name
        renamingGroup = group
    }

    /// Flat: every host in one list without headers — favorites first, then by name (a group shows
    /// as the row's colour dot, a favorite as a star).
    private var flatSection: some View {
        Section {
            let favorite = { (h: SSHHostEntry) in
                model.settings.sidebarShowFavorites && (h.alias.map { model.metadata(for: $0).favorite } ?? false)
            }
            let hosts = filtered(model.hosts).sorted {
                let (a, b) = (favorite($0), favorite($1))
                if a != b { return a }
                return ($0.alias ?? "").localizedStandardCompare($1.alias ?? "") == .orderedAscending
            }
            ForEach(hosts, id: \.id) { HostRows(host: $0, search: search) }
            if model.hosts.isEmpty { addFirstHost }
        }
    }

    private var addFirstHost: some View {
        Button {
            state.hostEditor = HostEditorRequest()
        } label: {
            Label("Add your first host", systemImage: "plus.circle")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
    }

    @ViewBuilder
    private var favoritesSection: some View {
        let favorites = model.ordered(model.hosts.filter { $0.alias.map { model.metadata(for: $0).favorite } ?? false })
        if !favorites.isEmpty && search.isEmpty && model.settings.sidebarShowFavorites {
            Section("Favorites") {
                ForEach(favorites, id: \.id) { HostRows(host: $0, search: search) }
            }
        }
    }

    @ViewBuilder
    private var ungroupedSection: some View {
        let look = SidebarLook(model.settings, scale: scale)
        if look.plainSectionHeaders || !model.groups.isEmpty {
            ungroupedHosts
        } else {
            Section { ungroupedRows }
        }
    }

    @ViewBuilder
    private var ungroupedRows: some View {
        ForEach(filtered(model.hosts(in: nil)), id: \.id) { HostRows(host: $0, search: search) }
            .onMove { from, to in model.moveHosts(in: nil, from: from, to: to) }
        if model.hosts.isEmpty { addFirstHost }
    }

    private var ungroupedHosts: some View {
        Section {
            ungroupedRows
        } header: {
            Text(model.groups.isEmpty ? "Hosts" : "Other Hosts")
                .dropDestination(for: String.self) { items, _ in
                    items.forEach { model.moveHost($0, toGroup: nil) }
                    return !items.isEmpty
                }
        }
    }

    @ViewBuilder
    private var quickConnectionsSection: some View {
        let keys = adhocKeys
        if !keys.isEmpty {
            Section("Quick Connections") {
                ForEach(keys, id: \.self) { key in
                    Label(key, systemImage: "bolt.horizontal")
                        .tag(SidebarItem.host(key))
                    HostChildren(key: key, target: model.target(forKey: key))
                }
            }
        }
    }

    var adhocKeys: [String] {
        var seen = Set<String>()
        return model.sessions.sessions.compactMap { s -> String? in
            guard case .adhoc = s.descriptor.target else { return nil }
            let k = s.descriptor.target.key
            return seen.insert(k).inserted ? k : nil
        }
    }

    private func filtered(_ hosts: [SSHHostEntry]) -> [SSHHostEntry] {
        hosts.filter { hostMatches($0, search: search, model: model) }
    }
}

/// A user group with its hosts. Hosts can be reordered by dragging and dropped onto the header.
private struct GroupSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sidebarLook) private var look
    let group: HostGroup
    let search: String
    let onRename: () -> Void

    var body: some View {
        Section(isExpanded: Binding(get: { group.isExpanded || !search.isEmpty },
                                    set: { v in model.updateGroup(group.id) { $0.isExpanded = v } })) {
            ForEach(hosts, id: \.id) { HostRows(host: $0, search: search) }
                .onMove { from, to in model.moveHosts(in: group.id, from: from, to: to) }
        } header: {
            HStack(spacing: 6) {
                if let c = group.color.color { Circle().fill(c).frame(width: 7, height: 7) }
                Text(group.name)
                if look.counts {
                    Text("\(model.hosts(in: group.id).count)").monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            .dropDestination(for: String.self) { items, _ in
                items.forEach { model.moveHost($0, toGroup: group.id) }
                return !items.isEmpty
            }
            .contextMenu { GroupMenu(group: group, onRename: onRename) }
        }
    }

    private var hosts: [SSHHostEntry] {
        model.hosts(in: group.id).filter { hostMatches($0, search: search, model: model) }
    }
}

/// A group's menu: on its section header, or its folder in the folder tree.
struct GroupMenu: View {
    @Environment(AppModel.self) private var model
    let group: HostGroup
    let onRename: () -> Void

    var body: some View {
        Button("Rename…", action: onRename)
        Menu("Color") {
            ForEach(TagColor.allCases) { c in
                Button(c.title) { model.updateGroup(group.id) { $0.color = c } }
            }
        }
        Button("Move Up") { model.moveGroup(group.id, by: -1) }
        Button("Move Down") { model.moveGroup(group.id, by: 1) }
        Divider()
        Button("Delete Group", role: .destructive) { model.deleteGroup(group.id) }
    }
}

/// A host row followed by its open sessions (in the folder tree: a host that opens to them).
struct HostRows: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let host: SSHHostEntry
    var search = ""

    /// While searching by a session name, only the matching sessions of a host are listed.
    private func visibleSessions(_ alias: String) -> [TerminalSession] {
        let all = model.sessions.sessions(for: alias)
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty,
              ![host.alias, host.hostName, host.user].compactMap({ $0 }).contains(where: { $0.localizedCaseInsensitiveContains(q) })
        else { return all }
        return all.filter { sessionMatches($0, q) }
    }

    @Environment(\.sidebarLook) private var look

    var body: some View {
        if let alias = host.alias {
            let children = HostChildren(key: alias, target: .alias(alias), sessions: visibleSessions(alias), searching: !search.isEmpty)
            if look.style == .folders {
                HostNode(key: alias, target: .alias(alias), searching: !search.isEmpty) {
                    HostRow(host: host).tag(SidebarItem.host(alias)).draggable(alias)
                } children: { children }
            } else {
                HostRow(host: host)
                    .tag(SidebarItem.host(alias))
                    .draggable(alias)
                children
            }
        }
    }
}

/// Everything listed under a host: its sessions (active first; ended ones disappear — they are in
/// the archive), its file manager tabs, and tmux/screen sessions found on the server. Long lists
/// are cut to a few rows with "Show all", and a host can be folded away entirely.
struct HostChildren: View {
    @Environment(AppModel.self) private var model
    let key: String
    let target: ConnectionTarget
    var sessions: [TerminalSession]? = nil
    var searching = false

    static let limit = 8
    static let serverLimit = 3

    private static func rank(_ s: TerminalSession) -> Int {
        switch s.phase {
        case .online: 0
        case .connecting, .waiting: 1
        case .suspended: 2
        case .dead: 3
        }
    }

    /// The host's live sessions in the order chosen in Settings (Sidebar ▸ Sort sessions).
    static func ordered(_ sessions: [TerminalSession], by order: SessionSortOrder) -> [TerminalSession] {
        let live = Array(sessions.filter { !$0.phase.isDead }.enumerated())
        let sorted: [(offset: Int, element: TerminalSession)]
        switch order {
        case .status:
            sorted = live.sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
        case .name:
            sorted = live.sorted {
                let c = $0.element.displayTitle.localizedStandardCompare($1.element.displayTitle)
                return c == .orderedSame ? $0.offset < $1.offset : c == .orderedAscending
            }
        case .newest:
            sorted = live.sorted { ($0.element.startedAt, $0.offset) > ($1.element.startedAt, $1.offset) }
        case .oldest:
            sorted = live.sorted { ($0.element.startedAt, $0.offset) < ($1.element.startedAt, $1.offset) }
        case .manual:
            sorted = live
        }
        return sorted.map(\.element)
    }

    var body: some View {
        let folding = SidebarFolding.shared
        if searching || !folding.collapsed.contains(key) {
            let expanded = searching || folding.expanded.contains(key)
            let order = model.settings.sessionSortOrder
            let list = Self.ordered(sessions ?? model.sessions.sessions(for: key), by: order)
            let shown = expanded ? list : Array(list.prefix(Self.limit))
            ForEach(shown) { SessionRow(session: $0) }
                // Manual order: drag sessions within their host (not while a search filters the list).
                .onMove(perform: order == .manual && !searching ? { from, to in
                    var ids = shown.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    model.sessions.reorder(ids + list.dropFirst(shown.count).map(\.id))
                } : nil)
            ForEach(model.fileTabs.tabs(for: key)) { FileTabRow(tab: $0) }
            let all = serverSessions
            // Tether sessions left on the server (after a crash, or a tab that never connected)
            // are summed up in one row with a clean-up button instead of a row each.
            let leftovers = all.filter { $0.isTether && !$0.attached }
            let server = all.filter { !($0.isTether && !$0.attached) }
            let shownServer = expanded ? server : Array(server.prefix(Self.serverLimit))
            ForEach(shownServer) { entry in
                ServerSessionRow(entry: entry, target: target, monitor: model.monitor(for: target))
            }
            if !leftovers.isEmpty {
                LeftoverSessionsRow(count: leftovers.count, target: target)
                if expanded {
                    ForEach(leftovers) { entry in
                        ServerSessionRow(entry: entry, target: target, monitor: model.monitor(for: target))
                    }
                }
            }
            let hidden = (list.count - shown.count) + (server.count - shownServer.count)
            if hidden > 0 {
                FoldRow(title: "Show \(hidden) more") { folding.expanded.insert(key) }
            } else if expanded && !searching && (list.count > Self.limit || server.count > Self.serverLimit) {
                FoldRow(title: "Show fewer") { folding.expanded.remove(key) }
            }
        }
    }

    /// tmux/screen sessions on the server that are not open in Tether (including the user's own).
    private var serverSessions: [RemoteSessionEntry] {
        guard !target.isLocal else { return [] }
        let open = Set(model.sessions.sessions(for: target.key).map(\.descriptor.remoteSessionName))
        return model.monitor(for: target).remoteSessions.filter { !open.contains($0.name) }
    }
}

/// "3 leftover sessions on the server" with a button that ends them.
private struct LeftoverSessionsRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sidebarLook) private var look
    let count: Int
    let target: ConnectionTarget
    @State private var cleaning = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full").uiFont(size: 10).foregroundStyle(.secondary)
                .frame(width: 16 * look.scale, height: 16 * look.scale)
            Text("\(count) leftover session\(count == 1 ? "" : "s") on the server")
                .uiFont(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            if cleaning {
                Image(systemName: "hourglass").uiFont(.caption).foregroundStyle(.secondary)
            } else {
                Button("Clean Up") {
                    cleaning = true
                    let open = Set(model.sessions.sessions(for: target.key).map(\.descriptor.remoteSessionName))
                    Task {
                        _ = await model.monitor(for: target).cleanUpOrphans(keeping: open)
                        cleaning = false
                    }
                }
                .buttonStyle(.borderless)
                .uiFont(.caption)
                .help("End the Tether sessions on this server that are not open in any tab (your own tmux sessions are not touched)")
            }
        }
        .padding(.leading, look.childIndent + 4)
    }
}

/// "Show 42 more" / "Show fewer" under a host.
private struct FoldRow: View {
    @Environment(\.sidebarLook) private var look
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: { withAnimation(.snappy) { action() } }) {
            Text(title)
                .uiFont(.caption)
                .foregroundStyle(.tint)
                .padding(.leading, look.childIndent + 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Which hosts are folded in the sidebar (remembered) or fully expanded (this run).
@MainActor
@Observable
final class SidebarFolding {
    static let shared = SidebarFolding()
    var collapsed: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "sidebar.collapsedHosts") ?? []) {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "sidebar.collapsedHosts") }
    }
    var expanded: Set<String> = []

    /// Folders of the folder tree that are not groups (their state is kept with the hosts').
    static let favoritesFolder = "folder:favorites"
    static let otherHostsFolder = "folder:other"
    static let quickFolder = "folder:quick"
    static let archiveFolder = "folder:archive"
    static let folderKeys = [otherHostsFolder, quickFolder]

    func toggle(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }
}

/// One server-side session: click it (or Attach) to open it in a tab.
private struct ServerSessionRow: View {
    @Environment(WindowState.self) private var state
    @Environment(\.sidebarLook) private var look
    let entry: RemoteSessionEntry
    let target: ConnectionTarget
    let monitor: RemoteMonitor
    @State private var attaching = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack")
                .uiFont(size: 10)
                .foregroundStyle(entry.attached ? .green : .secondary)
                .frame(width: 16 * look.scale, height: 16 * look.scale)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.isTether ? "Detached session" : entry.name)
                        .lineLimit(1)
                    Text(entry.kind.rawValue)
                        .uiFont(.caption2)
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(.quaternary))
                        .foregroundStyle(.secondary)
                }
                if let pane = entry.activePane, look.extras {
                    PaneSummary(pane: pane)
                }
            }
            Spacer(minLength: 4)
            if attaching {
                ProgressView().controlSize(.mini)
            } else if look.buttons {
                RowAction(symbol: "arrow.right.circle", help: "Attach in a new tab", action: attach)
                RowAction(symbol: "xmark.circle", help: "Kill this session on the server") {
                    Task { await monitor.killRemoteSession(entry) }
                }
            }
        }
        .padding(.leading, look.childIndent)
        .contentShape(Rectangle())
        .onTapGesture(perform: attach)
        .help(helpText)
        .contextMenu {
            Button("Attach in New Tab", action: attach)
            Divider()
            Button("Kill on Server", role: .destructive) { Task { await monitor.killRemoteSession(entry) } }
        }
    }

    private var helpText: String {
        var text = "\(entry.kind.rawValue) session “\(entry.name)” on the server\(entry.attached ? " (attached elsewhere)" : "") — click to open it in a tab"
        let windows = entry.panes.filter(\.paneActive)
        if !windows.isEmpty {
            text += "\n" + windows.map { "\($0.windowIndex): \($0.windowName) — \($0.summary)" }.joined(separator: "\n")
        }
        return text
    }

    private func attach() {
        guard !attaching else { return }
        attaching = true
        state.connect(target, remoteSessionName: entry.name, persistence: entry.kind == .tmux ? .tmux : .screen)
        // The row disappears once the session is open; reset in case attaching fails.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { attaching = false }
    }
}

/// What runs in a server session's pane: the coding agent and its session name, or the command, and
/// the folder.
struct PaneSummary: View {
    let pane: RemoteSessionPane
    var showPath = true
    /// The tab's title already names the agent session: only whether it is working is shown.
    var stateOnly = false

    var body: some View {
        HStack(spacing: 3) {
            if let agent = pane.agent {
                Image(systemName: agent.isWorking ? "sparkles" : "sparkle")
                    .uiFont(.caption2)
                    .foregroundStyle(agent.isWorking ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .help(agent.isWorking ? "\(agent.kind.title) is working" : agent.kind.title)
            }
            Text(stateOnly ? (pane.agent?.isWorking == true ? "working" : "waiting") : showPath ? pane.summary : pane.displayCommand)
                .uiFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

extension View {
    /// A middle click on this sidebar row closes it, as its close button would (`TabBarCenter`).
    func middleClickCloses(_ item: SidebarItem) -> some View { modifier(SidebarMiddleClick(item: item)) }
}

private struct SidebarMiddleClick: ViewModifier {
    @Environment(WindowState.self) private var state
    let item: SidebarItem

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(SidebarRowMarker(workspace: state.workspaceID, item: item))
    }
}

/// An invisible view in a sidebar row that says which row it is: a middle click finds it inside the
/// table row under the pointer (`TabBarCenter.closeTab`), whatever the list has scrolled to.
struct SidebarRowMarker: NSViewRepresentable {
    let workspace: UUID
    let item: SidebarItem

    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ view: MarkerView, context: Context) {
        view.workspace = workspace
        view.item = item
    }

    final class MarkerView: NSView {
        var workspace: UUID?
        var item: SidebarItem?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A small icon button for sidebar rows. Faint until pointed at; the row's layout never changes.
struct RowAction: View {
    let symbol: String
    let help: String
    var tint: Color = .accentColor
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button(action: action) {
            Image(systemName: hovering ? symbol + ".fill" : symbol)
                .uiFont(size: 12)
                .frame(width: 18 * scale, height: 18 * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? tint : Color.secondary.opacity(0.6))
        // Scale is a visual effect only: it does not change the row's layout.
        .scaleEffect(hovering ? 1.18 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Local shells on this Mac.
private struct LocalSection: View {
    @Environment(\.sidebarLook) private var look

    var body: some View {
        if look.plainSectionHeaders {
            Section {
                rows
            } header: {
                Text("Local")
            }
        } else {
            Section { rows }
        }
    }

    @ViewBuilder
    private var rows: some View {
        LocalRow().tag(SidebarItem.host("local"))
        HostChildren(key: "local", target: .local)
    }
}

/// "This Mac", with a button for a new local terminal.
struct LocalRow: View {
    @Environment(WindowState.self) private var state
    @Environment(\.sidebarLook) private var look

    var body: some View {
        HStack(spacing: 8 * look.scale) {
            if look.style != .minimal {
                Image(systemName: "laptopcomputer").foregroundStyle(.tint).frame(width: look.iconWidth)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("This Mac").uiFont(.body)
                if look.details {
                    Text(localMachineName).uiFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if look.style != .minimal {
                Button {
                    state.connect(.local)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("New local terminal (⌥⌘T)")
            }
        }
        .help(look.details ? "" : localMachineName)
    }
}

private struct ArchiveSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sidebarLook) private var look
    @Environment(WindowState.self) private var state
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.settings.showSidebarArchive && !model.sessions.archive.isEmpty {
            Section {
                ForEach(model.sessions.archive.prefix(30)) { item in
                    ArchiveRow(item: item)
                        .tag(SidebarItem.archived(item.id))
                }
            } header: {
                HStack {
                    Text("Archive")
                    Spacer()
                    if look.counts {
                        Text("\(model.sessions.archive.count)").monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

private struct SidebarBottomBar: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    @Environment(\.openWindow) private var openWindow
    @Binding var showNewGroup: Bool
    @State private var refreshing = false

    var body: some View {
        let sessions = model.sessions.sessions
        let online = sessions.filter { $0.phase.isOnline }.count
        let archived = model.sessions.archive.count
        HStack(spacing: 2) {
            Menu {
                Button("Add Host…") { state.hostEditor = HostEditorRequest() }
                Button("New Group…") { showNewGroup = true }
                Divider()
                Button("Edit SSH Config File…") { state.showConfigEditor = true }
                Button("Reload SSH Config") { model.reloadConfig() }
            } label: {
                // Not the tab bar's "+" (a new tab): this one adds to the host list, and says so.
                Label("Add", systemImage: "server.rack").labelStyle(.titleAndIcon).uiFont(.callout)
            }
            .menuStyle(.button)
            .menuIndicator(.visible)
            .buttonStyle(.borderless)
            .fixedSize()
            .frame(height: 24)
            .help("Add a host or group, or edit the SSH config")

            // Icon-only buttons with tooltips: they fit any sidebar width.
            BarButton(symbol: refreshing ? "arrow.clockwise.circle.fill" : "arrow.clockwise", active: refreshing,
                      help: "Refresh: reload the SSH config and the sessions on each connected server") {
                guard !refreshing else { return }
                refreshing = true
                Task {
                    await model.refreshSidebar()
                    refreshing = false
                }
            }
            BarButton(symbol: model.settings.showSidebarArchive ? "archivebox.fill" : "archivebox",
                      active: model.settings.showSidebarArchive,
                      help: model.settings.showSidebarArchive ? "Hide the archive (\(archived) ended sessions)"
                                                              : "Show the archive (\(archived) ended sessions)") {
                model.settings.showSidebarArchive.toggle()
            }

            Spacer(minLength: 4)

            if !sessions.isEmpty {
                HStack(spacing: 4) {
                    Circle().fill(online > 0 ? Color.green : .secondary).frame(width: 6, height: 6)
                    Text("\(online)/\(sessions.count)").monospacedDigit()
                }
                .uiFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("\(online) of \(sessions.count) sessions online")
            }

            if let update = Updater.shared.available {
                Button {
                    NSWorkspace.shared.open(update.page)
                } label: {
                    Text("Update")
                        .uiFont(.caption2, weight: .semibold)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        .foregroundStyle(.tint)
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .help("Tether \(update.version) is available — open the release page")
            }
            Button {
                openWindow(id: "about")
            } label: {
                Text("v\(AppInfo.bundleVersion)")
                    .uiFont(.caption2).monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .padding(.leading, 6)
            }
            .buttonStyle(.plain)
            .help("About Tether · GitHub")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// A compact icon button (counts go in the tooltip, not on the icon).
private struct BarButton: View {
    let symbol: String
    var active = false
    let help: String
    let action: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .uiFont(.body)
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 28 * scale, height: 24 * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct HostRow: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    @Environment(\.sidebarLook) private var look
    let host: SSHHostEntry

    var body: some View {
        let alias = host.alias ?? ""
        let meta = model.metadata(for: alias)
        let live = model.sessions.sessions(for: alias).filter { !$0.phase.isDead }
        let online = live.filter { $0.phase.isOnline }.count
        HStack(spacing: 8 * look.scale) {
            icon(meta: meta, live: live.count, online: online)
            VStack(alignment: .leading, spacing: 1) {
                Text(alias).uiFont(.body).lineLimit(1)
                if look.details, !subtitle.isEmpty {
                    Text(subtitle).uiFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if look.style == .flat && meta.favorite && model.settings.sidebarShowFavorites {
                Image(systemName: "star.fill").uiFont(size: 9).foregroundStyle(.yellow)
                    .help("Favorite")
            }
            Spacer(minLength: 4)
            if !live.isEmpty { foldControl(alias: alias, live: live.count, online: online) }
            // Always present (a row that changes its content on hover makes the list re-measure it).
            if look.buttons {
                RowAction(symbol: "terminal", help: "New terminal") { state.connect(.alias(alias)) }
                RowAction(symbol: "folder", help: "Open files in a tab") { state.openFiles(.alias(alias)) }
            }
        }
        .padding(.vertical, look.style == .detailed || look.style == .flat ? 2 : 0)
        .help(look.details || subtitle.isEmpty ? "" : subtitle)
    }

    @ViewBuilder
    private func icon(meta: HostMetadata, live: Int, online: Int) -> some View {
        let symbol = host.proxyJump != nil ? "point.3.connected.trianglepath.dotted" : "server.rack"
        switch look.style {
        case .minimal:
            EmptyView()
        case .compact:
            // A light: green with a session online, orange while sessions wait, faint otherwise.
            Circle()
                .fill(online > 0 ? Color.green : live > 0 ? Color.orange : Color.secondary.opacity(0.35))
                .frame(width: 7 * look.scale, height: 7 * look.scale)
                .frame(width: look.iconWidth)
        case .flat:
            HStack(spacing: 4 * look.scale) {
                Circle().fill(groupColor ?? .clear).frame(width: 6 * look.scale, height: 6 * look.scale)
                Image(systemName: symbol).foregroundStyle(meta.color.color ?? .secondary)
            }
            .frame(width: look.iconWidth + 10 * look.scale)
        case .detailed, .folders:
            Image(systemName: symbol)
                .foregroundStyle(meta.color.color ?? .secondary)
                .frame(width: look.iconWidth)
        }
    }

    /// The colour of the host's group (Flat shows it, having no group headers).
    private var groupColor: Color? {
        guard let alias = host.alias, let id = model.metadata(for: alias).groupID else { return nil }
        return model.groups.first { $0.id == id }?.color.color
    }

    /// Folds the host's sessions away: a capsule with the count (Detailed), a quiet count, or only a
    /// chevron. The folder tree folds with its own disclosure triangle, so it only shows the count.
    @ViewBuilder
    private func foldControl(alias: String, live: Int, online: Int) -> some View {
        let folded = SidebarFolding.shared.collapsed.contains(alias)
        let help = folded ? "Show this host's sessions" : "Hide this host's sessions (\(online) of \(live) online)"
        if look.style == .folders {
            if look.counts {
                Text("\(online)/\(live)").uiFont(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .help("\(online) of \(live) sessions online")
            }
        } else {
            Button {
                withAnimation(.snappy) { SidebarFolding.shared.toggle(alias) }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.right")
                        .uiFont(size: 8, weight: .bold)
                        .rotationEffect(.degrees(folded ? 0 : 90))
                    if look.counts { Text("\(online)/\(live)") }
                }
                .uiFont(.caption2)
                .monospacedDigit()
                .padding(.horizontal, look.style == .detailed && look.counts ? 6 : 2).padding(.vertical, 1)
                .background {
                    if look.style == .detailed && look.counts {
                        Capsule().fill((online > 0 ? Color.green : Color.orange).opacity(0.18))
                    }
                }
                .foregroundStyle(look.style == .detailed ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }

    /// user@address:port via jump — without repeating the name above it: an address that is the
    /// alias itself is left out (then only the user, port and jump are worth a line, if any).
    var subtitle: String {
        let alias = host.alias ?? ""
        let address = host.hostName.flatMap { $0.caseInsensitiveCompare(alias) == .orderedSame ? nil : $0 }
        var s = ""
        switch (host.user, address) {
        case let (u?, a?): s = "\(u)@\(a)"
        case let (u?, nil): s = u
        case let (nil, a?): s = a
        case (nil, nil): break
        }
        if let p = host.port, p != 22 { s += s.isEmpty ? "port \(p)" : ":\(p)" }
        if let j = host.proxyJump { s += s.isEmpty ? "via \(j)" : " via \(j)" }
        return s
    }
}

/// An open session under its host. Sessions with a tab look normal; sessions running in the
/// background are dimmed and marked, and open in a tab when clicked.
struct SessionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    @Environment(\.sidebarLook) private var look
    let session: TerminalSession

    /// Minimal shows a session's mark only when it needs you (waiting agent, bell, not connected).
    private var needsAttention: Bool {
        session.attention != nil || (session.agent?.activity.isWaiting ?? false) || !session.phase.isOnline
    }

    var body: some View {
        let inBackground = model.sessions.background.contains(session.id)
        let elsewhere = model.workspaces.otherWindowName(of: session.id, here: state.workspaceID)
        // The mark and the buttons sit in the middle of the whole row — also when a coding agent adds
        // a second line under the title — and every mark gets the same square, so they line up.
        HStack(spacing: 6 * look.scale) {
            if look.style == .minimal && !needsAttention {
                EmptyView()
            } else if session.phase.isSuspended || (inBackground && session.attention == nil && !(session.agent?.activity.isWaiting ?? false)) {
                Image(systemName: session.phase.isSuspended ? "pause.circle.fill" : "moon.zzz.fill")
                    .uiFont(size: 10)
                    .foregroundStyle(session.phase.tint)
                    .frame(width: 16 * look.scale, height: 16 * look.scale)
            } else {
                // The same as the tab: an agent waiting, attention, an agent, a working command.
                TabStatusIcon(session: session, size: 10 * look.scale, restingSymbol: "terminal", animates: false)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6 * look.scale) {
                    if session.phase.isSuspended && look.extras {
                        Text("Suspended").uiFont(.caption2).foregroundStyle(.blue)
                    }
                    Text(session.displayTitle)
                        .uiFont(.body)
                        .lineLimit(1)
                        .foregroundStyle(session.phase.isDead || elsewhere != nil || (inBackground && !look.extras) ? .secondary : .primary)
                    if let elsewhere { OtherWindowBadge(name: elsewhere) }
                    if inBackground && !session.phase.isSuspended && look.extras {
                        Text("background").uiFont(.caption2).foregroundStyle(.secondary)
                    }
                    if let c = session.descriptor.color.color, look.style != .minimal {
                        Circle().fill(c).frame(width: 6 * look.scale, height: 6 * look.scale)
                    }
                }
                // A coding agent in the tab: its session name, under the title.
                if look.extras, let pane = agentPane {
                    PaneSummary(pane: pane, showPath: false, stateOnly: session.agentTitle != nil)
                }
            }
            Spacer(minLength: 4)
            // Always present; they only light up on hover, so the row never changes its layout.
            if !look.buttons {
                EmptyView()
            } else if session.phase.isSuspended {
                RowAction(symbol: "play.circle", help: "Reconnect", tint: .blue) { state.show(session) }
            } else if session.canSuspend {
                RowAction(symbol: "pause.circle", help: "Disconnect & move to background (keeps running on the server)",
                          tint: .blue) { state.disconnectToBackground(session) }
            }
            if look.buttons {
                RowAction(symbol: "xmark.circle", help: "Close…", tint: .orange) { state.closeTab(session) }
                RowAction(symbol: "trash.circle", help: "Terminate — ends the shell on the server", tint: .red) {
                    state.terminate(session)
                }
            }
        }
        .padding(.leading, look.childIndent)
        .tag(SidebarItem.session(session.id))
        .id(SidebarItem.session(session.id))
        .middleClickCloses(.session(session.id))
        .help(elsewhere.map { "Open in \($0) — click to go there · right-click to move it here" }
              ?? (inBackground ? "In the background — click to open in a tab · double-click to rename" : "Double-click to rename"))
    }
}

extension SessionRow {
    /// The tab's active pane, when the last look at the host's tmux sessions found a coding agent in it.
    private var agentPane: RemoteSessionPane? {
        guard !session.phase.isDead, session.persistence == .tmux else { return nil }
        let entry = model.monitor(for: session.descriptor.target).remoteSessions
            .first { $0.kind == .tmux && $0.name == session.descriptor.remoteSessionName }
        guard let pane = entry?.activePane, pane.agent != nil else { return nil }
        return pane
    }
}

struct ArchiveRow: View {
    @Environment(\.sidebarLook) private var look
    let item: ArchivedSession
    var body: some View {
        HStack(spacing: 8 * look.scale) {
            if look.style != .minimal {
                Image(systemName: "archivebox").foregroundStyle(.secondary).frame(width: look.iconWidth)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).uiFont(.body).lineLimit(1)
                if look.style != .minimal && look.style != .compact {
                    Text(item.endedAt, format: .relative(presentation: .named))
                        .uiFont(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct HostContextMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    @Environment(\.openWindow) private var openWindow
    let alias: String

    var body: some View {
        Button("Connect") { state.connect(.alias(alias), mode: .tab) }
        Button("Connect in New Window") { state.connect(.alias(alias), mode: .window) }
        Button("Connect in Private Tab") { state.connect(.alias(alias), mode: .tab, isPrivate: true) }
            .help("Nothing is kept on this Mac: no recording, archive or command history")
        Button("Open Files in a Tab") { state.openFiles(.alias(alias)) }
        Button("Open Files in a Window") { openWindow(id: "files", value: FilesRequest(target: .alias(alias), path: nil)) }
        Button("Search on This Host…") {
            model.searchPreset = SearchPreset(host: alias, session: nil)
            openWindow(id: "search")
        }
        Divider()
        Button("Edit Host…") { state.hostEditor = HostEditorRequest(alias: alias) }
        if model.offersKeySetup(alias) {
            Button("Set Up SSH Key…") { state.keySetupTarget = KeySetupRequest(alias: alias) }
        }
        Toggle("Favorite", isOn: Binding(get: { model.metadata(for: alias).favorite },
                                         set: { v in model.updateMetadata(for: alias) { $0.favorite = v } }))
        Menu("Monitoring") {
            HostFeaturesMenu(target: .alias(alias)) { state.hostEditor = HostEditorRequest(alias: alias) }
        }
        Menu("Move to Group") {
            Button("None") { model.moveHost(alias, toGroup: nil) }
            ForEach(model.groups) { g in
                Button(g.name) { model.moveHost(alias, toGroup: g.id) }
            }
        }
        Menu("Color") {
            ForEach(TagColor.allCases) { c in
                Button(c.title) { model.updateMetadata(for: alias) { $0.color = c } }
            }
        }
        SessionSortMenu()
        Divider()
        Button("Terminate All Sessions on This Host…", role: .destructive) { state.terminateAll(on: .alias(alias)) }
        Button("Remove from SSH Config…", role: .destructive) {
            let alert = NSAlert()
            alert.messageText = "Remove \"\(alias)\" from your SSH config?"
            alert.informativeText = "A backup of the config file is kept in Tether's application support folder."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.first?.hasDestructiveAction = true
            if alert.runModal() == .alertFirstButtonReturn {
                do { try model.removeHost(alias) } catch { NSAlert(error: error).runModal() }
            }
        }
    }
}

/// "Sort Sessions" (one order for every host), in host and session context menus.
struct SessionSortMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settingsStore
        Picker("Sort Sessions", selection: $settings.settings.sessionSortOrder) {
            ForEach(SessionSortOrder.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
    }
}

struct SessionContextMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let session: TerminalSession

    var body: some View {
        let inBackground = model.sessions.background.contains(session.id)
        Button(session.phase.isSuspended ? "Reconnect" : inBackground ? "Open in Tab" : "Show") { state.show(session) }
        if let elsewhere = model.workspaces.otherWindowName(of: session.id, here: state.workspaceID) {
            Button("Move from \(elsewhere) to This Window") {
                let source = model.workspaces.workspace(containing: session.id)
                model.workspaces.add(session.id, to: state.workspaceID)
                if let source { model.workspaces.closeIfEmpty(source) }
            }
        }
        Button("Browse Files Here") { state.browse(session.descriptor.target, path: session.currentDirectory) }
        SearchInSessionButton(session: session)
        Button("Rename…") { state.renamingSession = session }
        Menu("Color") {
            ForEach(TagColor.allCases) { c in
                Button(c.title) { model.sessions.setColor(session.id, c) }
            }
        }
        SessionSortMenu()
        Button("New Session to Same Host") { state.newSession(like: session) }
        if case .waiting = session.phase {
            Button("Reconnect Now") { session.reconnectNow() }
        }
        Divider()
        if !inBackground {
            Button("Move to Background") { state.moveToBackground(.terminal(session)) }
        }
        if session.canSuspend {
            Button("Disconnect & Move to Background") { state.disconnectToBackground(session) }
        }
        Button("Close…") { state.closeTab(session) }
        Button("Terminate Session…", role: .destructive) { state.terminate(session) }
    }
}

/// Says which other window shows a tab ("Window 2").
struct OtherWindowBadge: View {
    let name: String

    var body: some View {
        Label(name, systemImage: "macwindow")
            .labelStyle(.titleAndIcon)
            .uiFont(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(.quaternary))
            .lineLimit(1)
            .fixedSize()
    }
}

/// A file manager tab under its host (open in a window, or kept in the background).
struct FileTabRow: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    @Environment(\.sidebarLook) private var look
    let tab: FileTab

    var body: some View {
        let open = model.workspaces.workspace(containing: tab.id) != nil
        let elsewhere = model.workspaces.otherWindowName(of: tab.id, here: state.workspaceID)
        HStack(spacing: 6) {
            Image(systemName: open ? "folder.fill" : "folder")
                .uiFont(size: 10)
                .foregroundStyle(Color.accentColor)
                .frame(width: 16 * look.scale, height: 16 * look.scale)
            Text(model.fileTabs.title(of: tab))
                .uiFont(.body)
                .lineLimit(1)
                .foregroundStyle(elsewhere != nil || (!open && !look.extras) ? .secondary : .primary)
            if let elsewhere { OtherWindowBadge(name: elsewhere) }
            if !open && look.extras {
                Text("background").uiFont(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, look.childIndent)
        .tag(SidebarItem.files(tab.id))
        .id(SidebarItem.files(tab.id))
        .middleClickCloses(.files(tab.id))
        .help(elsewhere.map { "Open in \($0) — click to go there" }
              ?? (open ? "File manager tab" : "File manager in the background — click to open"))
    }
}

/// Context menu for whatever sidebar row was right-clicked.
struct SidebarItemMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    @Environment(\.openWindow) private var openWindow
    let item: SidebarItem

    var body: some View {
        switch item {
        case .host(let key):
            if key == "local" {
                Button("New Local Terminal") { state.connect(.local) }
                Button("New Local Terminal in New Window") { state.connect(.local, mode: .window) }
                Button("Open Files in a Tab") { state.openFiles(.local) }
            } else if model.aliases.contains(key) {
                HostContextMenu(alias: key)
            } else {
                Button("New Session") { state.connect(model.target(forKey: key)) }
                Button("Open Files in a Tab") { state.openFiles(model.target(forKey: key)) }
                Button("Terminate All Sessions…", role: .destructive) { state.terminateAll(on: model.target(forKey: key)) }
            }
        case .session(let id):
            if let s = model.sessions.session(id) { SessionContextMenu(session: s) }
        case .files(let id):
            if let t = model.fileTabs.tab(id) {
                Button("Open") { state.show(t) }
                Button("Open Terminal Here") {
                    state.connect(t.target, directory: model.fileTabs.browser(for: t).directory)
                }
                if model.workspaces.workspace(containing: id) != nil {
                    Button("Move to Background") { state.moveToBackground(.files(t)) }
                }
                Divider()
                Button("Close") { state.close(.files(t)) }
            }
        case .archived(let id):
            if let a = model.sessions.archive.first(where: { $0.id == id }) {
                Button("Open Transcript") { openWindow(id: "transcript", value: TranscriptRequest(archiveID: id)) }
                Button("New Session to \(a.target.displayName)") { state.connect(a.target) }
                Divider()
                Button("Remove from Archive", role: .destructive) { model.sessions.deleteArchived(id, deleteRecording: false) }
            }
        }
    }
}

/// Sidebar search: a host matches by its alias, address or user, or when one of its sessions
/// (by tab name, custom name or running command) matches.
@MainActor
func hostMatches(_ h: SSHHostEntry, search: String, model: AppModel) -> Bool {
    let q = search.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return true }
    if [h.alias, h.hostName, h.user].compactMap({ $0 }).contains(where: { $0.localizedCaseInsensitiveContains(q) }) { return true }
    guard let alias = h.alias else { return false }
    return model.sessions.sessions(for: alias).contains { sessionMatches($0, q) }
}

@MainActor
func sessionMatches(_ s: TerminalSession, _ q: String) -> Bool {
    guard !q.isEmpty else { return true }
    return [s.displayTitle, s.descriptor.title, s.remoteTitle, s.activity?.command ?? ""]
        .contains { $0.localizedCaseInsensitiveContains(q) }
}
