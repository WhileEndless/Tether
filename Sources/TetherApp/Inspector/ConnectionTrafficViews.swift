import SwiftUI
import MonitorKit

/// Connections of a process or command: where each goes, its state and speed. A click shows the
/// details (the peer's host name as the server resolves it, the service, bytes moved). Used by the
/// Command tab and by Traffic by Process, so both read the same.
struct ConnectionRows: View {
    let connections: [ConnectionTraffic]
    let monitor: RemoteMonitor
    var showProcess = false
    var limit = 40

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(connections.prefix(limit)) { c in
                ConnectionRow(connection: c, monitor: monitor, showProcess: showProcess)
            }
            if connections.count > limit {
                Text("and \(connections.count - limit) more").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ConnectionRow: View {
    let connection: ConnectionTraffic
    let monitor: RemoteMonitor
    let showProcess: Bool
    @State private var showing = false

    var body: some View {
        let c = connection
        Button { showing.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(c.proto).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.monospaced()).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if c.received != nil || c.sent != nil {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("↓ \((c.received ?? 0).rateString)")
                        Text("↑ \((c.sent ?? 0).rateString)")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(c.rate > 0 ? .primary : .secondary)
                    .help("Speed of this connection: download ↓ and upload ↑ per second")
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .help("Click for details")
        .popover(isPresented: $showing, arrowEdge: .leading) {
            ConnectionDetail(connection: c, monitor: monitor)
        }
    }

    private var title: String {
        let c = connection
        if c.isListening { return "listening on \(c.local)" }
        if !c.isTCPorUDP { return c.peer == "*" ? "\(c.proto) socket" : c.peer }
        return c.peer
    }

    private var subtitle: String {
        let c = connection
        if !c.isTCPorUDP {
            return (c.state == "from command line" ? "target from the command line · " : "") + "\(c.processName) \(c.pid) · bytes not counted"
        }
        var parts: [String] = []
        if let service = ServicePorts.name(c.isListening ? c.localPort : c.peerPort) { parts.append(service) }
        if c.state != "-" { parts.append(c.state) }
        if showProcess || parts.isEmpty { parts.append("\(c.processName.isEmpty ? "PID" : c.processName) \(c.pid)") }
        return parts.joined(separator: " · ")
    }
}

/// Everything known about one connection.
struct ConnectionDetail: View {
    let connection: ConnectionTraffic
    let monitor: RemoteMonitor
    @State private var hostName: String?
    @State private var lookedUp = false

    var body: some View {
        let c = connection
        VStack(alignment: .leading, spacing: 10) {
            Text(c.isListening ? "Listening socket" : "Connection").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                row("Process", "\(c.processName.isEmpty ? "—" : c.processName) (PID \(c.pid))")
                row("Protocol", c.proto + (c.state == "-" ? "" : " · \(c.state)"))
                row("Local", c.local)
                if !c.isListening && c.peer != "*" {
                    row("Remote", c.peer)
                    if let service = ServicePorts.name(c.peerPort) { row("Service", "\(service) (port \(c.peerPort ?? 0))") }
                    row("Host name", lookedUp ? (hostName ?? "none (no reverse DNS on the server)") : "looking up…")
                } else if let service = ServicePorts.name(c.localPort) {
                    row("Service", service)
                }
                if c.received != nil || c.sent != nil {
                    row("Speed", "↓ \((c.received ?? 0).rateString)   ↑ \((c.sent ?? 0).rateString)")
                }
                if c.receivedBytes != nil || c.sentBytes != nil {
                    row("Transferred", "↓ \((c.receivedBytes ?? 0).byteString)   ↑ \((c.sentBytes ?? 0).byteString)")
                }
            }
            .font(.callout)
            if !c.isTCPorUDP {
                Text(c.state == "from command line"
                     ? "ICMP (ping and similar) uses no connection the system lists here; the target is read from the command line. Its bytes are not counted on any system."
                     : "ICMP and raw sockets (ping and similar) have no ports, and no system counts their bytes per process.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if c.received == nil && c.sent == nil && !c.isListening {
                Text("The server does not count bytes for this connection, so its speed is unknown.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Copy Remote Address") { CommandFormat.copy(c.peer) }.disabled(c.isListening)
                Button("Copy All") { CommandFormat.copy(summary) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 340)
        .task {
            guard !c.isListening else { return }
            // Asked on the server: it resolves the names of its own network.
            hostName = await monitor.hostName(of: c.peerHost)
            lookedUp = true
        }
    }

    private var summary: String {
        let c = connection
        return ["\(c.proto) \(c.state)", "local \(c.local)", "remote \(c.peer)", hostName.map { "name \($0)" },
                "process \(c.processName) (PID \(c.pid))"].compactMap { $0 }.joined(separator: "\n")
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(2)
        }
    }
}
