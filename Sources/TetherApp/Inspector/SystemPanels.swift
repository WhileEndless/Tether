import SwiftUI
import MonitorKit

/// GPUs and the processes using them.
struct GPUPanel: View {
    let monitor: RemoteMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(monitor.snapshot?.gpus ?? []) { GPUCard(gpu: $0) }
                Card(title: "Processes using the GPU", onExport: {
                    let gpus = monitor.snapshot?.gpus ?? []
                    let processes = monitor.gpuProcesses
                    ExportPanel.save(title: "Export GPUs", baseName: "gpus", formats: MonitorExport.Format.table) { MonitorExport.gpus(gpus, processes: processes, format: $0) }
                }) {
                    if monitor.gpuProcesses.isEmpty {
                        Text("None").foregroundStyle(.secondary)
                    }
                    ForEach(monitor.gpuProcesses) { p in
                        HStack {
                            Text(verbatim: String(p.pid)).uiFont(.callout).monospacedDigit().frame(width: 60, alignment: .leading)
                            Text((p.name as NSString).lastPathComponent).lineLimit(1).help(p.name)
                            Spacer()
                            Text(p.memoryUsed?.byteString ?? "—").uiFont(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
            .contextMenu {
                let gpus = monitor.snapshot?.gpus ?? []
                let processes = monitor.gpuProcesses
                Button("Export GPUs and Their Processes…") {
                    ExportPanel.save(title: "Export GPUs", baseName: "gpus", formats: MonitorExport.Format.table) { MonitorExport.gpus(gpus, processes: processes, format: $0) }
                }
                .disabled(gpus.isEmpty && processes.isEmpty)
            }
        }
        .task {
            while !Task.isCancelled {
                await monitor.refreshGPUProcesses()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// systemd services with start/stop/restart and logs.
struct ServicesPanel: View {
    enum Filter: String, CaseIterable, Identifiable {
        case running = "Running", failed = "Failed", all = "All"
        var id: String { rawValue }
    }

    let monitor: RemoteMonitor
    @State private var filter: Filter = .running
    @State private var search = ""
    @State private var message: String?
    @State private var logs: (unit: String, text: String)?

    private var rows: [ServiceEntry] {
        monitor.services.filter { s in
            let f: Bool = switch filter {
            case .running: s.isRunning
            case .failed: s.isFailed
            case .all: true
            }
            return f && (search.isEmpty || s.name.localizedCaseInsensitiveContains(search)
                         || s.description.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { f in
                        let n = count(f)
                        Text(n > 0 ? "\(f.rawValue) \(n)" : f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack {
                    TextField("Filter services", text: $search).textFieldStyle(.roundedBorder)
                    Button { Task { await monitor.refreshServices() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                    Button {
                        let shown = rows
                        ExportPanel.save(title: "Export Services", baseName: "services", formats: MonitorExport.Format.table) { MonitorExport.services(shown, format: $0) }
                    } label: { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(.borderless)
                        .disabled(rows.isEmpty)
                        .help("Export the services shown as CSV")
                }
                if let message {
                    Text(message).uiFont(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            List(rows) { s in
                HStack(spacing: 8) {
                    Circle().fill(s.isFailed ? .red : s.isRunning ? .green : .secondary.opacity(0.5)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name.replacingOccurrences(of: ".service", with: "")).lineLimit(1)
                        Text(s.description.isEmpty ? "\(s.active) · \(s.sub)" : s.description)
                            .uiFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Menu {
                        Button("Restart") { act("restart", s) }
                        Button(s.isRunning ? "Stop" : "Start") { act(s.isRunning ? "stop" : "start", s) }
                        Divider()
                        Button("Show Logs") {
                            Task { logs = (s.name, await monitor.serviceLogs(s.name, lines: 300)) }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .overlay {
                if monitor.services.isEmpty {
                    EmptyStateView(symbol: "gearshape.2", title: "No Services", message: "systemd was not found or is not readable.")
                }
            }
        }
        .task { await monitor.refreshServices() }
        .sheet(isPresented: Binding(get: { logs != nil }, set: { if !$0 { logs = nil } })) {
            LogSheet(title: logs?.unit ?? "", text: logs?.text ?? "")
        }
    }

    private func count(_ f: Filter) -> Int {
        switch f {
        case .running: monitor.services.filter(\.isRunning).count
        case .failed: monitor.services.filter(\.isFailed).count
        case .all: monitor.services.count
        }
    }

    private func act(_ action: String, _ s: ServiceEntry) {
        Task {
            let err = await monitor.service(action, s.name)
            withAnimation { message = err }
        }
    }
}

/// Docker / Podman containers.
struct ContainersPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let monitor: RemoteMonitor

    private func forward(_ m: PortMapping) {
        guard let port = m.hostPort, let target = state.inspectedTarget else { return }
        model.quickForward(target, port: port, address: m.hostAddress)
    }
    @State private var logs: (name: String, text: String)?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(monitor.containers.filter(\.isRunning).count) running · \(monitor.containers.count) total")
                    .uiFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await monitor.refreshContainers() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                Button {
                    let list = monitor.containers
                    ExportPanel.save(title: "Export Containers", baseName: "containers", formats: MonitorExport.Format.table) { MonitorExport.containers(list, format: $0) }
                } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless)
                    .disabled(monitor.containers.isEmpty)
                    .help("Export the containers as CSV")
            }
            .padding(10)
            if let message {
                Text(message).uiFont(.caption).foregroundStyle(.red).padding(.horizontal, 10)
            }
            List(monitor.containers) { c in
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox.fill").foregroundStyle(c.isRunning ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.name).lineLimit(1)
                        Text("\(c.image) · \(c.status)").uiFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if !c.portMappings.isEmpty {
                            PortChips(container: c, forward: forward)
                        }
                    }
                    Spacer()
                    Menu {
                        Button(c.isRunning ? "Stop" : "Start") { act(c.isRunning ? "stop" : "start", c) }
                        Button("Restart") { act("restart", c) }
                        Divider()
                        Button("Show Logs") {
                            Task {
                                let r = await monitor.container("logs", c)
                                logs = (c.name, r.output)
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .overlay {
                if monitor.containers.isEmpty {
                    EmptyStateView(symbol: "shippingbox", title: "No Containers",
                                   message: "Docker or Podman was not found, or you are not allowed to use it.")
                }
            }
        }
        .task { await monitor.refreshContainers() }
        .sheet(isPresented: Binding(get: { logs != nil }, set: { if !$0 { logs = nil } })) {
            LogSheet(title: logs?.name ?? "", text: logs?.text ?? "")
        }
    }

    private func act(_ action: String, _ c: ContainerEntry) {
        Task {
            let r = await monitor.container(action, c)
            withAnimation { message = r.ok ? nil : r.output.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }
}

/// Published ports of a container: "3000 → 3000/tcp" with how it is exposed and a forward button.
private struct PortChips: View {
    let container: ContainerEntry
    let forward: (PortMapping) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(container.portMappings) { m in
                HStack(spacing: 3) {
                    Image(systemName: m.exposure == .allInterfaces ? "globe" : m.exposure == .localOnly ? "lock" : "network")
                        .foregroundStyle(m.exposure == .allInterfaces ? .orange : .secondary)
                    Text(verbatim: m.hostPort.map { "\(String($0)) → \(String(m.containerPort))/\(m.proto)" } ?? "\(String(m.containerPort))/\(m.proto) (not published)")
                    if m.isPublished && m.proto == "tcp" && container.isRunning {
                        Button { forward(m) } label: { Image(systemName: "arrow.left.arrow.right.circle") }
                            .buttonStyle(.borderless)
                            .help("Forward to this Mac")
                    }
                }
                .uiFont(.caption2, design: .monospaced)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(.quaternary))
            }
        }
    }
}

struct LogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).uiFont(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            ScrollView([.vertical, .horizontal]) {
                Text(text.isEmpty ? "No output." : text)
                    .uiFont(size: 11, design: .monospaced)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(width: 760, height: 520)
        .appLockCover()
    }
}
