import SwiftUI
import TetherCore
import MonitorKit
import SessionKit
import SSHConfigKit

struct OverviewPanel: View {
    @Environment(AppModel.self) private var model
    let target: ConnectionTarget
    let monitor: RemoteMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ConnectionCard(target: target, monitor: monitor)
                if let s = monitor.snapshot {
                    MetricGrid(snapshot: s, history: monitor.history)
                    ForEach(s.gpus) { GPUCard(gpu: $0) }
                    if !s.interfaces.isEmpty { NetworkCard(interfaces: s.interfaces) }
                    DisksCard(disks: s.disks)
                    SystemCard(snapshot: s)
                } else if let error = monitor.error {
                    ErrorCard(message: error) { Task { await monitor.refresh(firstSample: true) } }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Collecting system information…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(12)
        }
    }
}

/// Where we are connected and how good the connection is.
struct ConnectionCard: View {
    @Environment(AppModel.self) private var model
    let target: ConnectionTarget
    let monitor: RemoteMonitor

    var body: some View {
        let entry: SSHHostEntry? = { if case .alias(let a) = target { model.config.entry(for: a) } else { nil } }()
        let conn = monitor.snapshot?.connection
        let latency = model.latency(for: target)
        Card(title: "Connection") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    LatencyBadge(stats: latency, fallback: monitor.commandLatency)
                    Spacer()
                    if let latency, latency.samples.count > 2 {
                        Sparkline(values: normalized(Array(latency.samples.suffix(40))), tint: .accentColor, filled: false)
                            .frame(width: 120, height: 26)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    row("Server", conn.flatMap { $0.serverAddress.isEmpty ? nil : "\($0.serverAddress):\($0.serverPort)" }
                        ?? hostDescription(entry))
                    row("User", entry?.user ?? userFromTarget ?? "default")
                    if let jump = entry?.proxyJump ?? jumpFromTarget { row("Via", jump) }
                    if let conn, !conn.clientAddress.isEmpty { row("You appear as", conn.clientAddress) }
                    if let conn, !conn.addresses.isEmpty { row("Addresses", conn.addresses.prefix(4).joined(separator: ", ")) }
                    if let conn, !conn.sshPorts.isEmpty { row("sshd ports", conn.sshPorts.joined(separator: ", ")) }
                    if let key = entry?.identityFiles.first { row("Key", (key as NSString).lastPathComponent) }
                }
                .font(.callout)
            }
        }
    }

    private var userFromTarget: String? { if case .adhoc(let u, _, _, _, _) = target { u } else { nil } }
    private var jumpFromTarget: String? { if case .adhoc(_, _, _, let j, _) = target { j } else { nil } }

    private func hostDescription(_ entry: SSHHostEntry?) -> String {
        switch target {
        case .local: localMachineName
        case .alias(let a): "\(entry?.hostName ?? a):\(entry?.port ?? 22)"
        case .adhoc(_, let h, let p, _, _): "\(h):\(p ?? 22)"
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// "23 ms · Good" with a coloured dot.
struct LatencyBadge: View {
    let stats: LatencyStats?
    var fallback: Double? = nil

    var body: some View {
        let quality = stats?.quality ?? (fallback == nil ? .unknown : .good)
        HStack(spacing: 6) {
            Circle().fill(color(quality)).frame(width: 8, height: 8)
            Text("Latency").font(.caption).foregroundStyle(.secondary)
            Text(LatencyStats.format(stats?.median ?? fallback))
                .font(.callout.monospacedDigit().weight(.semibold))
            if let j = stats?.jitter {
                Text("Jitter ±\(LatencyStats.format(j))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(quality.rawValue).font(.caption).foregroundStyle(color(quality))
        }
        .help("Latency: round-trip time to the server (median of recent samples). Jitter: how much it varies between samples — high jitter makes typing feel uneven.")
    }

    func color(_ q: LatencyStats.Quality) -> Color {
        switch q {
        case .excellent, .good: .green
        case .fair: .yellow
        case .poor: .orange
        case .lost: .red
        case .unknown: .secondary
        }
    }
}

/// Small metric tiles with sparklines.
struct MetricGrid: View {
    let snapshot: SystemSnapshot
    let history: [RemoteMonitor.Sample]

    var body: some View {
        let s = snapshot
        let root = s.disks.first { $0.mount == "/" } ?? s.disks.first
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            MetricTile(title: "CPU", value: s.cpuUsage ?? 0, detail: s.cpuCount > 0 ? "\(s.cpuCount) cores" : "",
                       tint: .blue, series: history.map(\.cpu))
            MetricTile(title: "Memory", value: s.memFraction, detail: "\(s.memUsed.byteString) / \(s.memTotal.byteString)",
                       tint: .purple, series: history.map(\.memory))
            // Windows has no load average.
            if !s.load.isEmpty {
                MetricTile(title: "Load", value: min((s.load.first ?? 0) / Double(max(s.cpuCount, 1)), 1),
                           detail: s.load.prefix(3).map { String(format: "%.2f", $0) }.joined(separator: "  "),
                           tint: .teal, series: [], valueText: String(format: "%.2f", s.load.first ?? 0))
            }
            if let root {
                MetricTile(title: "Disk \(root.mount)", value: root.fraction,
                           detail: "\((root.availableKB * 1024).byteString) free", tint: .orange, series: [])
            }
            if s.swapTotal > 0 {
                MetricTile(title: "Swap", value: s.swapFraction, detail: "\(s.swapUsed.byteString) / \(s.swapTotal.byteString)",
                           tint: .pink, series: [])
            }
            if let net = s.networkRates {
                MetricTile(title: "Network ↓ \(net.rx.rateString)", value: 0,
                           detail: "↑ \(net.tx.rateString)", tint: .indigo,
                           series: normalized(history.map { ($0.rx ?? 0) + ($0.tx ?? 0) }), valueText: "")
            }
            if !s.gpus.isEmpty {
                MetricTile(title: "GPU", value: s.gpus.compactMap(\.utilization).max() ?? 0,
                           detail: "\(s.gpus.count) device\(s.gpus.count == 1 ? "" : "s")",
                           tint: .green, series: history.compactMap(\.gpu))
            }
        }
    }
}

/// A light-weight line (and optional fill) for small history graphs. Much cheaper to redraw than a
/// chart, which matters because these update every few seconds in every window.
struct Sparkline: View {
    let values: [Double]   // 0…1
    let tint: Color
    var filled = false

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat(min(max(v, 0), 1))))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            if filled {
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: 0, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.3), tint.opacity(0.02)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            }
            ctx.stroke(line, with: .color(tint), lineWidth: 1.5)
        }
    }
}

