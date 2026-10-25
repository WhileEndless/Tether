import SwiftUI
import TetherCore
import MonitorKit
import SessionKit

/// Commands run in Tether's terminals: how long they ran and how much they used.
struct CommandHistoryView: View {
    @Environment(AppModel.self) private var model
    let target: ConnectionTarget
    let session: TerminalSession?
    @AppStorage("commandHistoryScope") private var scope = Scope.host
    @State private var search = ""
    @State private var expanded: UUID?
    @State private var confirmClear = false

    enum Scope: String, CaseIterable, Identifiable {
        case tab = "This Tab", host = "This Host", all = "All Hosts"
        var id: String { rawValue }
    }

    private var history: CommandHistoryStore { model.commandHistory }

    private var rows: [CommandRecord] {
        let list: [CommandRecord]
        switch scope {
        case .tab: list = session.map { history.records(sessionID: $0.id) } ?? []
        case .host: list = history.records(hostKey: target.key)
        case .all: list = history.records()
        }
        guard !search.isEmpty else { return list }
        return list.filter { $0.commandLine.localizedCaseInsensitiveContains(search) || $0.hostName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        let list = rows   // filtered once per update
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                TextField("Filter commands", text: $search).textFieldStyle(.roundedBorder)
                DiagnosticsButton(log: history.diagnostics) { history.clearDiagnostics() }
                Menu {
                    Button("Export \(list.count) Command\(list.count == 1 ? "" : "s")…") { export(list) }
                        .disabled(list.isEmpty)
                    Divider()
                    Button("Clear \(scope == .all ? "All History" : "History of \(target.displayName)")…", role: .destructive) {
                        confirmClear = true
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .help("Export or clear the commands listed")
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            if !model.settings.keepCommandHistory {
                Label("Command history is turned off in Settings ▸ Monitoring.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 6)
            }
            if history.isLocked {
                Label("Some history is encrypted: unlock Tether to see it.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 6)
            }
            if list.isEmpty {
                EmptyStateView(symbol: "clock.arrow.circlepath", title: "No Commands Yet",
                               message: "Commands that run for a few seconds or longer in Tether's terminals are listed here with their time and usage.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(list) { r in
                            CommandRecordRow(record: r, showHost: scope == .all, expanded: expanded == r.id)
                                .contentShape(Rectangle())
                                .onTapGesture { withAnimation(.smooth) { expanded = expanded == r.id ? nil : r.id } }
                                .contextMenu {
                                    Button("Copy Command") { CommandFormat.copy(r.commandLine) }
                                    Button("Export This Command…") { export([r]) }
                                    if !r.isRunning {
                                        Button("Delete", role: .destructive) { history.delete([r.id]) }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
        }
        .confirmationDialog(scope == .all ? "Clear the whole command history?" : "Clear the command history of \(target.displayName)?",
                            isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { history.clear(hostKey: scope == .all ? nil : target.key) }
        } message: {
            Text("Commands still running are kept. This cannot be undone.")
        }
    }
}

extension CommandHistoryView {
    /// The commands listed (scope and filter applied), as CSV or JSON.
    func export(_ records: [CommandRecord]) {
        let base = scope == .all ? "tether-command-history" : "tether-command-history \(target.displayName)"
        ExportPanel.save(title: "Export Command History", baseName: base, formats: MonitorExport.Format.allCases) { format in
            MonitorExport.history(records, format: format)
        }
    }
}

/// One command: name, when, how long, and its usage; tapped open, every min / average / peak.
struct CommandRecordRow: View {
    let record: CommandRecord
    let showHost: Bool
    let expanded: Bool

    var body: some View {
        let r = record
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                statusIcon
                Text(r.name).fontWeight(.medium).lineLimit(1)
                if showHost { Text(r.hostName).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                duration
            }
            Text(r.commandLine).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(expanded ? 6 : 1)
                .textSelection(.enabled)
            HStack(spacing: 10) {
                Text(r.started.formatted(date: .abbreviated, time: .shortened))
                if r.short == true {
                    Text("short — ended before it was measured").help("Seen by the watcher: command line and duration only")
                }
                if let cpu = r.cpu { Text("CPU avg \(CommandFormat.percent(cpu.mean)) · peak \(CommandFormat.percent(cpu.max))") }
                if let mem = r.memory { Text("Mem peak \(Int64(mem.max).byteString)") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if expanded { details }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(expanded ? 0.7 : 0.4)))
    }

    @ViewBuilder private var duration: some View {
        if record.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date.timeIntervalSince(record.started).clockString)
            }
            .font(.callout.monospacedDigit().weight(.medium))
            .foregroundStyle(.green)
        } else {
            Text(record.duration.clockString).font(.callout.monospacedDigit())
        }
    }

    private var statusIcon: some View {
        let (symbol, color, help): (String, Color, String) = switch record.status {
        case .running: ("play.circle.fill", .green, "Running")
        case .finished: ("checkmark.circle", .secondary, "Finished")
        case .endedWhileDisconnected: ("bolt.horizontal.circle", .orange, "Ended while the terminal was disconnected")
        case .trackingStopped: ("questionmark.circle", .secondary, "No longer followed: its terminal was closed")
        }
        return Image(systemName: symbol).foregroundStyle(color).help(help)
    }

    @ViewBuilder private var details: some View {
        let r = record
        Divider()
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("").gridColumnAlignment(.leading)
                Text("min").foregroundStyle(.secondary)
                Text("average").foregroundStyle(.secondary)
                Text("peak").foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
            metric("CPU", r.cpu, CommandFormat.percent)
            metric("Memory", r.memory) { Int64($0).byteString }
            metric("Threads", r.threads) { "\(Int($0.rounded()))" }
            metric("Processes", r.processes) { "\(Int($0.rounded()))" }
            metric("Download", r.received) { $0.rateString }
            metric("Upload", r.sent) { $0.rateString }
            metric("Disk read", r.read) { $0.rateString }
            metric("Disk write", r.written) { $0.rateString }
        }
        .font(.caption.monospacedDigit())
        if r.series.count > 2 {
            let cpu = r.series.map { $0.cpu ?? 0 }
            let mem = r.series.map { $0.memory ?? 0 }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CPU").font(.caption2).foregroundStyle(.secondary)
                    Sparkline(values: cpu.map { $0 / max(cpu.max() ?? 0, 100) }, tint: .blue, filled: true).frame(height: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory").font(.caption2).foregroundStyle(.secondary)
                    Sparkline(values: normalized(mem), tint: .purple, filled: true).frame(height: 28)
                }
            }
        }
        if let list = r.processList, !list.isEmpty { processes(list, dropped: r.droppedProcesses ?? 0) }
        if let list = r.connectionList, !list.isEmpty { connections(list, more: r.moreConnections == true) }
        VStack(alignment: .leading, spacing: 2) {
            if let total = transferred { Text(total) }
            Text("PID " + String(r.pid) + " · " + r.sessionTitle)
            Text(endText)
            if r.disconnectedSeconds > 0 {
                Text("Disconnected for \(r.disconnectedSeconds.uptimeString) while it ran (no readings then)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func processes(_ list: [ProcessSummary], dropped: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Processes (\(list.count + dropped))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(list.prefix(20)) { p in
                HStack(spacing: 6) {
                    Text(p.name).lineLimit(1).help(p.commandLine)
                    Text(String(p.pid)).foregroundStyle(.secondary).help("Process ID")
                    Spacer(minLength: 4)
                    Text(p.lastSeen.timeIntervalSince(p.started ?? p.firstSeen).clockString).foregroundStyle(.secondary)
                        .help("How long it was seen running")
                    if let cpu = p.cpu {
                        Text("CPU \(CommandFormat.percent(cpu.mean))/\(CommandFormat.percent(cpu.max))").help("CPU average / peak")
                    }
                    if let mem = p.memoryPeak { Text("RAM \(Int64(mem).byteString)").help("Peak memory") }
                }
                .font(.caption.monospacedDigit())
            }
            if list.count > 20 || dropped > 0 {
                Text("and \(list.count - min(list.count, 20) + dropped) more (export as JSON for every kept one)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func connections(_ list: [ConnectionSummary], more: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Connections (\(list.count)\(more ? "+" : ""))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(list.prefix(20)) { c in
                HStack(spacing: 6) {
                    Text(c.proto).foregroundStyle(.secondary)
                    Text(c.peer).lineLimit(1).textSelection(.enabled)
                    if let service = c.service { Text(service).foregroundStyle(.secondary) }
                    Spacer(minLength: 4)
                    Text(c.processName).foregroundStyle(.secondary).lineLimit(1)
                    if c.receivedBytes != nil || c.sentBytes != nil {
                        Text("↓\(Int64(c.receivedBytes ?? 0).byteString) ↑\(Int64(c.sentBytes ?? 0).byteString)")
                            .help("Bytes moved over this connection" + (c.peakReceived.map { ", peak ↓ \($0.rateString)" } ?? ""))
                    }
                }
                .font(.caption.monospacedDigit())
            }
            if list.count > 20 || more {
                Text("more connections were open (export as JSON for every kept one)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var transferred: String? {
        let r = record
        var parts: [String] = []
        if r.receivedBytes != nil || r.sentBytes != nil {
            parts.append("↓ \(Int64(r.receivedBytes ?? 0).byteString) ↑ \(Int64(r.sentBytes ?? 0).byteString)")
        }
        if r.readBytes != nil || r.writtenBytes != nil {
            parts.append("disk read \(Int64(r.readBytes ?? 0).byteString), written \(Int64(r.writtenBytes ?? 0).byteString)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var endText: String {
        let r = record
        let start = "Started \(r.started.formatted(date: .abbreviated, time: .standard))"
        switch r.status {
        case .running:
            return start + " · last seen \(r.lastSeen.formatted(date: .omitted, time: .standard))"
        case .finished:
            return start + " · ended \((r.ended ?? r.lastSeen).formatted(date: .omitted, time: .standard))"
        case .endedWhileDisconnected:
            let before = r.endedBefore.map { " and \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            return start + " · ended between \(r.lastSeen.formatted(date: .abbreviated, time: .shortened))\(before)"
        case .trackingStopped:
            return start + " · last seen \(r.lastSeen.formatted(date: .abbreviated, time: .standard))"
        }
    }

    @ViewBuilder
    private func metric(_ title: String, _ m: MetricSummary?, _ format: @escaping (Double) -> String) -> some View {
        if let m {
            GridRow {
                Text(title).foregroundStyle(.secondary)
                Text(format(m.min))
                Text(format(m.mean))
                Text(format(m.max))
            }
        }
    }
}
