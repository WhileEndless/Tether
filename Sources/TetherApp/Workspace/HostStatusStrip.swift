import SwiftUI
import TetherCore
import SessionKit
import MonitorKit
import SSHTransport

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
                    let signIn = monitor.error?.hasPrefix(BackgroundSignIn.marker) == true
                    Label(monitor.error == nil ? "Loading host status…" : signIn ? "Sign in to see host status" : "Host status unavailable",
                          systemImage: signIn ? "lock" : "gauge.with.dots.needle.0percent")
                        .foregroundStyle(.secondary)
                        .help(monitor.error ?? "")
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
            // Learn about other tmux sessions on the server once we are connected, then keep the
            // list (and what runs in each session) fresh while the window is visible.
            if session.phase.isOnline {
                await monitor.refreshRemoteSessions()
                model.checkKeyLogin(session.descriptor.target)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { break }
                    if !monitor.paused { await monitor.refreshRemoteSessions(maxAge: 10) }
                }
            }
        }
    }

    private func row(_ s: SystemSnapshot, _ monitor: RemoteMonitor, _ density: Density) -> some View {
        HStack(spacing: density == .full ? 14 : 10) {
            meter("CPU", "CPU", s.cpuUsage, tab: .processes, density,
                  help: "CPU use of the whole server" + (s.cpuCount > 0 ? " (\(s.cpuCount) cores)" : "") + ". Click for its processes.")
            meter("Memory", "RAM", s.memFraction, tab: .overview, density,
                  help: "Memory (RAM) in use on the server: \(s.memUsed.byteString) of \(s.memTotal.byteString).")
            if density != .minimal {
                if let root = s.disks.first(where: { $0.mount == "/" }) ?? s.disks.first {
                    meter("Disk", "Disk", root.fraction, tab: .overview, density,
                          help: "Disk \(root.mount) in use, \((root.availableKB * 1024).byteString) free.")
                }
                if let load = s.load.first {
                    Button { open(.overview) } label: {
                        item("Load", "chart.line.uptrend.xyaxis", String(format: "%.2f", load))
                    }
                    .help("Load average over 1, 5 and 15 minutes: " + s.load.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: " ")
                          + (s.cpuCount > 0 ? " (\(s.cpuCount) cores: above \(s.cpuCount) means work is waiting)" : ""))
                }
                if let net = s.networkRates {
                    Button { open(.connections) } label: {
                        HStack(spacing: 4) {
                            if density == .full { Text("Net").foregroundStyle(.secondary) }
                            Image(systemName: "arrow.down").foregroundStyle(.blue)
                            Text(net.rx.rateString)
                            Image(systemName: "arrow.up").foregroundStyle(.orange)
                            Text(net.tx.rateString)
                        }
                        .fixedSize()
                    }
                    .help("Network traffic of the whole server: download ↓ \(net.rx.rateString), upload ↑ \(net.tx.rateString). Click for traffic by process.")
                }
                ForEach(s.gpus) { g in
                    let name = "GPU\(s.gpus.count > 1 ? " \(g.index)" : "")"
                    meter(name, name, g.utilization, tab: .gpu, density,
                          extra: density == .full ? g.temperature.map { " \(Int($0))°" } : nil,
                          help: "\(name) use (\(g.name))" + (g.temperature.map { ", \(Int($0)) °C" } ?? "") + ".")
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
            if let title { Text(title).foregroundStyle(.secondary) } else { Image(systemName: symbol).foregroundStyle(.secondary) }
            Text(value)
        }
        .fixedSize()
    }

    /// A labelled value with a small bar. The label stays (shortened when narrow), so every value
    /// says what it is; the tooltip explains it.
    private func meter(_ title: String, _ short: String, _ value: Double?, tab: InspectorTab, _ density: Density,
                       extra: String? = nil, help: String) -> some View {
        let v = value ?? 0
        return Button { open(tab) } label: {
            HStack(spacing: 4) {
                Text(density == .full ? title : short).foregroundStyle(.secondary)
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
        .help(help)
    }

    @ViewBuilder
    private func latency(_ monitor: RemoteMonitor, _ density: Density) -> some View {
        let stats = model.latency(for: session.descriptor.target) ?? (session.latency.samples.isEmpty ? nil : session.latency)
        if let median = stats?.median ?? monitor.commandLatency {
            let quality = stats?.quality ?? .good
            Button { open(.overview) } label: {
                HStack(spacing: 4) {
                    Circle().fill(LatencyBadge(stats: stats).color(quality)).frame(width: 7, height: 7)
                    if density != .minimal { Text(density == .full ? "Latency" : "Ping").foregroundStyle(.secondary) }
                    Text(LatencyStats.format(median))
                }
                .fixedSize()
            }
            .help("Latency: how long a round trip to the server takes, \(LatencyStats.format(median)) · \(quality.rawValue)"
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
