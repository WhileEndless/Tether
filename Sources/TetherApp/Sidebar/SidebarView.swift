import SwiftUI
import TetherCore
import SSHConfigKit
import SessionKit
import MonitorKit

struct SidebarView: View {
    @Environment(AppModel.self) private var model
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
        @Bindable var state = state
        List(selection: $state.sidebarSelection) {
            LocalSection()
            favoritesSection
            ForEach(model.groups) { group in
                GroupSection(group: group, search: search, onRename: {
                    newGroupName = group.name
                    renamingGroup = group
                })
            }
            ungroupedSection
            quickConnectionsSection
            ArchiveSection()
        }
        .listStyle(.sidebar)
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
                if id != state.workspace.selected, let s = model.sessions.session(id) { state.show(s) }
            case .files(let id):
                if id != state.workspace.selected, let t = model.fileTabs.tab(id) { state.show(t) }
            case .host:
                // Clicking a host shows its details in the host panel.
                state.inspectorTab = .overview
                state.showInspectorRequest = true
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

    @ViewBuilder
    private var favoritesSection: some View {
        let favorites = model.ordered(model.hosts.filter { $0.alias.map { model.metadata(for: $0).favorite } ?? false })
        if !favorites.isEmpty && search.isEmpty {
            Section("Favorites") {
                ForEach(favorites, id: \.id) { HostRows(host: $0, search: search) }
            }
        }
    }

    private var ungroupedSection: some View {
        Section {
            ForEach(filtered(model.hosts(in: nil)), id: \.id) { HostRows(host: $0, search: search) }
                .onMove { from, to in model.moveHosts(in: nil, from: from, to: to) }
            if model.hosts.isEmpty {
                Button {
                    state.hostEditor = HostEditorRequest()
                } label: {
                    Label("Add your first host", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
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
                    ForEach(model.sessions.sessions(for: key)) { SessionRow(session: $0) }
                    ForEach(model.fileTabs.tabs(for: key)) { FileTabRow(tab: $0) }
                }
            }
        }
    }

    private var adhocKeys: [String] {
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
            }
            .dropDestination(for: String.self) { items, _ in
                items.forEach { model.moveHost($0, toGroup: group.id) }
                return !items.isEmpty
            }
            .contextMenu {
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
    }

    private var hosts: [SSHHostEntry] {
        model.hosts(in: group.id).filter { hostMatches($0, search: search, model: model) }
    }
}

/// A host row followed by its open sessions.
private struct HostRows: View {
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

    var body: some View {
        if let alias = host.alias {
            HostRow(host: host)
                .tag(SidebarItem.host(alias))
                .draggable(alias)
            ForEach(visibleSessions(alias)) { SessionRow(session: $0) }
            ForEach(model.fileTabs.tabs(for: alias)) { FileTabRow(tab: $0) }
            ServerSessionRows(target: .alias(alias))
        }
    }
}

/// tmux/screen sessions found on the server that are not open in Tether (including the user's own).
private struct ServerSessionRows: View {
    @Environment(AppModel.self) private var model
    let target: ConnectionTarget

    var body: some View {
        let monitor = model.monitor(for: target)
        let open = Set(model.sessions.sessions(for: target.key).map(\.descriptor.remoteSessionName))
        ForEach(monitor.remoteSessions.filter { !open.contains($0.name) }) { entry in
            ServerSessionRow(entry: entry, target: target, monitor: monitor)
        }
    }
}

/// One server-side session: click it (or Attach) to open it in a tab.
private struct ServerSessionRow: View {
    @Environment(WindowState.self) private var state
    let entry: RemoteSessionEntry
    let target: ConnectionTarget
    let monitor: RemoteMonitor
    @State private var attaching = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack")
                .font(.caption)
                .foregroundStyle(entry.attached ? .green : .secondary)
                .frame(width: 16)
            Text(entry.isTether ? "Detached session" : entry.name)
                .lineLimit(1)
            Text(entry.kind.rawValue)
                .font(.caption2)
                .padding(.horizontal, 4)
                .background(Capsule().fill(.quaternary))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if attaching {
                ProgressView().controlSize(.mini)
            } else {
                RowAction(symbol: "arrow.right.circle", help: "Attach in a new tab", action: attach)
                RowAction(symbol: "xmark.circle", help: "Kill this session on the server") {
                    Task { await monitor.killRemoteSession(entry) }
                }
            }
        }
        .padding(.leading, 22)
        .contentShape(Rectangle())
        .onTapGesture(perform: attach)
        .help("\(entry.kind.rawValue) session “\(entry.name)” on the server\(entry.attached ? " (attached elsewhere)" : "") — click to open it in a tab")
        .contextMenu {
            Button("Attach in New Tab", action: attach)
            Divider()
            Button("Kill on Server", role: .destructive) { Task { await monitor.killRemoteSession(entry) } }
        }
    }

    private func attach() {
        guard !attaching else { return }
        attaching = true
        state.connect(target, remoteSessionName: entry.name, persistence: entry.kind == .tmux ? .tmux : .screen)
        // The row disappears once the session is open; reset in case attaching fails.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { attaching = false }
    }
}

