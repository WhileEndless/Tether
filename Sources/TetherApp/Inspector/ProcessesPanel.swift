import SwiftUI
import MonitorKit

struct ProcessesPanel: View {
    @Environment(AppModel.self) private var model
    let monitor: RemoteMonitor
    @State private var search = ""
    @State private var sort = [KeyPathComparator(\ProcessEntry.cpu, order: .reverse)]
    @State private var selection = Set<Int>()
    @State private var pendingSignal: (pids: [Int], signal: String)?
    @State private var error: String?

    private var rows: [ProcessEntry] {
        let filtered = search.isEmpty ? monitor.processes : monitor.processes.filter {
            $0.command.localizedCaseInsensitiveContains(search) || $0.user.localizedCaseInsensitiveContains(search)
                || String($0.pid).hasPrefix(search)
        }
        return filtered.sorted(using: sort)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter processes", text: $search).textFieldStyle(.roundedBorder)
                Button { Task { await monitor.refreshProcesses() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                Menu {
                    Button("Terminate (TERM)") { askSignal("TERM") }
                    Button("Kill (KILL)", role: .destructive) { askSignal("KILL") }
                    Button("Hang Up (HUP)") { askSignal("HUP") }
                    Button("Interrupt (INT)") { askSignal("INT") }
                } label: {
                    Image(systemName: "xmark.octagon")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(selection.isEmpty)
                .help("Send a signal to the selected processes")
            }
            .padding(10)

            Table(rows, selection: $selection, sortOrder: $sort) {
                TableColumn("PID", value: \.pid) { Text(verbatim: String($0.pid)).monospacedDigit() }.width(min: 44, ideal: 56)
                TableColumn("Name", value: \.name) { p in Text(p.name).help(p.command) }.width(min: 80, ideal: 140)
                TableColumn("CPU %", value: \.cpu) { Text(String(format: "%.1f", $0.cpu)).monospacedDigit() }.width(min: 44, ideal: 54)
                TableColumn("Mem %", value: \.mem) { Text(String(format: "%.1f", $0.mem)).monospacedDigit() }.width(min: 44, ideal: 54)
                TableColumn("User", value: \.user).width(min: 50, ideal: 70)
                TableColumn("Time", value: \.elapsed).width(min: 50, ideal: 70)
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                Button("Terminate") { pendingSignal = (Array(ids), "TERM") }
                Button("Kill", role: .destructive) { pendingSignal = (Array(ids), "KILL") }
                Divider()
                Button("Copy PID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ids.map(String.init).joined(separator: " "), forType: .string)
                }
                Button("Copy Command") {
                    let cmds = monitor.processes.filter { ids.contains($0.pid) }.map(\.command)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmds.joined(separator: "\n"), forType: .string)
                }
            }
            HStack {
                Text("\(monitor.processes.count) processes").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(1) }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .confirmationDialog("Send \(pendingSignal?.signal ?? "") to \(pendingSignal?.pids.count ?? 0) process(es)?",
                            isPresented: Binding(get: { pendingSignal != nil }, set: { if !$0 { pendingSignal = nil } })) {
            Button("Send \(pendingSignal?.signal ?? "")", role: .destructive) {
                if let p = pendingSignal { send(p.pids, p.signal) }
            }
        } message: {
            Text(monitor.processes.filter { pendingSignal?.pids.contains($0.pid) ?? false }.map(\.command).prefix(3).joined(separator: "\n"))
        }
        .task {
            while !Task.isCancelled {
                await monitor.refreshProcesses()
                try? await Task.sleep(for: .seconds(max(model.settings.monitorRefreshInterval, 3)))
            }
        }
    }

    private func askSignal(_ signal: String) {
        if model.settings.confirmKill { pendingSignal = (Array(selection), signal) } else { send(Array(selection), signal) }
    }

    private func send(_ pids: [Int], _ signal: String) {
        Task {
            var errors: [String] = []
            for pid in pids {
                if let e = await monitor.signal(pid, signal: signal) { errors.append(e) }
            }
            withAnimation { error = errors.first }
        }
    }
}