/// Scales a series to 0…1 for a sparkline.
func normalized(_ values: [Double]) -> [Double] {
    let m = max(values.max() ?? 0, 1)
    return values.map { $0 / m }
}

/// Network interfaces: real ones first with live rates, virtual ones folded away.
struct NetworkCard: View {
    let interfaces: [NetworkInterface]
    @State private var showVirtual = false

    var body: some View {
        let real = interfaces.filter { $0.priority.0 == 0 }
        let virtual = interfaces.filter { $0.priority.0 != 0 }
        Card(title: "Network") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(real) { InterfaceRow(interface: $0) }
                if !virtual.isEmpty {
                    DisclosureGroup(isExpanded: $showVirtual) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(virtual) { InterfaceRow(interface: $0) }
                        }
                        .padding(.top, 6)
                    } label: {
                        Text("Virtual & loopback (\(virtual.count))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct InterfaceRow: View {
    let interface: NetworkInterface

    var body: some View {
        let i = interface
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(i.state == "down" ? Color.secondary : .green).frame(width: 6, height: 6)
                Text(i.name).font(.callout.weight(.medium))
                if let speed = i.speedMbps {
                    Text(speed >= 1000 ? "\(speed / 1000) Gb/s" : "\(speed) Mb/s").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Label(i.rxRate?.rateString ?? "—", systemImage: "arrow.down").foregroundStyle(.blue)
                Label(i.txRate?.rateString ?? "—", systemImage: "arrow.up").foregroundStyle(.orange)
            }
            .font(.caption.monospacedDigit())
            if !i.addresses.isEmpty || !i.mac.isEmpty {
                Text((i.addresses + (i.mac.isEmpty ? [] : [i.mac])).joined(separator: "  ·  "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Text("Total ↓ \(Int64(i.rxBytes).byteString)  ↑ \(Int64(i.txBytes).byteString)")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: Double
    let detail: String
    let tint: Color
    let series: [Double]
    var valueText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if valueText != "" {
                Text(valueText ?? "\(Int((value * 100).rounded()))%")
                    .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                    .foregroundStyle(value > 0.9 ? .red : value > 0.75 ? .orange : .primary)
                    .contentTransition(.numericText(value: value))
                }
            }
            if series.count > 1 {
                Sparkline(values: Array(series.suffix(60)), tint: tint, filled: true)
                    .frame(height: 30)
            } else {
                ProgressView(value: min(max(value, 0), 1)).tint(tint).frame(height: 30)
            }
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
        .animation(.smooth, value: value)
    }
}

struct GPUCard: View {
    let gpu: GPUInfo

    var body: some View {
        Card(title: "\(gpu.vendor.rawValue) GPU \(gpu.index)") {
            VStack(alignment: .leading, spacing: 8) {
                Text(gpu.name).font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 14) {
                    gauge("Util", gpu.utilization.map { "\(Int(($0 * 100).rounded()))%" }, gpu.utilization)
                    gauge("Memory", memoryText, gpu.memoryFraction)
                    gauge("Temp", gpu.temperature.map { "\(Int($0))°C" }, gpu.temperature.map { $0 / 100 })
                    gauge("Power", powerText, gpu.power.flatMap { p in gpu.powerLimit.map { p / $0 } })
                }
            }
        }
    }

    private var memoryText: String? {
        if let u = gpu.memoryUsed, let t = gpu.memoryTotal { return "\(u.byteString) / \(t.byteString)" }
        if let u = gpu.memoryUsed { return u.byteString }
        return "shared"
    }

    private var powerText: String? {
        guard let p = gpu.power else { return nil }
        if let l = gpu.powerLimit { return String(format: "%.0f / %.0f W", p, l) }
        return String(format: "%.1f W", p)
    }

    private func gauge(_ title: String, _ text: String?, _ fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(text ?? "—").font(.caption.monospacedDigit().weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            ProgressView(value: min(max(fraction ?? 0, 0), 1))
                .tint((fraction ?? 0) > 0.85 ? .red : .green)
                .opacity(fraction == nil ? 0.3 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DisksCard: View {
    let disks: [DiskUsage]
    var body: some View {
        Card(title: "Disks") {
            VStack(spacing: 10) {
                ForEach(disks) { d in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(d.mount).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("\((d.usedKB * 1024).byteString) / \((d.sizeKB * 1024).byteString)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ProgressView(value: d.fraction).tint(d.fraction > 0.9 ? .red : d.fraction > 0.75 ? .orange : .accentColor)
                    }
                }
            }
        }
    }
}

struct SystemCard: View {
    let snapshot: SystemSnapshot
    var body: some View {
        let s = snapshot
        let i = s.osInfo
        Card(title: "System") {
            Grid(alignment: .leading, verticalSpacing: 6) {
                row("Hostname", s.hostname)
                row("OS", s.osName)
                if let v = i["version"] {
                    row("Version", [v, i["codename"].map { "(\($0))" }, i["build"].map { "build \($0)" }]
                        .compactMap { $0 }.joined(separator: " "))
                }
                row("Kernel", s.kernel)
                if let b = i["kernelbuild"] { row("Kernel build", b) }
                row("Architecture", s.architecture)
                if let cpu = s.connection?.cpuModel, !cpu.isEmpty { row("CPU", cpu) }
                if s.cpuCount > 0 {
                    let sockets = i["sockets"].flatMap(Int.init).map { $0 > 1 ? " · \($0) sockets" : "" } ?? ""
                    row("Cores", "\(s.cpuCount) logical\(sockets)")
                }
                if s.memTotal > 0 { row("Memory", s.memTotal.byteString) }
                if let h = i["hardware"] { row("Hardware", h) }
                row("Virtualization", virtualization(i["virt"]))
                if let sh = i["shell"] { row("Login shell", sh) }
                row("Uptime", s.uptime.uptimeString)
                row("Booted", Date().addingTimeInterval(-s.uptime).formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private func virtualization(_ v: String?) -> String {
        switch v {
        case nil, "none"?: return "Bare metal (or not detected)"
        case let v?: return v == "kvm" ? "KVM virtual machine" : v == "docker" ? "Docker container" : v
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled).lineLimit(1)
        }
        .font(.callout)
    }
}

struct Card<Content: View>: View {
    let title: String
    /// Shows an export button in the card's title row (the card's table as CSV or JSON).
    var onExport: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                if let onExport {
                    Spacer()
                    Button(action: onExport) { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(.borderless)
                        .help("Export as CSV or JSON")
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }
}

struct ErrorCard: View {
    let message: String
    let retry: () -> Void
    @State private var showOutput = false

    /// A known ssh failure in the message (e.g. a changed host key), said in a sentence.
    private var diagnosis: (String, String)? {
        message.split(whereSeparator: \.isNewline).lazy.compactMap { ConnectionProgress.diagnose(String($0)) }.first
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.orange)
            if let (problem, hint) = diagnosis {
                // ssh's own output (banners and all) stays one click away.
                Text(problem).multilineTextAlignment(.center).font(.callout.weight(.medium))
                Text(hint).multilineTextAlignment(.center).font(.caption).foregroundStyle(.secondary)
                Button(showOutput ? "Hide ssh Output" : "Show ssh Output") { showOutput.toggle() }
                    .buttonStyle(.borderless).font(.caption)
                if showOutput {
                    Text(message).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(message).multilineTextAlignment(.center).font(.callout).textSelection(.enabled)
            }
            Button("Retry", action: retry).glassButtonStyle()
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }
}