/// A small icon button for sidebar rows. Faint until pointed at; the row's layout never changes.
struct RowAction: View {
    let symbol: String
    let help: String
    var tint: Color = .accentColor
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: hovering ? symbol + ".fill" : symbol)
                .font(.system(size: 12))
                .frame(width: 18, height: 18)
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
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer").foregroundStyle(.tint).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("This Mac")
                    Text(localMachineName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button {
                    state.connect(.local)
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("New local terminal (⌥⌘T)")
            }
            .tag(SidebarItem.host("local"))
            ForEach(model.sessions.sessions(for: "local")) { SessionRow(session: $0) }
            ForEach(model.fileTabs.tabs(for: "local")) { FileTabRow(tab: $0) }
        } header: {
            Text("Local")
        }
    }
}

private struct ArchiveSection: View {
    @Environment(AppModel.self) private var model
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
                    Text("\(model.sessions.archive.count)").monospacedDigit().foregroundStyle(.tertiary)
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
                Image(systemName: "plus")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .frame(width: 28, height: 24)
            .help("Add a host or group")

            // Icon-only buttons with tooltips: they fit any sidebar width.
            BarButton(symbol: model.settings.showSidebarArchive ? "archivebox.fill" : "archivebox",
                      badge: archived, active: model.settings.showSidebarArchive,
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .help("\(online) of \(sessions.count) sessions online")
            }

            if let update = Updater.shared.available {
                Button {
                    NSWorkspace.shared.open(update.page)
                } label: {
                    Text("Update")
                        .font(.caption2.weight(.semibold))
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
                    .font(.caption2.monospacedDigit())
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

/// A compact icon button with an optional count badge.
private struct BarButton: View {
    let symbol: String
    var badge = 0
    var active = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 28, height: 24)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.system(size: 9, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.25)))
                            .offset(x: 2, y: -1)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct HostRow: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let host: SSHHostEntry

