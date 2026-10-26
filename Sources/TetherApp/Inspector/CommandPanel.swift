import SwiftUI
import TetherCore
import MonitorKit
import SessionKit

/// The host panel's Command tab: what runs in the terminal now, and the commands run before.
struct CommandPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let target: ConnectionTarget
    let monitor: RemoteMonitor
    @AppStorage("commandPanelMode") private var mode = Mode.now

    enum Mode: String, CaseIterable, Identifiable {
        case now = "Now", history = "History"
        var id: String { rawValue }
    }

    /// The terminal shown: the one selected in the sidebar, else the window's tab — on this host.
    private var session: TerminalSession? {
        if case .session(let id) = state.sidebarSelection, let s = model.sessions.session(id),
           s.descriptor.target.key == target.key { return s }
        if let s = state.session, s.descriptor.target.key == target.key { return s }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)
            switch mode {
            case .now:
                if let session {
                    if let sampler = model.commandSamplers[session.id] {
                        RunningCommandView(session: session, sampler: sampler, monitor: monitor)
                            .id(session.id)
                    } else {
                        // Created outside the view update (it changes the model).
                        ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                            .task(id: session.id) { model.watchCommands(in: session) }
                    }
                } else {
                    EmptyStateView(symbol: "terminal", title: "No Terminal",
                                   message: "Open a terminal to \(target.displayName) to see what runs in it.")
                }
            case .history:
                CommandHistoryView(target: target, session: session)
            }
        }
    }
}

/// What runs in one terminal right now: the program, its time, usage and processes.
struct RunningCommandView: View {
    @Environment(AppModel.self) private var model
    let session: TerminalSession
    let sampler: CommandSampler
    let monitor: RemoteMonitor
    /// The signal and the command it was asked for (not whatever runs when it is confirmed).
    @State private var pendingSignal: (signal: String, pid: Int, name: String, processes: [CommandProcess], shell: Int?)?
    @State private var error: String?

