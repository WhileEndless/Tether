import SwiftUI
import TetherCore
import MonitorKit

struct ConnectionsPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let monitor: RemoteMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ListeningCard(sockets: monitor.listeningPorts) { s in
                    if let target = state.inspectedTarget { model.quickForward(target, port: s.port, address: s.address) }
                }
                Card(title: "Logged-in users") {
                    if monitor.logins.isEmpty {
                        Text("Nobody").foregroundStyle(.secondary)
                    }
                    ForEach(monitor.logins) { l in
                        HStack {
                            Image(systemName: "person.crop.circle").foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text(l.user).fontWeight(.medium)
                                Text("\(l.terminal) · \(l.since)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(l.from).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                Card(title: "Established TCP connections (\(monitor.connections.count))") {
                    ForEach(monitor.connections) { c in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: c.isSSH ? "lock.fill" : "arrow.left.arrow.right")
                                .foregroundStyle(c.isSSH ? .green : .secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.peer).font(.callout.monospaced())
                                Text("→ \(c.local)\(c.process.isEmpty ? "" : " · \(c.process)")")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .refreshable { await monitor.refreshConnections() }
        .task {
            while !Task.isCancelled {
                await monitor.refreshConnections()
                await monitor.refreshListeningPorts()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }
}

/// What the server listens on and from where it can be reached.
struct ListeningCard: View {
    let sockets: [ListeningSocket]
    let forward: (ListeningSocket) -> Void

    var body: some View {
        Card(title: "Listening ports (\(sockets.count))") {
            if sockets.isEmpty {
                Text("Loading…").foregroundStyle(.secondary)
            }
            ForEach([Exposure.allInterfaces, .interface, .localOnly], id: \.self) { exposure in
                let group = sockets.filter { $0.exposure == exposure }
                if !group.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(title(exposure), systemImage: icon(exposure))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color(exposure))
                        ForEach(group) { s in row(s) }
                    }
                    .padding(.bottom, 4)
                }
            }
            Text("Process names of other users' services are only visible with root rights.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func row(_ s: ListeningSocket) -> some View {
        HStack(spacing: 8) {
            Text("\(s.port)").font(.callout.monospacedDigit().weight(.medium)).frame(width: 52, alignment: .leading)
            Text(s.proto.uppercased()).font(.caption2).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if let c = s.container {
                        Label(c, systemImage: "shippingbox.fill").font(.caption).foregroundStyle(.teal)
                    }
                    Text(s.process.isEmpty ? "unknown process" : s.process + (s.pid.map { " (\($0))" } ?? ""))
                        .font(.caption).foregroundStyle(s.process.isEmpty ? .tertiary : .primary)
                }
                Text(s.address).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer()
            if s.proto == "tcp" {
                Button("Forward") { forward(s) }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Make it reachable on this Mac through the SSH connection")
            }
        }
    }

    private func title(_ e: Exposure) -> String {
        switch e {
        case .allInterfaces: "Reachable from outside (all interfaces)"
        case .interface: "Bound to one interface"
        case .localOnly: "Local only (server itself)"
        }
    }

    private func icon(_ e: Exposure) -> String {
        switch e {
        case .allInterfaces: "globe"
        case .interface: "network"
        case .localOnly: "lock"
        }
    }

    private func color(_ e: Exposure) -> Color {
        switch e {
        case .allInterfaces: .orange
        case .interface: .blue
        case .localOnly: .secondary
        }
    }
}

struct RemoteSessionsPanel: View {
    @Environment(AppModel.self) private var model
    let monitor: RemoteMonitor
    let target: ConnectionTarget

    private var openNames: Set<String> {
        Set(model.sessions.sessions(for: target.key).filter { !$0.phase.isDead }.map(\.descriptor.remoteSessionName))
    }

    private var leftoverCount: Int {
        monitor.remoteSessions.filter { $0.isTether && !openNames.contains($0.name) && !$0.attached }.count
    }

    var body: some View {
        List {
            Section {
                ForEach(monitor.remoteSessions) { RemoteSessionRow(entry: $0, monitor: monitor, target: target) }
            } header: {
                HStack {
                    Text("tmux / screen sessions on this host")
                    Spacer()
                    let leftovers = leftoverCount
                    if leftovers > 0 {
                        Button("Clean Up \(leftovers) Leftover") {
                            Task { _ = await monitor.cleanUpOrphans(keeping: openNames) }
                        }
                        .help("Kill detached Tether sessions that are not open in the app")
                    }
                }
            } footer: {
                Text("Includes sessions you started yourself. Attach to continue where you left off; leftovers from closed tabs can be cleaned up.")
            }
        }
        .overlay {
            if monitor.remoteSessions.isEmpty {
                EmptyStateView(symbol: "rectangle.stack", title: "No Persistent Sessions",
                               message: "tmux or screen sessions created by Tether will appear here.")
            }
        }
        .task { await monitor.refreshRemoteSessions() }
        .refreshable { await monitor.refreshRemoteSessions() }
    }
}

private struct RemoteSessionRow: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let entry: RemoteSessionEntry
    let monitor: RemoteMonitor
    let target: ConnectionTarget

    private var isOpen: Bool {
        model.sessions.sessions.contains { $0.descriptor.remoteSessionName == entry.name && !$0.phase.isDead }
    }

    private var detail: String {
        var parts = [entry.kind.rawValue, entry.attached ? "attached" : "detached"]
        if let w = entry.windows { parts.append("\(w) window\(w == 1 ? "" : "s")") }
        if let created = entry.created { parts.append(created.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack {
            Image(systemName: entry.kind == .tmux ? "rectangle.split.3x1" : "rectangle.on.rectangle")
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                Text(entry.name).font(.callout.monospaced())
                if entry.isTether {
                    Text("Tether").font(.caption2).padding(.horizontal, 4).background(Capsule().fill(.quaternary))
                }
            }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                Task { await monitor.killRemoteSession(entry) }
            } label: { Image(systemName: "xmark.circle") }
            .buttonStyle(.borderless)
            .help("Kill this session on the server")
            if isOpen {
                Text("Open").font(.caption).foregroundStyle(.green)
            } else {
                Button("Attach") {
                    state.connect(target, remoteSessionName: entry.name,
                                  persistence: entry.kind == .tmux ? .tmux : .screen)
                }
                .buttonStyle(.glass)
            }
        }
        .contextMenu {
            Button("Kill Session", role: .destructive) { Task { await monitor.killRemoteSession(entry) } }
        }
    }
}