    var body: some View {
        let alias = host.alias ?? ""
        let meta = model.metadata(for: alias)
        let sessions = model.sessions.sessions(for: alias)
        HStack(spacing: 8) {
            Image(systemName: host.proxyJump != nil ? "point.3.connected.trianglepath.dotted" : "server.rack")
                .foregroundStyle(meta.color.color ?? .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(alias).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !sessions.isEmpty {
                let online = sessions.filter { $0.phase.isOnline }.count
                Text("\(online)/\(sessions.count)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill((online > 0 ? Color.green : Color.orange).opacity(0.18)))
            }
            // Always present (a row that changes its content on hover makes the list re-measure it).
            RowAction(symbol: "terminal", help: "New terminal") { state.connect(.alias(alias)) }
            RowAction(symbol: "folder", help: "Open files in a tab") { state.openFiles(.alias(alias)) }
        }
        .padding(.vertical, 2)

    }

    private var subtitle: String {
        var s = ""
        if let u = host.user { s += u + "@" }
        s += host.hostName ?? host.alias ?? ""
        if let p = host.port, p != 22 { s += ":\(p)" }
        if let j = host.proxyJump { s += " via \(j)" }
        return s
    }
}

/// An open session under its host. Sessions with a tab look normal; sessions running in the
/// background are dimmed and marked, and open in a tab when clicked.
struct SessionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let session: TerminalSession

    var body: some View {
        let inBackground = model.sessions.background.contains(session.id)
        HStack(spacing: 6) {
            Image(systemName: session.phase.isSuspended ? "pause.circle.fill" : inBackground ? "moon.zzz.fill" : "terminal")
                .font(.caption)
                .foregroundStyle(session.phase.tint)
                .frame(width: 16)
            if session.phase.isSuspended {
                Text("Suspended").font(.caption2).foregroundStyle(.blue)
            }
            Text(session.displayTitle)
                .lineLimit(1)
                .foregroundStyle(session.phase.isDead ? .secondary : .primary)
            if inBackground && !session.phase.isSuspended {
                Text("background").font(.caption2).foregroundStyle(.secondary)
            }
            if let c = session.descriptor.color.color {
                Circle().fill(c).frame(width: 6, height: 6)
            }
            Spacer(minLength: 4)
            // Always present; they only light up on hover, so the row never changes its layout.
            if session.phase.isSuspended {
                RowAction(symbol: "play.circle", help: "Reconnect", tint: .blue) { state.show(session) }
            } else if session.canSuspend {
                RowAction(symbol: "pause.circle", help: "Disconnect & move to background (keeps running on the server)",
                          tint: .blue) { state.disconnectToBackground(session) }
            }
            RowAction(symbol: "xmark.circle", help: "Close…", tint: .orange) { state.closeTab(session) }
            RowAction(symbol: "trash.circle", help: "Terminate — ends the shell on the server", tint: .red) {
                state.terminate(session)
            }
        }
        .padding(.leading, 22)
        .tag(SidebarItem.session(session.id))
        .help(inBackground ? "In the background — click to open in a tab · double-click to rename" : "Double-click to rename")
    }
}

struct ArchiveRow: View {
    let item: ArchivedSession
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                Text(item.endedAt, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
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
        Button("Open Files in a Tab") { state.openFiles(.alias(alias)) }
        Button("Open Files in a Window") { openWindow(id: "files", value: FilesRequest(target: .alias(alias), path: nil)) }
        Button("Search on This Host…") {
            model.searchPreset = SearchPreset(host: alias, session: nil)
            openWindow(id: "search")
        }
        Divider()
        Button("Edit Host…") { state.hostEditor = HostEditorRequest(alias: alias) }
        if model.metadata(for: alias).keyLoginWorks != true {
            Button("Set Up SSH Key…") { state.keySetupTarget = KeySetupRequest(alias: alias) }
        }
        Toggle("Favorite", isOn: Binding(get: { model.metadata(for: alias).favorite },
                                         set: { v in model.updateMetadata(for: alias) { $0.favorite = v } }))
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

struct SessionContextMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let session: TerminalSession

    var body: some View {
        let inBackground = model.sessions.background.contains(session.id)
        Button(session.phase.isSuspended ? "Reconnect" : inBackground ? "Open in Tab" : "Show") { state.show(session) }
        Button("Browse Files Here") { state.openFiles(session.descriptor.target, path: session.currentDirectory) }
        SearchInSessionButton(session: session)
        Button("Rename…") { state.renamingSession = session }
        Menu("Color") {
            ForEach(TagColor.allCases) { c in
                Button(c.title) { model.sessions.setColor(session.id, c) }
            }
        }
        Button("New Session to Same Host") { state.connect(session.descriptor.target) }
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

/// A file manager tab under its host (open in a window, or kept in the background).
struct FileTabRow: View {
    @Environment(AppModel.self) private var model
    let tab: FileTab

    var body: some View {
        let open = model.workspaces.workspace(containing: tab.id) != nil
        HStack(spacing: 6) {
            Image(systemName: open ? "folder.fill" : "folder")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)
            Text(model.fileTabs.title(of: tab))
                .lineLimit(1)
            if !open {
                Text("background").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 22)
        .tag(SidebarItem.files(tab.id))
        .help(open ? "File manager tab" : "File manager in the background — click to open")
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