    private var frame: CommandFrame? { sampler.frame }
    private var cores: Int { max(monitor.snapshot?.cpuCount ?? 1, 1) }
    private var isWindows: Bool { monitor.platform?.isWindows ?? false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !sampler.diagnostics.isEmpty {
                    HStack {
                        Spacer()
                        DiagnosticsButton(log: sampler.diagnostics) { sampler.clearDiagnostics() }
                    }
                }
                switch sampler.status {
                case .running:
                    if let frame, let leader = frame.leader { running(frame, leader) }
                case .idle:
                    note("The shell is waiting for a command", symbol: "terminal",
                         "Run something in the terminal to see its PID, time, CPU, memory and network use here.")
                case .waiting:
                    if session.phase.isOnline {
                        HStack { ProgressView().controlSize(.small); Text("Looking at the terminal…").foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        note("The terminal is not connected", symbol: "bolt.horizontal",
                             "A command that keeps running on the server is followed again after reconnecting.")
                    }
                case .unsupported(let why):
                    note("Not available for this terminal", symbol: "questionmark.circle", why)
                case .unreachable(let why):
                    note("The host did not answer", symbol: "exclamationmark.triangle", why)
                }
            }
            .padding(12)
        }
        .onAppear { sampler.watch() }
        .onDisappear { sampler.unwatch() }
        .confirmationDialog("Send \(pendingSignal?.signal ?? "") to \(pendingSignal?.name ?? "") (PID \(pendingSignal.map { String($0.pid) } ?? ""))?",
                            isPresented: Binding(get: { pendingSignal != nil }, set: { if !$0 { pendingSignal = nil } })) {
            Button("Send \(pendingSignal?.signal ?? "")", role: .destructive) {
                if let p = pendingSignal { send(p.signal, to: p.processes, shell: p.shell) }
            }
        } message: {
            Text(frame?.leader?.pid == pendingSignal?.pid ? frame?.leader?.commandLine ?? "" : "This process is no longer the one in front.")
        }
    }

    @ViewBuilder
    private func running(_ frame: CommandFrame, _ leader: CommandProcess) -> some View {
        let latest = sampler.latest
        let record = sampler.record
        CommandHeader(leader: leader, shellPid: frame.shellPid)
        actions(leader)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            MetricTile(title: "CPU", value: min((latest?.cpu ?? 0) / Double(100 * cores), 1),
                       detail: summary(record?.cpu) { CommandFormat.percent($0) },
                       tint: .blue, series: CommandFormat.cpuSeries(sampler.samples),
                       valueText: latest?.cpu.map(CommandFormat.percent) ?? "—")
            MetricTile(title: "Memory", value: memoryFraction(latest?.memory),
                       detail: summary(record?.memory, low: true) { Int64($0).byteString },
                       tint: .purple, series: normalized(sampler.samples.map { Double($0.memory ?? 0) }),
                       valueText: latest?.memory.map(\.byteString) ?? "—")
            if latest?.received != nil || latest?.sent != nil {
                MetricTile(title: "Network ↓ \((latest?.received ?? 0).rateString)", value: 0,
                           detail: "↑ \((latest?.sent ?? 0).rateString)" + total(record?.receivedBytes, record?.sentBytes),
                           tint: .indigo, series: normalized(sampler.samples.map { ($0.received ?? 0) + ($0.sent ?? 0) }), valueText: "")
            }
            if latest?.read != nil || latest?.written != nil {
                MetricTile(title: "Disk read \((latest?.read ?? 0).rateString)", value: 0,
                           detail: "write \((latest?.written ?? 0).rateString)" + total(record?.readBytes, record?.writtenBytes),
                           tint: .orange, series: normalized(sampler.samples.map { ($0.read ?? 0) + ($0.written ?? 0) }), valueText: "")
            }
            MetricTile(title: "Processes", value: 0,
                       detail: latest?.threads.map { "\($0) thread\($0 == 1 ? "" : "s")" } ?? "",
                       tint: .teal, series: normalized(sampler.samples.map { Double($0.processes) }),
                       valueText: String(frame.processes.count))
        }
        if latest?.received == nil && latest?.sent == nil {
            NetworkSourceNote(isWindows: isWindows)
        }
        ProcessTreeCard(processes: frame.processes, cpu: sampler.processCPU)
        if !sampler.connections.isEmpty {
            Card(title: "Network connections (\(sampler.connections.count))") {
                ConnectionRows(connections: sampler.connections, monitor: monitor, showProcess: frame.processes.count > 1)
            }
            .contextMenu {
                let list = sampler.connections
                Button("Export Connections…") {
                    ExportPanel.save(title: "Export Connections", baseName: "\(leader.name) connections", formats: MonitorExport.Format.table) { MonitorExport.connections(list, format: $0) }
                }
                Button("Copy as CSV") { CommandFormat.copy(String(decoding: MonitorExport.connections(list), as: UTF8.self)) }
            }
        }
        GPUUseCard(monitor: monitor, pids: Set(frame.processes.map(\.pid)))
        if let error { Text(error).uiFont(.caption).foregroundStyle(.red) }
    }

    private func actions(_ leader: CommandProcess) -> some View {
        HStack {
            Button {
                session.send(Array("\u{03}".utf8)[...])
            } label: { Label("Interrupt", systemImage: "stop.circle") }
            .help("Send Control-C to the terminal")
            Button { ask("TERM", leader) } label: { Label("Terminate", systemImage: "xmark.circle") }
                .help("Ask \(leader.name) (PID \(leader.pid)) and everything it started to quit")
            Button(role: .destructive) { ask("KILL", leader) } label: { Label("Kill", systemImage: "xmark.octagon") }
                .help("End \(leader.name) (PID \(leader.pid)) and everything it started at once")
            Spacer()
        }
        .controlSize(.small)
        .disabled(!session.phase.isOnline)
    }

    private func ask(_ signal: String, _ leader: CommandProcess) {
        let processes = frame?.processes ?? [leader]
        if model.settings.confirmKill { pendingSignal = (signal, leader.pid, leader.name, processes, frame?.shellPid) }
        else { send(signal, to: processes, shell: frame?.shellPid) }
    }

    /// The whole command: its process group and every process in it, so nothing it started lives on.
    private func send(_ signal: String, to processes: [CommandProcess], shell: Int?) {
        Task { error = await monitor.stopCommand(processes, shellPid: shell, signal: signal) }
    }

    private func memoryFraction(_ bytes: Int64?) -> Double {
        guard let bytes, let total = monitor.snapshot?.memTotal, total > 0 else { return 0 }
        return min(Double(bytes) / Double(total), 1)
    }

    /// "avg 12% · peak 80%" (with "min" first for memory).
    private func summary(_ m: MetricSummary?, low: Bool = false, _ format: (Double) -> String) -> String {
        guard let m, m.samples > 1 else { return "" }
        return (low ? "min \(format(m.min)) · " : "") + "avg \(format(m.mean)) · peak \(format(m.max))"
    }

    private func total(_ a: Double?, _ b: Double?) -> String {
        guard a != nil || b != nil else { return "" }
        return " · \(Int64((a ?? 0) + (b ?? 0)).byteString) total"
    }

    private func note(_ title: String, symbol: String, _ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).uiFont(.title).foregroundStyle(.secondary)
            Text(title).uiFont(.headline)
            Text(message).uiFont(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .padding(.horizontal)
    }
}

/// The program, its command line, PID, user and how long it has been running.
struct CommandHeader: View {
    let leader: CommandProcess
    let shellPid: Int?

