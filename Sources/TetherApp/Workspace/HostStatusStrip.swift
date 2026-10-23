import SwiftUI
import TetherCore
import SessionKit
import MonitorKit

/// A thin live bar above the terminal: CPU, memory, disk, load, network, GPU and latency.
/// It adapts to the width (full → compact → essentials) instead of truncating labels.
/// Clicking an item opens the matching tab of the host panel.
struct HostStatusStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let session: TerminalSession

    private enum Density { case full, compact, minimal }

    /// The bar's width, measured once per resize. Picking the density from it (instead of
    /// ViewThatFits) means each update lays out one row, not three.
    @State private var width: CGFloat = 1000

    private var density: Density {
        width >= 920 ? .full : width >= 620 ? .compact : .minimal
    }

    var body: some View {
        let monitor = model.monitor(for: session.descriptor.target)
        Group {
            if let s = monitor.snapshot {
                // The row is an overlay of a flexible, empty container: the container's width is
                // measured, and the row can never change it (no layout feedback loop).
                Color.clear
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width = $0 }
                    .overlay(alignment: .leading) { row(s, monitor, density) }
                    .clipped()
            } else {
                HStack {
                    Label(monitor.error == nil ? "Loading host status…" : "Host status unavailable",
                          systemImage: "gauge.with.dots.needle.0percent")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .buttonStyle(.plain)
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .onAppear { monitor.retain(interval: model.settings.monitorRefreshInterval) }
        .onDisappear { monitor.release() }
        .task(id: session.phase.isOnline) {
            // Learn about other tmux sessions on the server once we are connected.
            if session.phase.isOnline {
                await monitor.refreshRemoteSessions()
                model.checkKeyLogin(session.descriptor.target)
            }
        }
    }

    private func row(_ s: SystemSnapshot, _ monitor: RemoteMonitor, _ density: Density) -> some View {
        HStack(spacing: density == .full ? 14 : 10) {
            meter("CPU", "cpu", s.cpuUsage, tab: .processes, density)
            meter("Memory", "memorychip", s.memFraction, tab: .overview, density)
            if density != .minimal {
                if let root = s.disks.first(where: { $0.mount == "/" }) ?? s.disks.first {
                    meter("Disk", "internaldrive", root.fraction, tab: .overview, density)
                }
                if let load = s.load.first {
                    Button { open(.overview) } label: {
                        item(density == .full ? "Load" : nil, "chart.line.uptrend.xyaxis", String(format: "%.2f", load))
                    }
                    .help("Load average (1 min)")
                }
                if let net = s.networkRates {
                    Button { open(.overview) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down").foregroundStyle(.blue)
                            Text(net.rx.rateString)
                            Image(systemName: "arrow.up").foregroundStyle(.orange)
                            Text(net.tx.rateString)
                        }
                        .fixedSize()
                    }
                    .help("Network traffic on the server (download / upload)")
                }
                ForEach(s.gpus) { g in
                    meter("GPU\(s.gpus.count > 1 ? " \(g.index)" : "")", "rectangle.3.group", g.utilization, tab: .gpu, density,
                          extra: density == .full ? g.temperature.map { " \(Int($0))°" } : nil)
                }
            }
            Spacer(minLength: 8)
            let forwards = model.forwards.activeCount(for: session.descriptor.target)
            if forwards > 0 && density != .minimal {
                Button { open(.ports) } label: { item(nil, "arrow.left.arrow.right.circle.fill", "\(forwards)") }
                    .foregroundStyle(.green)
                    .help("\(forwards) active port forward\(forwards == 1 ? "" : "s")")
            }
            latency(monitor, density)
        }
    }

    // MARK: Pieces

    private func item(_ title: String?, _ symbol: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            if let title { Text(title).foregroundStyle(.secondary) }
            Text(value)
        }
        .fixedSize()
    }

    private func meter(_ title: String, _ symbol: String, _ value: Double?, tab: InspectorTab, _ density: Density,
                       extra: String? = nil) -> some View {
        let v = value ?? 0
        return Button { open(tab) } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                if density == .full { Text(title).foregroundStyle(.secondary) }
                if density != .minimal {
                    Capsule().fill(.quaternary)
                        .frame(width: 30, height: 5)
                        .overlay(alignment: .leading) {
                            Capsule().fill(color(v)).frame(width: 30 * min(max(v, 0), 1), height: 5)
                        }
                }
                Text((value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—") + (extra ?? ""))
            }
            .fixedSize()
        }
        .help("\(title) — show in host panel")
    }

    @ViewBuilder
    private func latency(_ monitor: RemoteMonitor, _ density: Density) -> some View {
        let stats = model.latency(for: session.descriptor.target) ?? (session.latency.samples.isEmpty ? nil : session.latency)
        if let median = stats?.median ?? monitor.commandLatency {
            let quality = stats?.quality ?? .good
            Button { open(.overview) } label: {
                HStack(spacing: 4) {
                    Circle().fill(LatencyBadge(stats: stats).color(quality)).frame(width: 7, height: 7)
                    if density == .full { Text("Latency").foregroundStyle(.secondary) }
                    Text(LatencyStats.format(median))
                }
                .fixedSize()
            }
            .help("Latency (round-trip time) \(LatencyStats.format(median)) · \(quality.rawValue)"
                  + (stats?.jitter.map { " · jitter ±\(LatencyStats.format($0))" } ?? ""))
        }
    }

    private func color(_ v: Double) -> Color { v > 0.9 ? .red : v > 0.75 ? .orange : .green }

    private func open(_ tab: InspectorTab) {
        state.sidebarSelection = .session(session.id)
        state.inspectorTab = tab
        state.showInspectorRequest = true
    }
}
