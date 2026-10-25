import SwiftUI
import TetherCore
import MonitorKit
import SessionKit

enum InspectorTab: String, CaseIterable, Identifiable {
    case overview = "Overview", command = "Command", processes = "Processes", gpu = "GPU", services = "Services",
         containers = "Containers", kubernetes = "Kubernetes", files = "Files", ports = "Ports", logs = "Logs", connections = "Network",
         sessions = "Sessions"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .command: "terminal"
        case .processes: "list.bullet.rectangle"
        case .gpu: "cpu"
        case .services: "gearshape.2"
        case .containers: "shippingbox"
        case .kubernetes: "circle.hexagongrid"
        case .files: "folder"
        case .ports: "arrow.left.arrow.right.circle"
        case .logs: "doc.text.magnifyingglass"
        case .connections: "network"
        case .sessions: "rectangle.stack"
        }
    }
}

struct InspectorContainer: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state

    var body: some View {
        @Bindable var state = state
        if let target = state.inspectedTarget {
            let monitor = model.monitor(for: target)
            let tabs = InspectorTab.allCases.filter { $0 != .gpu || !(monitor.snapshot?.gpus.isEmpty ?? true) }
            VStack(spacing: 0) {
                HostHeader(target: target, monitor: monitor)
                InspectorTabBar(tabs: tabs, selection: $state.inspectorTab)
                Divider()
                Group {
                    switch state.inspectorTab {
                    case .overview: OverviewPanel(target: target, monitor: monitor)
                    case .command: CommandPanel(target: target, monitor: monitor)
                    case .processes: ProcessesPanel(monitor: monitor)
                    case .gpu: GPUPanel(monitor: monitor)
                    case .services: ServicesPanel(monitor: monitor)
                    case .containers: ContainersPanel(monitor: monitor)
                    case .kubernetes: KubernetesPanel(monitor: monitor)
                    case .files: FileBrowserView(target: target, standalone: false) { dir in
                        state.connect(target, directory: dir)
                    }
                    case .ports: PortsPanel(target: target, monitor: monitor)
                    case .logs: LogsPanel(monitor: monitor)
                    case .connections: ConnectionsPanel(monitor: monitor)
                    case .sessions: RemoteSessionsPanel(monitor: monitor, target: target)
                    }
                }
                .id(target.key + state.inspectorTab.rawValue)
            }
            // Keep the stream alive while the panel shows this host.
            .onAppear { monitor.retain(interval: model.settings.monitorRefreshInterval) }
            .onDisappear { monitor.release() }
            .id(target.key)
        } else {
            EmptyStateView(symbol: "server.rack", title: "No Host Selected",
                           message: "Select a host or a session to see its system information.")
        }
    }
}

/// Compact icon tab bar for the host panel (labels appear on hover).
private struct InspectorTabBar: View {
    let tabs: [InspectorTab]
    @Binding var selection: InspectorTab
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                Button {
                    selection = tab
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .foregroundStyle(selection == tab ? Color.accentColor : .secondary)
                        .background {
                            if selection == tab {
                                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.14))
                                    .matchedGeometryEffect(id: "sel", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.rawValue)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .animation(.snappy(duration: 0.2), value: selection)
        .onChange(of: tabs) { _, t in if !t.contains(selection) { selection = .overview } }
    }
}

struct HostHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let target: ConnectionTarget
    let monitor: RemoteMonitor

    var body: some View {
        let snapshot = monitor.snapshot
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(model.metadata(for: target.key).color.color ?? .accentColor)
                Circle()
                    .fill(monitor.isStreaming && monitor.error == nil ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                    .offset(x: 3, y: 2)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(target.displayName).font(.headline).lineLimit(1)
                Text(snapshot.map { "\($0.osName) · \($0.architecture) · up \($0.uptime.uptimeString)" } ?? "Connecting…")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer()
            Button {
                state.connect(target)
            } label: {
                Image(systemName: "terminal")
            }
            .glassButtonStyle()
            .help("New terminal")
        }
        .padding(12)
    }
}
