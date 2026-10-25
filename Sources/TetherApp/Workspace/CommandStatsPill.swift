import SwiftUI
import MonitorKit
import SessionKit

/// The command running in a terminal, in the bar below it: name, running time, PID, CPU, memory
/// and network. Shown only while something other than the shell runs; a click opens the details.
struct CommandStatsPill: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let session: TerminalSession

    var body: some View {
        if model.settings.showCommandStats, let sampler = model.commandSamplers[session.id],
           sampler.status == .running, let leader = sampler.frame?.leader {
            Button {
                state.showRunningCommand(session)
            } label: {
                ViewThatFits(in: .horizontal) {
                    content(leader, sampler, full: true)
                    content(leader, sampler, full: false)
                    Image(systemName: "play.circle.fill").foregroundStyle(.green)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Running command \(leader.name), click for details")
        }
    }

    private func content(_ leader: CommandProcess, _ sampler: CommandSampler, full: Bool) -> some View {
        let s = sampler.latest
        return HStack(spacing: 6) {
            Image(systemName: "play.circle.fill").foregroundStyle(.green)
            Text(leader.name).fontWeight(.medium).lineLimit(1)
                .help("Running command: \(leader.commandLine.isEmpty ? leader.name : leader.commandLine)")
            if let started = leader.started {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date.timeIntervalSince(started).clockString).monospacedDigit()
                }
                .help("Running for this long (since \(started.formatted(date: .omitted, time: .standard)))")
            }
            if full {
                item("PID", String(leader.pid), help: "Process ID of \(leader.name) on the host")
                if let cpu = s?.cpu {
                    item("CPU", CommandFormat.percent(cpu), help: "CPU use of the command and the processes it started (100% = one core)")
                }
                if let memory = s?.memory {
                    item("RAM", memory.byteString, help: "Memory in use (resident) by the command and its processes")
                }
                if let rx = s?.received, let tx = s?.sent, rx + tx >= 1 {
                    item("Net", "↓\(rx.rateString) ↑\(tx.rateString)", help: "Network: download ↓ and upload ↑ per second")
                }
                if sampler.samples.count > 2 {
                    Sparkline(values: CommandFormat.cpuSeries(sampler.samples), tint: .green, filled: false)
                        .frame(width: 36, height: 12)
                        .help("CPU over the last \(sampler.samples.count) readings")
                }
            }
        }
        .fixedSize()
    }

    /// "CPU 37%": a dim label before its value, with what it means on hover.
    private func item(_ label: String, _ value: String, help: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .help(help)
    }
}
