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
                ProcessTrafficCard(monitor: monitor)
                ListeningCard(sockets: monitor.listeningPorts) { s in
                    if let target = state.inspectedTarget { model.quickForward(target, port: s.port, address: s.address) }
                }
                Card(title: "Logged-in users", onExport: monitor.logins.isEmpty ? nil : {
                    let logins = monitor.logins
                    ExportPanel.save(title: "Export Logged-in Users", baseName: "logged-in users", formats: MonitorExport.Format.table) { MonitorExport.logins(logins, format: $0) }
                }) {
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
                .contextMenu {
                    let logins = monitor.logins
                    Button("Export Logged-in Users…") {
                        ExportPanel.save(title: "Export Logged-in Users", baseName: "logged-in users", formats: MonitorExport.Format.table) { MonitorExport.logins(logins, format: $0) }
                    }
                    .disabled(logins.isEmpty)
                }
                Card(title: "Established TCP connections (\(monitor.connections.count))", onExport: monitor.connections.isEmpty ? nil : {
                    let connections = monitor.connections
                    ExportPanel.save(title: "Export TCP Connections", baseName: "tcp connections", formats: MonitorExport.Format.table) { MonitorExport.tcpConnections(connections, format: $0) }
                }) {
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
                .contextMenu {
                    let connections = monitor.connections
                    Button("Export TCP Connections…") {
                        ExportPanel.save(title: "Export TCP Connections", baseName: "tcp connections", formats: MonitorExport.Format.table) { MonitorExport.tcpConnections(connections, format: $0) }
                    }
                    .disabled(connections.isEmpty)
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

/// Network use per process on the whole host (nettop, the TCP counters, nethogs, or socket
/// counts), streamed while the card is shown. The list stays calm: ordered by what each process
/// moved since the card opened (or by name, or by speed now), quiet processes fade out after a
/// minute, and Pause holds what is shown.
struct ProcessTrafficCard: View {
    let monitor: RemoteMonitor
    @State private var expanded: Set<Int> = []
    @AppStorage("trafficSort") private var sort = Sort.total
    @State private var filter = ""
    @State private var frozen: [ProcessTrafficEntry]?

    enum Sort: String, CaseIterable, Identifiable {
        case total = "Total", now = "Now", name = "Name"
        var id: String { rawValue }
    }

    private var traffic: ProcessTraffic { monitor.traffic }

    private var rows: [ProcessTrafficEntry] {
        var list = frozen ?? traffic.entries
        if !filter.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(filter) || String($0.pid).hasPrefix(filter) }
        }
        switch sort {
        case .total: return list      // already ordered by total, which changes slowly
        case .now: return list.sorted { ($0.rate, $1.pid) > ($1.rate, $0.pid) }
        case .name: return list.sorted { ($0.name.lowercased(), $0.pid) < ($1.name.lowercased(), $1.pid) }
        }
    }

    var body: some View {
        Card(title: title) {
            VStack(alignment: .leading, spacing: 6) {
                if let message = traffic.message {
                    Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                suggestion
                switch traffic.source {
                case nil:
                    Text("Loading…").foregroundStyle(.secondary)
                case .unavailable(let why)?:
                    Text(why).foregroundStyle(.secondary)
                default:
                    controls
                    let list = rows
                    if list.isEmpty {
                        Text(filter.isEmpty ? (traffic.source?.hasRates == true ? "No traffic yet" : "No connections") : "No match")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(list.prefix(40)) { e in
                        if e.flows.isEmpty {
                            processRow(e)
                        } else {
                            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(e.pid) },
                                                                set: { if $0 { expanded.insert(e.pid) } else { expanded.remove(e.pid) } })) {
                                ConnectionRows(connections: e.flows, monitor: monitor, limit: 20)
                                    .padding(.leading, 4)
                            } label: {
                                processRow(e)
                            }
                            .help("Show the connections of \(e.name)")
                        }
                    }
                    if list.count > 40 {
                        Text("and \(list.count - 40) more — filter to find one").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .contextMenu {
            let entries = traffic.entries
            Button("Export Traffic by Process…") {
                ExportPanel.save(title: "Export Traffic by Process", baseName: "traffic by process", formats: MonitorExport.Format.table) { MonitorExport.traffic(entries, format: $0) }
            }
            .disabled(entries.isEmpty)
        }
        .onAppear { traffic.retain(interval: max(AppModel.shared.settings.trafficInterval, 1)) }
        .onDisappear { traffic.release() }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Sort", selection: $sort) {
                ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Total: data moved since this card opened (the steadiest order) · Now: current speed · Name")
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).controlSize(.small)
            Button {
                frozen = frozen == nil ? traffic.entries : nil
            } label: {
                Image(systemName: frozen == nil ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .help(frozen == nil ? "Pause: keep the list as it is now" : "Resume live updates")
            DiagnosticsButton(log: traffic.diagnostics) { traffic.clearDiagnostics() }
        }
    }

    /// What could be installed on the host for (better) traffic per process — a suggestion only.
    @ViewBuilder private var suggestion: some View {
        let isLinux = !(monitor.platform?.isWindows ?? false) && monitor.snapshot?.osInfo["id"] != "macos"
        let wanted: String? = switch traffic.source {
        case .connections?: "Speeds need ss (iproute2) with a Linux kernel 4.1 or later."
        case .tcp?: "For UDP and other users' processes too, nethogs can be used when it may run as root or with passwordless sudo."
        default: nil
        }
        if isLinux, let wanted {
            let command = ProcessTraffic.installSuggestion(osID: monitor.snapshot?.osInfo["id"])
            VStack(alignment: .leading, spacing: 4) {
                Text(wanted).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let command {
                    HStack(spacing: 6) {
                        Text(command).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2)
                        Button { CommandFormat.copy(command) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy — run it on the server yourself if you want it (Tether installs nothing)")
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
                }
            }
        }
    }

    private func processRow(_ e: ProcessTrafficEntry) -> some View {
        let quiet = e.rate == 0
        return HStack(spacing: 6) {
            Text(e.name.isEmpty ? "?" : e.name).lineLimit(1)
            Text(verbatim: String(e.pid)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).help("Process ID")
            Spacer(minLength: 4)
            if let c = e.connections {
                Text("\(c) connection\(c == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            } else {
                if e.history.count > 2 {
                    Sparkline(values: normalized(e.history), tint: .indigo, filled: false)
                        .frame(width: 40, height: 12)
                        .help("Speed over the last \(e.history.count) samples")
                }
                VStack(alignment: .trailing, spacing: 0) {
                    Text("↓ \((e.received ?? 0).rateString)  ↑ \((e.sent ?? 0).rateString)")
                        .help("Speed now: download ↓ and upload ↑ per second")
                    if e.total > 0 {
                        Text("\(Int64(e.total).byteString) total").foregroundStyle(.secondary)
                            .help("Moved since this card opened: ↓ \(Int64(e.totalReceived).byteString) ↑ \(Int64(e.totalSent).byteString)")
                    }
                }
                .font(.caption.monospacedDigit())
                .fixedSize()
            }
        }
        .font(.callout)
        .opacity(quiet && e.connections == nil ? 0.5 : 1)
    }

    private var title: String {
        switch traffic.source {
        case .nettop?: "Traffic by process (nettop)"
        case .nethogs?: "Traffic by process (nethogs)"
        case .tcp?: "Traffic by process (TCP)"
        case .connections?: "Connections by process"
        default: "Traffic by process"
        }
    }
}

/// What the server listens on and from where it can be reached.
struct ListeningCard: View {
    let sockets: [ListeningSocket]
    let forward: (ListeningSocket) -> Void

    var body: some View {
        Card(title: "Listening ports (\(sockets.count))", onExport: sockets.isEmpty ? nil : {
            let list = sockets
            ExportPanel.save(title: "Export Listening Ports", baseName: "listening ports", formats: MonitorExport.Format.table) { MonitorExport.listening(list, format: $0) }
        }) {
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
        .contextMenu {
            let list = sockets
            Button("Export Listening Ports…") {
                ExportPanel.save(title: "Export Listening Ports", baseName: "listening ports", formats: MonitorExport.Format.table) { MonitorExport.listening(list, format: $0) }
            }
            .disabled(list.isEmpty)
        }
    }

    private func row(_ s: ListeningSocket) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: String(s.port)).font(.callout.monospacedDigit().weight(.medium)).frame(width: 52, alignment: .leading)
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
                if monitor.platform?.isWindows == true {
                    EmptyStateView(symbol: "rectangle.stack", title: "Not Available on Windows",
                                   message: "Windows has no tmux or screen, so shells end when the connection drops. Recordings still keep their output.")
                } else {
                    EmptyStateView(symbol: "rectangle.stack", title: "No Persistent Sessions",
                                   message: "tmux or screen sessions created by Tether will appear here.")
                }
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
                let windows = entry.panes.filter(\.paneActive)
                ForEach(windows.prefix(6), id: \.windowIndex) { pane in
                    HStack(spacing: 4) {
                        Image(systemName: pane.windowActive ? "chevron.right.circle.fill" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(pane.windowActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                            .frame(width: 12)
                        Text("\(pane.windowIndex): \(pane.windowName)").font(.caption.monospaced())
                        PaneSummary(pane: pane)
                    }
                    .help(pane.summary)
                }
                if windows.count > 6 {
                    Text("+\(windows.count - 6) more").font(.caption2).foregroundStyle(.tertiary)
                }
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
                .glassButtonStyle()
            }
        }
        .contextMenu {
            Button("Kill Session", role: .destructive) { Task { await monitor.killRemoteSession(entry) } }
        }
    }
}