    var body: some View {
        Card(title: "Running") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(leader.name).uiFont(.title3, weight: .semibold).lineLimit(1)
                    Spacer()
                    if let started = leader.started {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(context.date.timeIntervalSince(started).clockString)
                                .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                        }
                        .help("Running since \(started.formatted(date: .abbreviated, time: .standard))")
                    }
                }
                Text(leader.commandLine.isEmpty ? leader.name : leader.commandLine)
                    .uiFont(.callout, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                HStack(spacing: 12) {
                    Label("PID " + String(leader.pid), systemImage: "number")
                    if leader.user != "-" { Label(leader.user, systemImage: "person").help("User running it") }
                    if leader.state != "-" {
                        Label(CommandFormat.state(leader.state), systemImage: "circle.dotted").help("Process state (\(leader.state))")
                    }
                    if let shellPid { Text("shell " + String(shellPid)).foregroundStyle(.tertiary).help("Process ID of the terminal's shell") }
                }
                .uiFont(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            }
        }
        .contextMenu {
            Button("Copy Command") { CommandFormat.copy(leader.commandLine) }
            Button("Copy PID") { CommandFormat.copy(String(leader.pid)) }
        }
    }
}

/// The command's processes as a tree, with CPU and memory of each.
struct ProcessTreeCard: View {
    let processes: [CommandProcess]
    let cpu: [Int: Double]

    var body: some View {
        let depth = depths()
        Card(title: "Processes (\(processes.count))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(processes.prefix(60)) { p in
                    HStack(spacing: 6) {
                        Text(verbatim: String(p.pid)).monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                        Text(p.name).lineLimit(1)
                            .padding(.leading, CGFloat(min(depth[p.pid] ?? 0, 6)) * 10)
                            .help(p.commandLine)
                        Spacer(minLength: 4)
                        Text(cpu[p.pid].map(CommandFormat.percent) ?? "").monospacedDigit().foregroundStyle(.secondary)
                        Text(p.rssBytes?.byteString ?? "").monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                    .uiFont(.callout)
                    .contextMenu {
                        Button("Copy Command") { CommandFormat.copy(p.commandLine) }
                        Button("Copy PID") { CommandFormat.copy(String(p.pid)) }
                    }
                }
                if processes.count > 60 {
                    Text("and \(processes.count - 60) more").uiFont(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Steps below the command's first process.
    private func depths() -> [Int: Int] {
        var result: [Int: Int] = [:]
        for p in processes { result[p.pid] = result[p.ppid].map { $0 + 1 } ?? 0 }
        return result
    }
}

/// GPU memory the command's processes use (hosts with NVIDIA GPUs).
struct GPUUseCard: View {
    let monitor: RemoteMonitor
    let pids: Set<Int>

    var body: some View {
        let mine = monitor.gpuProcesses.filter { pids.contains($0.pid) }
        Group {
            if !mine.isEmpty {
                Card(title: "GPU") {
                    ForEach(mine) { g in
                        HStack {
                            Text(g.gpu).foregroundStyle(.secondary).lineLimit(1)
                            Text(g.name).lineLimit(1)
                            Spacer()
                            Text(g.memoryUsed?.byteString ?? "—").monospacedDigit()
                        }
                        .uiFont(.callout)
                    }
                }
            }
        }
        .task(id: monitor.snapshot?.gpus.isEmpty == false) {
            guard monitor.snapshot?.gpus.isEmpty == false else { return }
            while !Task.isCancelled {
                await monitor.refreshGPUProcesses()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// Why no network rates are shown for the command.
struct NetworkSourceNote: View {
    let isWindows: Bool

    var body: some View {
        Label(isWindows ? "Windows does not report network traffic per process without administrator tools."
                        : "No network use measured yet. Linux counts TCP per socket (ss, kernel 4.1 or later); UDP is not counted.",
              systemImage: "info.circle")
            .uiFont(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Formatting shared by the command views.
enum CommandFormat {
    static func percent(_ v: Double) -> String {
        v >= 10 || v == 0 ? "\(Int(v.rounded()))%" : String(format: "%.1f%%", v)
    }

    /// CPU readings scaled for a sparkline (one full core = the top, more cores go beyond).
    static func cpuSeries(_ samples: [CommandSample]) -> [Double] {
        let values = samples.map { $0.cpu ?? 0 }
        let top = max(values.max() ?? 0, 100)
        return values.map { $0 / top }
    }

    static func state(_ s: String) -> String {
        switch s.first {
        case "R": "running"
        case "S", "I": "sleeping"
        case "D": "waiting for I/O"
        case "T", "t": "stopped"
        case "Z": "zombie"
        default: s
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
