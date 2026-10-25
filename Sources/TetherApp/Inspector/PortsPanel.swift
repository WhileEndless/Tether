import SwiftUI
import TetherCore
import SessionKit
import MonitorKit
import SSHConfigKit

/// Port forwards for a host: saved ones with on/off switches, quick forwards for ports the server
/// listens on, and forwards defined in ssh config (read-only).
struct PortsPanel: View {
    @Environment(AppModel.self) private var model
    let target: ConnectionTarget
    let monitor: RemoteMonitor
    @State private var editing: PortForward?
    @State private var isNew = false

    private var saved: [PortForward] { model.metadata(for: target.key).forwards ?? [] }

    var body: some View {
        List {
            Section {
                if saved.isEmpty {
                    Text("No forwards yet. Add one, or forward a port the server listens on below.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(saved) { f in ForwardRow(forward: f, target: target, onEdit: { isNew = false; editing = f }) }
            } header: {
                HStack {
                    Text("Forwards")
                    Spacer()
                    Button {
                        isNew = true
                        editing = PortForward(listenPort: LocalPorts.nextFree(from: 8080) ?? 8080, destinationPort: 80)
                    } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.borderless)
                }
            }

            if !monitor.listeningPorts.isEmpty {
                Section("Listening on the server") {
                    ForEach(monitor.listeningPorts.filter { $0.proto == "tcp" }) { p in
                        HStack {
                            Text(verbatim: String(p.port)).font(.callout.monospacedDigit()).frame(width: 56, alignment: .leading)
                            Text([p.container.map { "🐳 \($0)" }, p.process.isEmpty ? nil : p.process, p.address]
                                    .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button("Forward") { model.quickForward(target, port: p.port, address: p.address) }
                                .buttonStyle(.borderless)
                                .disabled(saved.contains { $0.kind == .local && $0.destinationPort == p.port })
                        }
                    }
                }
            }

            let configured = configForwards
            if !configured.isEmpty {
                Section {
                    ForEach(configured, id: \.self) { Text($0).font(.callout.monospaced()) }
                } header: {
                    Text("From SSH config")
                } footer: {
                    Text("These are opened by ssh itself when the shared connection starts.")
                }
            }
        }
        .task { await monitor.refreshListeningPorts() }
        .refreshable { await monitor.refreshListeningPorts() }
        .sheet(item: $editing) { f in
            ForwardEditor(forward: f, isNew: isNew) { result in save(result) }.appLockCover()
        }
    }

    private var configForwards: [String] {
        guard case .alias(let a) = target, let e = model.config.entry(for: a) else { return [] }
        return e.options.filter { ["localforward", "remoteforward", "dynamicforward"].contains($0.key.lowercased()) }
            .map { "\($0.key) \($0.value)" }
    }

    private func save(_ f: PortForward) {
        model.updateMetadata(for: target.key) { m in
            var list = m.forwards ?? []
            if let i = list.firstIndex(where: { $0.id == f.id }) { list[i] = f } else { list.append(f) }
            m.forwards = list
        }
    }
}

private struct ForwardRow: View {
    @Environment(AppModel.self) private var model
    let forward: PortForward
    let target: ConnectionTarget
    let onEdit: () -> Void

    var body: some View {
        let status = model.forwards.status(of: forward)
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { status == .active || status == .starting }, set: { on in
                Task { if on { await model.forwards.start(forward, on: target) } else { await model.forwards.stop(forward) } }
            }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(forward.label.isEmpty ? forward.summary : forward.label).lineLimit(1)
                    if forward.autoStart {
                        Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.yellow).help("Starts automatically")
                    }
                }
                switch status {
                case .failed(let msg): Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
                case .starting: Text("Starting…").font(.caption).foregroundStyle(.secondary)
                case .active: Text(forward.label.isEmpty ? "Active" : forward.summary).font(.caption).foregroundStyle(.green)
                case .inactive: Text(forward.kind.title).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if status == .active, forward.kind == .local {
                Button {
                    let scheme = [443, 8443].contains(forward.destinationPort) ? "https" : "http"
                    if let url = URL(string: "\(scheme)://localhost:\(forward.listenPort)") { NSWorkspace.shared.open(url) }
                } label: { Image(systemName: "safari") }
                .buttonStyle(.borderless)
                .help("Open in browser")
            }
            Menu {
                Button("Edit…", action: onEdit)
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("localhost:\(forward.listenPort)", forType: .string)
                }
                Divider()
                Button("Delete", role: .destructive) {
                    Task { await model.forwards.stop(forward) }
                    model.updateMetadata(for: target.key) { $0.forwards?.removeAll { $0.id == forward.id } }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .animation(.snappy, value: status)
    }
}

private struct ForwardEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var forward: PortForward
    let isNew: Bool
    let onSave: (PortForward) -> Void
    @State private var listen = ""
    @State private var destPort = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Type", selection: $forward.kind) {
                    ForEach(PortForward.Kind.allCases) { Text($0.title).tag($0) }
                }
                TextField("Name", text: $forward.label, prompt: Text("Optional, e.g. Postgres"))
                TextField(forward.kind == .remote ? "Port on the server" : "Port on this Mac", text: $listen)
                if forward.kind != .dynamic {
                    TextField(forward.kind == .remote ? "Destination (seen from this Mac)" : "Destination (seen from the server)",
                              text: $forward.destinationHost, prompt: Text("localhost"))
                    TextField("Destination port", text: $destPort)
                }
                TextField("Bind address", text: $forward.bindAddress, prompt: Text("Default (loopback only)"))
                Toggle("Start automatically when connected", isOn: $forward.autoStart)
                Text(explanation).font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    forward.listenPort = Int(listen) ?? forward.listenPort
                    forward.destinationPort = Int(destPort) ?? forward.destinationPort
                    if forward.destinationHost.isEmpty { forward.destinationHost = "localhost" }
                    onSave(forward)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .prominentGlassButtonStyle()
                .disabled(!(1...65535 ~= (Int(listen) ?? 0)) || (forward.kind != .dynamic && !(1...65535 ~= (Int(destPort) ?? 0))))
            }
            .padding()
        }
        .frame(width: 460, height: 440)
        .onAppear {
            listen = String(forward.listenPort)
            destPort = String(forward.destinationPort)
        }
    }

    private var explanation: String {
        switch forward.kind {
        case .local: "Connections to localhost:\(listen) on this Mac reach \(forward.destinationHost):\(destPort) through the server."
        case .remote: "Connections to port \(listen) on the server reach \(forward.destinationHost):\(destPort) through this Mac."
        case .dynamic: "A SOCKS5 proxy on localhost:\(listen). Point a browser or tool at it to browse through the server."
        }
    }
}
