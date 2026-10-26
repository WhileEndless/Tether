import SwiftUI
import TetherCore
import SSHConfigKit
import SessionKit

/// The Folders sidebar style: a Finder-like tree. Groups are folders, hosts open to their sessions,
/// and Favorites, Other Hosts, Quick Connections and the archive are folders of their own. Rows,
/// selection, menus and drag and drop are the same as in the other styles.
struct SidebarFolderTree: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let search: String
    let adhocKeys: [String]
    let onRename: (HostGroup) -> Void

    var body: some View {
        let searching = !search.isEmpty
        HostNode(key: "local", target: .local, searching: searching) {
            LocalRow().tag(SidebarItem.host("local"))
        } children: {
            HostChildren(key: "local", target: .local)
        }

        let favorites = model.ordered(model.hosts.filter { $0.alias.map { model.metadata(for: $0).favorite } ?? false })
        if !favorites.isEmpty && !searching && model.settings.sidebarShowFavorites {
            SidebarFolder(key: SidebarFolding.favoritesFolder, title: "Favorites", symbol: "star.fill", tint: .yellow,
                          count: favorites.count, searching: false) {
                ForEach(favorites, id: \.id) { HostRows(host: $0, search: search) }
            }
        }

        ForEach(model.groups) { group in
            GroupFolder(group: group, hosts: filtered(model.hosts(in: group.id)), search: search) { onRename(group) }
        }

        let ungrouped = filtered(model.hosts(in: nil))
        if model.groups.isEmpty {
            // No groups: hosts sit at the top level, like files in a folder.
            ForEach(ungrouped, id: \.id) { HostRows(host: $0, search: search) }
                .onMove { from, to in model.moveHosts(in: nil, from: from, to: to) }
        } else if !ungrouped.isEmpty {
            SidebarFolder(key: SidebarFolding.otherHostsFolder, title: "Other Hosts", symbol: "tray.fill", tint: nil,
                          count: ungrouped.count, searching: searching, dropToGroup: .some(nil)) {
                ForEach(ungrouped, id: \.id) { HostRows(host: $0, search: search) }
                    .onMove { from, to in model.moveHosts(in: nil, from: from, to: to) }
            }
        }
        if model.hosts.isEmpty {
            Button {
                state.hostEditor = HostEditorRequest()
            } label: {
                Label("Add your first host", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }

        if !adhocKeys.isEmpty {
            SidebarFolder(key: SidebarFolding.quickFolder, title: "Quick Connections", symbol: "bolt.horizontal.fill",
                          tint: nil, count: adhocKeys.count, searching: searching) {
                ForEach(adhocKeys, id: \.self) { key in
                    let target = model.target(forKey: key)
                    HostNode(key: key, target: target, searching: searching) {
                        Label(key, systemImage: "bolt.horizontal").tag(SidebarItem.host(key))
                    } children: {
                        HostChildren(key: key, target: target)
                    }
                }
            }
        }

        if model.settings.showSidebarArchive && !model.sessions.archive.isEmpty {
            SidebarFolder(key: SidebarFolding.archiveFolder, title: "Archive", symbol: "archivebox.fill", tint: nil,
                          count: model.sessions.archive.count, searching: false) {
                ForEach(model.sessions.archive.prefix(30)) { item in
                    ArchiveRow(item: item).tag(SidebarItem.archived(item.id))
                }
            }
        }
    }

    private func filtered(_ hosts: [SSHHostEntry]) -> [SSHHostEntry] {
        hosts.filter { hostMatches($0, search: search, model: model) }
    }
}

/// A host in the tree: opens to its sessions, file tabs and server sessions when it has any.
/// Folding uses the same remembered state as the other styles.
struct HostNode<Label: View, Children: View>: View {
    @Environment(AppModel.self) private var model
    let key: String
    let target: ConnectionTarget
    let searching: Bool
    @ViewBuilder var label: Label
    @ViewBuilder var children: Children

    var body: some View {
        if hasChildren {
            let folding = SidebarFolding.shared
            DisclosureGroup(isExpanded: Binding(
                get: { searching || !folding.collapsed.contains(key) },
                set: { open in
                    if open { folding.collapsed.remove(key) } else { folding.collapsed.insert(key) }
                })) {
                children
            } label: {
                label
            }
        } else {
            label
        }
    }

    private var hasChildren: Bool {
        if model.sessions.sessions(for: key).contains(where: { !$0.phase.isDead }) { return true }
        if !model.fileTabs.tabs(for: key).isEmpty { return true }
        guard !target.isLocal else { return false }
        let open = Set(model.sessions.sessions(for: key).map(\.descriptor.remoteSessionName))
        return model.monitor(for: target).remoteSessions.contains { !open.contains($0.name) }
    }
}

/// A folder row with a symbol, a name and a count; its open state is remembered.
struct SidebarFolder<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sidebarLook) private var look
    let key: String
    let title: String
    let symbol: String
    let tint: Color?
    let count: Int
    let searching: Bool
    /// Hosts dropped here move to this group (`.some(nil)`: out of every group).
    var dropToGroup: UUID?? = nil
    @ViewBuilder var content: Content

    var body: some View {
        let folding = SidebarFolding.shared
        DisclosureGroup(isExpanded: Binding(
            get: { searching || !folding.collapsed.contains(key) },
            set: { open in
                if open { folding.collapsed.remove(key) } else { folding.collapsed.insert(key) }
            })) {
            content
        } label: {
            FolderLabel(title: title, symbol: symbol, tint: tint, count: look.counts ? count : nil)
                .dropDestination(for: String.self) { items, _ in
                    guard let group = dropToGroup else { return false }
                    items.forEach { model.moveHost($0, toGroup: group) }
                    return !items.isEmpty
                }
        }
    }
}

/// A user group as a folder in its colour; hosts can be dropped on it.
private struct GroupFolder: View {
    @Environment(AppModel.self) private var model
    @Environment(\.sidebarLook) private var look
    let group: HostGroup
    let hosts: [SSHHostEntry]
    let search: String
    let onRename: () -> Void

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { group.isExpanded || !search.isEmpty },
                                            set: { v in model.updateGroup(group.id) { $0.isExpanded = v } })) {
            ForEach(hosts, id: \.id) { HostRows(host: $0, search: search) }
                .onMove { from, to in model.moveHosts(in: group.id, from: from, to: to) }
        } label: {
            FolderLabel(title: group.name, symbol: "folder.fill", tint: group.color.color,
                        count: look.counts ? model.hosts(in: group.id).count : nil)
                .dropDestination(for: String.self) { items, _ in
                    items.forEach { model.moveHost($0, toGroup: group.id) }
                    return !items.isEmpty
                }
                .contextMenu { GroupMenu(group: group, onRename: onRename) }
        }
    }
}

private struct FolderLabel: View {
    @Environment(\.sidebarLook) private var look
    let title: String
    let symbol: String
    let tint: Color?
    let count: Int?

    var body: some View {
        HStack(spacing: 7 * look.scale) {
            Image(systemName: symbol)
                .foregroundStyle(tint ?? Color.secondary)
                .frame(width: look.iconWidth)
            Text(title).uiFont(.body, weight: .medium).lineLimit(1)
            Spacer(minLength: 4)
            if let count {
                Text("\(count)").uiFont(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}
