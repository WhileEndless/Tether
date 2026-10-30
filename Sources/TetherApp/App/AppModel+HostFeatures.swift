import Foundation
import TetherCore
import MonitorKit
import SessionKit
import SSHTransport

/// What may run on, or show for, each host (see `HostFeature`): the system setting, the host's own
/// choice, and the one place every subsystem asks.
extension AppModel {
    func feature(_ f: HostFeature, for target: ConnectionTarget) -> (on: Bool, origin: HostFeatureOrigin) {
        if f.needsScripts, isDevice(target) { return (false, .unsupported) }
        return settings.isEnabled(f, host: metadata(for: target.key).features)
    }

    // MARK: Network devices and limited shells

    /// Tether sends this host nothing but the terminal's login (see `ShellAccess`).
    func isDevice(_ target: ConnectionTarget) -> Bool {
        !target.isLocal && PlatformCache.shared.isDevice(target.key)
    }

    /// The user's choice of how Tether may use a host (host editor ▸ Shell).
    func shellAccess(for target: ConnectionTarget) -> ShellAccess {
        metadata(for: target.key).shellAccess ?? .automatic
    }

    func setShellAccess(_ access: ShellAccess, for target: ConnectionTarget) {
        updateMetadata(for: target.key) { $0.shellAccess = access == .automatic ? nil : access }
        PlatformCache.shared.setAccess(access, for: target.key)
        hostFeaturesChanged(target)
    }

    /// What was found on first contact, for the host editor ("Detected: …").
    func detectedShell(for target: ConnectionTarget) -> String? {
        if metadata(for: target.key).detectedDevice == true { return "a network device or limited shell" }
        return PlatformCache.shared.cached(target.key)?.title
    }

    func isEnabled(_ f: HostFeature, for target: ConnectionTarget) -> Bool { feature(f, for: target).on }

    /// The host's own choice (nil: it follows the system setting).
    func hostChoice(_ f: HostFeature, for target: ConnectionTarget) -> Bool? {
        metadata(for: target.key).features?[f.rawValue]
    }

    func setHostChoice(_ f: HostFeature, for target: ConnectionTarget, _ value: Bool?) {
        updateMetadata(for: target.key) { m in
            var own = m.features ?? [:]
            own[f.rawValue] = value
            m.features = own.isEmpty ? nil : own
        }
        hostFeaturesChanged(target)
    }

    /// Turns a feature on or off system-wide.
    func setSystemFeature(_ f: HostFeature, _ on: Bool) {
        settings.setEnabled(f, on)
        settingsChanged()
    }

    /// Everything that runs for the host follows the switches at once.
    func hostFeaturesChanged(_ target: ConnectionTarget) {
        monitors[target.key]?.featuresChanged()
        applyCommandSettings()
        for s in sessions.sessions(for: target.key) { applyAgentSettings(to: s) }
    }

    /// Whether the host panel shows a tab: switched on, and — for GPU, containers and
    /// Kubernetes — the host has what it needs (unless the host turned the tab on itself).
    func showsPanel(_ tab: InspectorTab, for target: ConnectionTarget, monitor: RemoteMonitor) -> Bool {
        let f = tab.feature
        guard isEnabled(f, for: target) else { return false }
        let snapshot = monitor.snapshot
        switch tab {
        case .gpu:
            return !(snapshot?.gpus.isEmpty ?? true)
        case .containers, .kubernetes:
            guard settings.hideAbsentToolPanels, hostChoice(f, for: target) != true else { return true }
            let has = tab == .containers ? snapshot?.hasContainerTool : snapshot?.hasKubernetesTool
            return has ?? true          // not known yet: shown
        default:
            return true
        }
    }
}

extension InspectorTab {
    var feature: HostFeature {
        switch self {
        case .overview: .overviewPanel
        case .command: .commandPanel
        case .processes: .processesPanel
        case .gpu: .gpuPanel
        case .services: .servicesPanel
        case .containers: .containersPanel
        case .kubernetes: .kubernetesPanel
        case .files: .filesPanel
        case .ports: .portsPanel
        case .logs: .logsPanel
        case .connections: .networkPanel
        case .sessions: .sessionsPanel
        }
    }
}

// MARK: Coding agents

extension AppModel {
    /// Hosts with a tab running a coding agent: their agents' status is looked at every few
    /// seconds (Settings ▸ Monitoring), so a plan approval or a question is noticed in any tab —
    /// not only on the host shown. Other hosts get nothing extra.
    func startAgentWatch() {
        guard agentWatch == nil else { return }
        agentWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let interval = max(self.settings.agentPollInterval, 2)
                var hosts: [String: ConnectionTarget] = [:]
                for s in self.sessions.sessions where s.phase.isOnline && s.persistence == .tmux && self.runsAgent(s) {
                    let t = s.descriptor.target
                    if self.isEnabled(.agentStatus, for: t) { hosts[t.key] = t }
                }
                // Each host on its own: one that does not answer (up to the look's time limit, or a
                // sign-in's) never delays the others' news. A look still running for a host is not
                // started twice (`refreshRemoteSessions` returns at once then).
                for t in hosts.values {
                    let monitor = self.monitor(for: t)
                    Task { @MainActor in await monitor.refreshRemoteSessions(maxAge: interval - 1) }
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// The agent and tab-activity settings a session follows.
    func applyAgentSettings(to s: TerminalSession) {
        let target = s.descriptor.target
        s.agentStatusEnabled = isEnabled(.agentStatus, for: target)
        s.notifyAgentWaiting = settings.notifyAgentWaiting && s.agentStatusEnabled
        s.notifyAgentDone = settings.notifyAgentDone && s.agentStatusEnabled
        s.outputQuietDelay = max(settings.workingQuietDelay, 1)
    }

    /// A coding agent runs in the session's terminal, as far as Tether knows.
    func runsAgent(_ s: TerminalSession) -> Bool {
        s.agent != nil || s.agentTitle != nil || s.foregroundName.flatMap { AgentKind(program: $0) } != nil
    }

    /// The agent a session's tab shows (its symbol), if any.
    /// The container tool in the terminal's foreground, and what it is doing (from its command line
    /// when the command watcher has it).
    func containerTool(of s: TerminalSession) -> (kind: ToolKind, doing: String?)? {
        guard settings.showToolIcons else { return nil }
        let line = commandSamplers[s.id]?.frame?.leader?.commandLine
        guard let program = s.foregroundName ?? line.flatMap({ $0.split(separator: " ").first.map(String.init) }),
              let kind = ToolKind(program: program, commandLine: line) else { return nil }
        return (kind, ToolKind.doing(line))
    }

    func agentKind(of s: TerminalSession) -> AgentKind? {
        guard settings.showAgentIcons else { return nil }
        return s.agent?.kind ?? s.foregroundName.flatMap { AgentKind(program: $0) }
    }
}
