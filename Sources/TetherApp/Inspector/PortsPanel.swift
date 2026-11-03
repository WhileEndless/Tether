import SwiftUI
import TetherCore
import SessionKit
import MonitorKit
import SSHConfigKit

/// Port forwards for a host: saved ones with on/off switches that say what they do, quick forwards
/// for ports the server listens on, and forwards defined in ssh config (read-only).
struct PortsPanel: View {
    @Environment(AppModel.self) private var model
    let target: ConnectionTarget
    let monitor: RemoteMonitor
    @State private var editing: Editing?

    /// The editor's subject: a new forward for a purpose, or a saved one.
    struct Editing: Identifiable {
        let id = UUID()
        var draft: ForwardDraft
        var original: PortForward?
    }

    private var saved: [PortForward] { model.metadata(for: target.key).forwards ?? [] }
    private var server: String { target.displayName }

    var body: some View {
        List {
            Section {
                if saved.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No port forwards yet. What do you want to do?")
                            .uiFont(.callout).foregroundStyle(.secondary)
                        ForEach([ForwardDraft.Purpose.serverPort, .otherMachine, .toThisMac], id: \.self) { purpose in
                            Button { add(purpose) } label: {
                                Label(purpose.title(server: server), systemImage: Self.icon(purpose))
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 4)
                }
                ForEach(saved) { f in
                    ForwardRow(forward: f, target: target, onEdit: { editing = Editing(draft: ForwardDraft(f), original: f) },
                               onUsePort: { port in usePort(port, for: f) })
                }
            } header: {
                HStack {
                    Text("Forwards")
                    Spacer()
                    Menu {
                        ForEach(ForwardDraft.Purpose.allCases) { purpose in
                            Button { add(purpose) } label: { Label(purpose.title(server: server), systemImage: Self.icon(purpose)) }
                        }
                    } label: { Label("Forward a Port…", systemImage: "plus") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Add a port forward and start it")
                }
            }

            listeningSection

            let configured = configForwards
            if !configured.isEmpty {
                Section {
                    ForEach(configured, id: \.self) { Text($0).uiFont(.callout, design: .monospaced) }
                } header: {
                    Text("From SSH config")
                } footer: {
                    Text("These are opened by ssh itself when the shared connection starts.")
                }
            }
        }
        .task { await monitor.refreshListeningPorts() }
        .refreshable { await monitor.refreshListeningPorts() }
        .sheet(item: $editing) { e in
            ForwardEditor(draft: e.draft, isNew: e.original == nil, server: server, running: e.original.map { runs($0) } ?? false) { result in
                save(result, replacing: e.original)
            }
            .appLockCover()
        }
    }

    @ViewBuilder private var listeningSection: some View {
        let tcp = monitor.listeningPorts.filter { $0.proto == "tcp" }
        if !tcp.isEmpty {
            Section("Listening on the server") {
                ForEach(tcp) { p in
                    HStack {
                        Text(verbatim: String(p.port)).uiFont(.callout).monospacedDigit().frame(width: 56, alignment: .leading)
                        Text([p.container.map { "🐳 \($0)" }, p.process.isEmpty ? nil : p.process, p.address]
                                .compactMap { $0 }.joined(separator: " · "))
                            .uiFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        if let f = existingForward(for: p) {
                            let status = model.forwards.status(of: f)
                            if status == .active {
                                Text(verbatim: "→ localhost:\(f.listenPort)").uiFont(.caption).foregroundStyle(.green)
                                Button { ForwardRow.openInBrowser(f) } label: { Image(systemName: "safari") }
                                    .buttonStyle(.borderless)
                                    .help("Open localhost:\(f.listenPort) in the browser")
                            } else if status == .starting {
                                Text("Starting…").uiFont(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("Turn On") { Task { await model.forwards.start(f, on: target) } }
                                    .buttonStyle(.borderless)
                                    .help("Start the saved forward: \(f.sentence(server: server))")
                            }
                        } else {
                            Button("Forward") { model.quickForward(target, port: p.port, address: p.address) }
                                .buttonStyle(.borderless)
                                .help("Open port \(p.port) of \(server) on this Mac (the same number when it is free) and start it")
                        }
                    }
                }
            }
        } else if !model.isEnabled(.monitoring, for: target) {
            Section("Listening on the server") {
                Text(model.isDevice(target)
                     ? "Tether reads nothing on a network device. Use Forward a Port… with the port number."
                     : "Turn on monitoring to see the ports the server listens on, or use Forward a Port… with the port number.")
                    .uiFont(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The saved forward that already opens this listening port on this Mac.
    private func existingForward(for p: ListeningSocket) -> PortForward? {
        let host = AppModel.quickForwardDestination(p.address)
        return saved.first { $0.kind == .local && $0.destinationPort == p.port && $0.destinationHost == host }
    }

    static func icon(_ purpose: ForwardDraft.Purpose) -> String {
        switch purpose {
        case .serverPort: "arrow.down.left.circle"
        case .otherMachine: "point.3.connected.trianglepath.dotted"
        case .toThisMac: "arrow.up.right.circle"
        case .socks: "globe"
        }
    }

    private var configForwards: [String] {
        guard case .alias(let a) = target, let e = model.config.entry(for: a) else { return [] }
        return e.options.filter { ["localforward", "remoteforward", "dynamicforward"].contains($0.key.lowercased()) }
            .map { "\($0.key) \($0.value)" }
    }

    private func runs(_ f: PortForward) -> Bool {
        let s = model.forwards.status(of: f)
        return s == .active || s == .starting
    }

    private func add(_ purpose: ForwardDraft.Purpose) {
        editing = Editing(draft: ForwardDraft(purpose: purpose), original: nil)
    }

    /// Saves `f`; a new one starts at once, and one that ran is made again with its new values.
    private func save(_ f: PortForward, replacing original: PortForward?) {
        let wasRunning = original.map { runs($0) } ?? false
        model.updateMetadata(for: target.key) { m in
            var list = m.forwards ?? []
            if let i = list.firstIndex(where: { $0.id == f.id }) { list[i] = f } else { list.append(f) }
            m.forwards = list
        }
        let target = target
        let forwards = model.forwards
        Task {
            if let original, wasRunning { await forwards.stop(original) }
            if original == nil || wasRunning { await forwards.start(f, on: target) }
        }
    }

    /// A failed forward's port was in use: saved with the free one, and started.
    private func usePort(_ port: Int, for f: PortForward) {
        var changed = f
        changed.listenPort = port
        save(changed, replacing: nil)
    }
}

private struct ForwardRow: View {
    @Environment(AppModel.self) private var model
    let forward: PortForward
    let target: ConnectionTarget
    let onEdit: () -> Void
    let onUsePort: (Int) -> Void

    var body: some View {
        let status = model.forwards.status(of: forward)
        let waiting = model.forwards.isWaiting(forward)
        let server = target.displayName
        let on = status == .active || status == .starting || waiting
        HStack(alignment: .top, spacing: 10) {
            Toggle(on ? "On" : "Off", isOn: Binding(get: { on }, set: { want in
                Task { if want { await model.forwards.start(forward, on: target) } else { await model.forwards.stop(forward) } }
            }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel(on ? "Port forward on" : "Port forward off")
            .help(on ? "On: click to stop it" : "Off: click to start it")
            VStack(alignment: .leading, spacing: 3) {
                Text(forward.label.isEmpty ? forward.sentence(server: server) : forward.label)
                    .lineLimit(2)
                if !forward.label.isEmpty {
                    Text(forward.sentence(server: server)).uiFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                state(status, waiting: waiting, server: server)
                if forward.autoStart {
                    Label("Starts when \(server) connects", systemImage: "bolt.fill")
                        .uiFont(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if status == .active, forward.kind == .local {
                Button { Self.openInBrowser(forward) } label: { Image(systemName: "safari") }
                    .buttonStyle(.borderless)
                    .help("Open localhost:\(forward.listenPort) in the browser")
            }
            Menu {
                Button("Edit…", action: onEdit)
                if forward.kind != .remote {
                    Button("Copy Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("localhost:\(forward.listenPort)", forType: .string)
                    }
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

    /// The state in words, coloured, with what can be done about a failure.
    @ViewBuilder private func state(_ status: ForwardManager.Status, waiting: Bool, server: String) -> some View {
        if waiting {
            Label("Waiting for \(server) — starts again by itself when it connects", systemImage: "clock")
                .uiFont(.caption).foregroundStyle(.orange)
        } else {
            switch status {
            case .inactive:
                Text(forward.offMeaning(server: server)).uiFont(.caption).foregroundStyle(.secondary)
            case .starting:
                Text("Starting…").uiFont(.caption).foregroundStyle(.secondary)
            case .active:
                Text("On").uiFont(.caption).foregroundStyle(.green)
            case .failed(let msg):
                VStack(alignment: .leading, spacing: 3) {
                    Label(msg, systemImage: "exclamationmark.triangle.fill").uiFont(.caption).foregroundStyle(.red).lineLimit(3)
                    HStack(spacing: 10) {
                        Button("Try Again") { Task { await model.forwards.start(forward, on: target) } }
                        if forward.listensLocally, !LocalPorts.isFree(forward.listenPort, address: forward.bindAddress),
                           let free = LocalPorts.nextFree(from: forward.listenPort + 1, address: forward.bindAddress) {
                            Button("Use Port \(String(free))") { onUsePort(free) }
                        }
                    }
                    .buttonStyle(.borderless)
                    .uiFont(.caption)
                }
            }
        }
    }

    static func openInBrowser(_ forward: PortForward) {
        let scheme = [443, 8443].contains(forward.destinationPort) ? "https" : "http"
        if let url = URL(string: "\(scheme)://localhost:\(forward.listenPort)") { NSWorkspace.shared.open(url) }
    }
}

/// Adds or edits a forward in plain words: what to do, the ports, and what will happen.
private struct ForwardEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: ForwardDraft
    let isNew: Bool
    let server: String
    /// The forward being edited runs now (its own port is in use by itself).
    let running: Bool
    let onSave: (PortForward) -> Void
    @State private var showsAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Picker("What do you want to do?", selection: $draft.purpose) {
                    ForEach(ForwardDraft.Purpose.allCases) { Text($0.title(server: server)).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: draft.purpose) { _, _ in
                    draft.listenFollowsTarget = draft.purpose == .serverPort || draft.purpose == .otherMachine
                    followTarget()
                }

                Section {
                    fields
                }

                Section {
                    Toggle(draft.purpose == .toThisMac ? "Other machines on \(server)’s network can use it"
                                                       : "Other devices on my network can use it", isOn: $draft.openToNetwork)
                        .disabled(draft.customBind != nil)
                    if draft.openToNetwork {
                        Text(draft.purpose == .toThisMac
                             ? "The server must allow it (sshd’s GatewayPorts); otherwise only the server itself can connect."
                             : "Anyone who can reach this Mac can then use the port — only on networks you trust.")
                            .uiFont(.caption).foregroundStyle(.orange)
                    }
                    Toggle("Start automatically when \(server) connects", isOn: $draft.autoStart)
                    TextField("Name", text: $draft.label, prompt: Text("Optional, e.g. Web app"))
                    DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                        TextField("Bind address", text: Binding(get: { draft.customBind ?? "" },
                                                                set: { draft.customBind = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }),
                                  prompt: Text(draft.openToNetwork ? "All addresses" : "Loopback only"))
                    }
                }

                Section {
                    summary
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add and Start" : (running ? "Save and Restart" : "Save")) {
                    if let f = draft.forward { onSave(f); dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .prominentGlassButtonStyle()
                .disabled(draft.forward == nil)
            }
            .padding()
        }
        .frame(width: 520, height: 600)
        .onAppear { showsAdvanced = draft.customBind != nil }
    }

    @ViewBuilder private var fields: some View {
        switch draft.purpose {
        case .serverPort:
            portField("Port on \(server)", text: $draft.targetPort, prompt: "e.g. 8090", target: true)
            portField("Port on this Mac", text: $draft.listenPort, prompt: "the same when free", target: false)
        case .otherMachine:
            TextField("Machine", text: $draft.targetHost, prompt: Text("Name or address as \(server) sees it, e.g. 192.0.2.10"))
            portField("Its port", text: $draft.targetPort, prompt: "e.g. 5432", target: true)
            portField("Port on this Mac", text: $draft.listenPort, prompt: "the same when free", target: false)
        case .toThisMac:
            portField("Port to open on \(server)", text: $draft.listenPort, prompt: "e.g. 9000", target: false)
            TextField("Machine", text: $draft.targetHost, prompt: Text("This Mac, or a name or address on its network"))
            portField("Its port", text: $draft.targetPort, prompt: "e.g. 3000", target: true)
        case .socks:
            portField("Port on this Mac", text: $draft.listenPort, prompt: "e.g. 1080", target: false)
        }
    }

    private func portField(_ title: String, text: Binding<String>, prompt: String, target: Bool) -> some View {
        TextField(title, text: Binding(get: { text.wrappedValue }, set: { value in
            text.wrappedValue = value.filter(\.isNumber)
            if target { followTarget() } else { draft.listenPortEdited() }
        }), prompt: Text(prompt))
        .monospacedDigit()
    }

    private func followTarget() {
        let bind = draft.bindAddress
        draft.targetPortChanged { wanted in
            LocalPorts.isFree(wanted, address: bind) ? wanted : LocalPorts.nextFree(from: wanted + 1, address: bind)
        }
    }

    /// What will happen, or what is missing; and a port taken on this Mac, with a free one.
    @ViewBuilder private var summary: some View {
        if let problem = draft.problem {
            Label(problem, systemImage: "info.circle").uiFont(.callout).foregroundStyle(.secondary)
        } else if let f = draft.forward {
            Label(f.sentence(server: server), systemImage: "arrow.right.circle.fill").uiFont(.callout)
            if f.listensLocally, !running, !LocalPorts.isFree(f.listenPort, address: f.bindAddress) {
                HStack {
                    Label("Port \(String(f.listenPort)) is in use on this Mac.", systemImage: "exclamationmark.triangle.fill")
                        .uiFont(.caption).foregroundStyle(.orange)
                    if let free = LocalPorts.nextFree(from: f.listenPort + 1, address: f.bindAddress) {
                        Button("Use \(String(free))") { draft.listenPort = String(free); draft.listenPortEdited() }
                            .controlSize(.small)
                    }
                }
            } else if f.listenPort < 1024, !f.bindAddress.isEmpty, f.listensLocally {
                Label("Ports below 1024 need administrator rights on macOS.", systemImage: "exclamationmark.triangle.fill")
                    .uiFont(.caption).foregroundStyle(.orange)
            } else if draft.listenFollowsTarget, let wanted = Int(draft.targetPort), String(wanted) != draft.listenPort, f.listensLocally {
                Text(wanted < 1024 ? "Port \(String(wanted)) is below 1024: \(String(f.listenPort)) is used on this Mac instead."
                                   : "Port \(String(wanted)) is in use on this Mac: \(String(f.listenPort)) is used instead.")
                    .uiFont(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
