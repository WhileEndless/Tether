import Foundation

/// Everything Tether runs on, or shows for, a host that can be switched off — system-wide in
/// Settings ▸ Monitoring, and per host (host editor, the host panel's menu, the sidebar).
///
/// A host's choice wins over the system setting; `monitoring` off stops everything that probes
/// the host at once (`needsMonitoring`).
public enum HostFeature: String, CaseIterable, Codable, Identifiable, Sendable {
    // Monitoring
    case monitoring
    case statusStrip
    // Host panel tabs
    case overviewPanel, commandPanel, processesPanel, gpuPanel, servicesPanel, containersPanel
    case kubernetesPanel, filesPanel, portsPanel, logsPanel, networkPanel, sessionsPanel
    // In the background
    case serverSessions, keyLoginCheck, commandWatch, commandStats, commandHistory, processTraffic
    case agentStatus, tabActivity

    public var id: String { rawValue }

    public enum Group: String, CaseIterable, Sendable {
        case monitoring = "Monitoring"
        case panels = "Host Panel"
        case background = "In the Background"
    }

    public var group: Group {
        switch self {
        case .monitoring, .statusStrip: .monitoring
        case .overviewPanel, .commandPanel, .processesPanel, .gpuPanel, .servicesPanel, .containersPanel,
             .kubernetesPanel, .filesPanel, .portsPanel, .logsPanel, .networkPanel, .sessionsPanel: .panels
        default: .background
        }
    }

    public var title: String {
        switch self {
        case .monitoring: "Monitor the host"
        case .statusStrip: "Status bar under the terminal"
        case .overviewPanel: "Overview"
        case .commandPanel: "Command"
        case .processesPanel: "Processes"
        case .gpuPanel: "GPU"
        case .servicesPanel: "Services"
        case .containersPanel: "Containers"
        case .kubernetesPanel: "Kubernetes"
        case .filesPanel: "Files"
        case .portsPanel: "Ports"
        case .logsPanel: "Logs"
        case .networkPanel: "Network"
        case .sessionsPanel: "Sessions"
        case .serverSessions: "Server sessions in the sidebar"
        case .keyLoginCheck: "Check whether key login works"
        case .commandWatch: "Follow which command runs"
        case .commandStats: "Running command stats"
        case .commandHistory: "Command history"
        case .processTraffic: "Traffic by process"
        case .agentStatus: "Coding agent status"
        case .tabActivity: "Working mark on tabs"
        }
    }

    /// What it does on the host, in a few words (Settings shows it under the switch).
    public var detail: String {
        switch self {
        case .monitoring: "Everything below that runs commands on the host. Off: nothing is probed."
        case .statusStrip: "CPU, memory and disk under the terminal, from the live stream."
        case .overviewPanel: "The live system stream: CPU, memory, disks, network."
        case .commandPanel: "The command running in the tab, its processes and what they use."
        case .processesPanel: "The process list (ps)."
        case .gpuPanel: "GPU use (nvidia-smi, rocm-smi), shown when the host has a GPU."
        case .servicesPanel: "Services (systemctl, launchctl, Get-Service)."
        case .containersPanel: "Docker or Podman containers."
        case .kubernetesPanel: "Pods and nodes through the host's kubectl."
        case .filesPanel: "Browsing files over the connection."
        case .portsPanel: "Listening ports and your port forwards."
        case .logsPanel: "System logs (journalctl, log, Get-WinEvent)."
        case .networkPanel: "Connections and logins (ss, netstat, who)."
        case .sessionsPanel: "tmux and screen sessions on the server."
        case .serverSessions: "Lists tmux and screen sessions every 15 s while the host is shown."
        case .keyLoginCheck: "Tries key login once (BatchMode) to offer key setup."
        case .commandWatch: "Notices within half a second when a command starts or ends."
        case .commandStats: "Measures the running command every few seconds (the pill under the terminal)."
        case .commandHistory: "Keeps finished commands with what they used."
        case .processTraffic: "Network use per process (ss, nettop) while the Network tab is shown."
        case .agentStatus: "Reads coding agents' status files (Claude Code) to notice when they wait for you."
        case .tabActivity: "Animates a tab's mark while its command is busy."
        }
    }

    /// Off together with `monitoring`. Browsing files and your own port forwards are not monitoring.
    public var needsMonitoring: Bool {
        switch self {
        case .monitoring, .filesPanel, .portsPanel: false
        default: true
        }
    }

    /// Runs scripts on the host: never on a network device or limited shell. Port forwards use
    /// the connection only; an agent's status and a tab's activity are read from the terminal.
    public var needsScripts: Bool {
        switch self {
        case .portsPanel, .agentStatus, .tabActivity: false
        default: true
        }
    }

    /// The host panel tab this feature shows, if it is one.
    public static let panels: [HostFeature] = allCases.filter { $0.group == .panels }
}

/// Where a feature's state comes from (shown next to switches that are off).
public enum HostFeatureOrigin: Equatable, Sendable {
    case host, system, monitoringOff
    /// The host is a network device or limited shell: nothing runs there.
    case unsupported
}

extension AppSettings {
    /// The system-wide switch of a feature. A few have their own long-standing settings; the
    /// others live in `hostFeatures` (absent: on).
    public func isEnabled(_ feature: HostFeature) -> Bool {
        switch feature {
        case .monitoring: monitorAutoLoad
        case .statusStrip: showStatusStrip
        case .commandStats: showCommandStats
        case .commandHistory: keepCommandHistory
        case .commandWatch: commandWatchEnabled
        default: hostFeatures[feature.rawValue] ?? true
        }
    }

    public mutating func setEnabled(_ feature: HostFeature, _ on: Bool) {
        switch feature {
        case .monitoring: monitorAutoLoad = on
        case .statusStrip: showStatusStrip = on
        case .commandStats: showCommandStats = on
        case .commandHistory: keepCommandHistory = on
        case .commandWatch: commandWatchEnabled = on
        default: hostFeatures[feature.rawValue] = on ? nil : false
        }
    }

    /// Whether a feature is on for a host: the host's own choice, else the system setting —
    /// and never while monitoring is off for it. `host` is the host's overrides (`HostMetadata.features`).
    public func isEnabled(_ feature: HostFeature, host: [String: Bool]?) -> (on: Bool, origin: HostFeatureOrigin) {
        if feature.needsMonitoring, !isEnabled(.monitoring, host: host).on { return (false, .monitoringOff) }
        if let own = host?[feature.rawValue] { return (own, .host) }
        return (isEnabled(feature), .system)
    }
}
