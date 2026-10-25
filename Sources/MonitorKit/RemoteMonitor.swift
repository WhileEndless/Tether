import Foundation
import Observation
import SSHTransport
import TetherCore

/// Live system information for one host, shared by every view that shows it.
///
/// While at least one view is interested (`retain`/`release`), a single remote loop streams a
/// snapshot every few seconds over the shared ssh connection. Nothing runs when nobody looks.
@MainActor
@Observable
public final class RemoteMonitor {
    public struct Sample: Identifiable, Sendable {
        public var date: Date
        public var cpu: Double
        public var memory: Double
        public var gpu: Double?
        public var rx: Double?
        public var tx: Double?
        public var id: Date { date }
    }

    public let executor: RemoteExecutor
    /// Traffic per process on this host (streamed only while someone looks).
    public let traffic: ProcessTraffic
    public private(set) var snapshot: SystemSnapshot?
    public private(set) var history: [Sample] = []
    public private(set) var processes: [ProcessEntry] = []
    public private(set) var gpuProcesses: [GPUProcess] = []
    public private(set) var logins: [LoginEntry] = []
    public private(set) var connections: [ConnectionEntry] = []
    public private(set) var services: [ServiceEntry] = []
    public private(set) var containers: [ContainerEntry] = []
    /// nil until loaded, or when the host has no Kubernetes client.
    public private(set) var kubernetes: Result<KubeCluster, KubeError>?
    public private(set) var kubernetesLoaded = false
    public private(set) var remoteSessions: [RemoteSessionEntry] = []
    /// Sockets the server listens on (for the ports overview and quick forwarding).
    public private(set) var listeningPorts: [ListeningSocket] = []
    public private(set) var logText = ""
    public private(set) var error: String?
    public private(set) var isStreaming = false
    /// Latency of short commands over the shared connection (for hosts without a tmux session).
    public private(set) var commandLatency: Double?
    /// The host's platform, once known (Windows hosts have no load average, tmux, etc.).
    public private(set) var platform: RemotePlatform?

    @ObservationIgnored private var stream: RemoteStream?
    @ObservationIgnored private var sessionsRefreshing = false
    /// A fresh look was asked for while one was running (e.g. right after ending a session).
    @ObservationIgnored private var sessionsRefreshAgain = false
    @ObservationIgnored private var sessionsRefreshedAt: Date?
    @ObservationIgnored private var interest = 0
    @ObservationIgnored private var interval: TimeInterval = 3
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var lastFrameAt: Date?
    /// Demo data loaded: never contact the host.
    @ObservationIgnored private var frozen = false

    public init(executor: RemoteExecutor) {
        self.executor = executor
        traffic = ProcessTraffic(executor: executor)
    }

    // MARK: Interest

    /// A view starts showing this host's data.
    public func retain(interval: TimeInterval) {
        interest += 1
        self.interval = max(interval, 1)
        if stream == nil && !frozen && !paused { startStream() }
    }

    /// While paused (no window of the app is visible), nothing is streamed; the last data stays.
    public var paused = false {
        didSet {
            guard paused != oldValue else { return }
            if paused { stopStream() } else if interest > 0 && stream == nil && !frozen { startStream() }
        }
    }

    /// A view stops showing it. The stream ends shortly after the last one goes away.
    public func release() {
        interest = max(interest - 1, 0)
        guard interest == 0 else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.interest == 0 else { return }
            self.stopStream()
        }
    }

    private func startStream() {
        guard !frozen, !paused else { return }
        restartTask?.cancel()
        let s = RemoteStream(separator: "@@end\n")
        s.onRecord = { [weak self] text in self?.ingest(text) }
        s.onEnd = { [weak self] status, err in
            guard let self, self.stream === s else { return }
            self.stream = nil
            self.isStreaming = false
            if status != 0 && status != 15, !err.isEmpty {
                self.error = err.split(separator: "\n").suffix(2).joined(separator: "\n")
            }
            // Keep data flowing while someone is watching (e.g. after a reconnect).
            if self.interest > 0 {
                self.restartTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard let self, self.interest > 0, self.stream == nil else { return }
                    self.startStream()
                }
            }
        }
        stream = s
        isStreaming = true
        let executor = self.executor
        let interval = self.interval
        Task { [weak self] in
            // A terminal may be logging in to this host right now: stream over its connection.
            if executor.options.useControlMaster { await ConnectionGate.shared.waitForTurn(executor.target.key) }
            let platform = await executor.resolvedPlatform()
            guard let self, self.stream === s else { return }
            self.platform = platform
            s.start(executor: executor, script: RemoteScript(ProbeScripts.systemStream, windows: WindowsProbeScripts.systemStream),
                    platform: platform, arguments: [String(Int(interval))], purpose: "monitor")
        }
    }

    private func stopStream() {
        restartTask?.cancel()
        stream?.stop()
        stream = nil
        isStreaming = false
    }

    private func ingest(_ frame: String) {
        let snap = ProbeParser.system(frame, previous: snapshot)
        snapshot = snap
        error = nil
        let gpu = snap.gpus.compactMap(\.utilization).max()
        let net = snap.networkRates
        history.append(Sample(date: snap.timestamp, cpu: snap.cpuUsage ?? 0, memory: snap.memFraction, gpu: gpu,
                              rx: net?.rx, tx: net?.tx))
        if history.count > 200 { history.removeFirst(history.count - 200) }
        lastFrameAt = Date()
    }

    /// One-off refresh (e.g. the Retry button).
    public func refresh(firstSample: Bool = false) async {
        guard !frozen else { return }
        do {
            let start = Date()
            let text = try await executor.output(RemoteScript(ProbeScripts.system, windows: WindowsProbeScripts.system), arguments: ["1"], timeout: 20, purpose: "monitor")
            commandLatency = Date().timeIntervalSince(start)
            ingest(text)
        } catch {
            self.error = error.localizedDescription
        }
        if interest > 0 && stream == nil { startStream() }
    }

    // MARK: On-demand data

    public func refreshProcesses() async {
        guard !frozen else { return }
        if let text = try? await executor.output(RemoteScript(ProbeScripts.processes, windows: WindowsProbeScripts.processes), timeout: 20, purpose: "monitor") {
            processes = ProbeParser.processes(text)
        }
    }

    public func refreshListeningPorts() async {
        guard !frozen else { return }
        if let text = try? await executor.output(RemoteScript(ProbeScripts.listening, windows: WindowsProbeScripts.listening), timeout: 20, purpose: "monitor") {
            if containers.isEmpty { await refreshContainers() }
            listeningPorts = ProbeParser.listening(text, containers: containers)
        }
    }

    public func refreshGPUProcesses() async {
        guard !frozen else { return }
        if let text = try? await executor.output(RemoteScript(ProbeScripts.gpuProcesses, windows: WindowsProbeScripts.gpuProcesses), timeout: 20, purpose: "monitor") {
            gpuProcesses = ProbeParser.gpuProcesses(text)
        }
    }

    public func refreshConnections() async {
        guard !frozen else { return }
        if let text = try? await executor.output(RemoteScript(ProbeScripts.connections, windows: WindowsProbeScripts.connections), timeout: 20, purpose: "monitor") {
            let parsed = ProbeParser.connections(text)
            logins = parsed.logins
            connections = parsed.connections
        }
    }

    public func refreshServices() async {
        guard !frozen else { return }
        if let text = try? await executor.output(RemoteScript(ProbeScripts.services, windows: WindowsProbeScripts.services), timeout: 20, purpose: "monitor") {
            services = ProbeParser.services(text)
        }
    }

    public func refreshContainers() async {
        guard !frozen else { return }
        if let text = try? await executor.output(RemoteScript(ProbeScripts.containers, windows: WindowsProbeScripts.containers), timeout: 20, purpose: "monitor") {
            containers = ProbeParser.containers(text)
        }
    }

    public func refreshKubernetes() async {
        guard !frozen else { return }
        if let text = try? await executor.output(RemoteScript(KubeScripts.list, windows: KubeScripts.listWindows),
                                                 timeout: 30, purpose: "monitor") {
            kubernetes = ProbeParser.kubernetes(text)
        }
        kubernetesLoaded = true
    }

    /// logs / describe / delete for a pod. Returns the output (or the error).
    public func kubernetes(_ action: String, _ pod: KubePod) async -> (ok: Bool, output: String) {
        // The tool name came from the host: only a known client is ever run.
        guard case .success(let cluster)? = kubernetes, KubeScripts.tools.contains(cluster.tool),
              ["logs", "describe", "delete"].contains(action) else { return (false, "Not available.") }
        let r = await executor.run(RemoteScript(KubeScripts.action, windows: KubeScripts.actionWindows),
                                   arguments: [cluster.tool, action, pod.namespace, pod.name], timeout: 60, purpose: "kubernetes")
        if action == "delete" { await refreshKubernetes() }
        return (r.succeeded, r.output + r.errorOutput)
    }

    /// Lists the host's tmux/screen sessions and what runs in them. One look at a time per host;
    /// with `maxAge`, a list younger than that is kept (several views ask on their own schedules).
    /// Called after every look at the server sessions (the app names tabs after coding agents; it
    /// changes nothing when nothing changed).
    @ObservationIgnored public var onRemoteSessions: (([RemoteSessionEntry]) -> Void)?

    public func refreshRemoteSessions(maxAge: TimeInterval = 0) async {
        guard !frozen else { return }
        if sessionsRefreshing {
            // The running look may have started before the change the caller knows about.
            if maxAge == 0 { sessionsRefreshAgain = true }
            return
        }
        if maxAge > 0, let at = sessionsRefreshedAt, Date().timeIntervalSince(at) < maxAge { return }
        sessionsRefreshing = true
        repeat {
            sessionsRefreshAgain = false
            await lookAtRemoteSessions()
        } while sessionsRefreshAgain && !frozen
        sessionsRefreshing = false
    }

    private func lookAtRemoteSessions() async {
        let start = Date()
        if let text = try? await executor.output(RemoteScript(ProbeScripts.remoteSessions, windows: WindowsProbeScripts.remoteSessions), timeout: 20, purpose: "monitor") {
            commandLatency = Date().timeIntervalSince(start)
            sessionsRefreshedAt = Date()
            // Unchanged lists are not assigned: observers (the sidebar) are not redrawn for nothing.
            let found = ProbeParser.remoteSessions(text)
            if found != remoteSessions { remoteSessions = found }
            onRemoteSessions?(found)
        }
    }

    public func loadLogs(_ source: LogSource, lines: Int) async {
        guard !frozen else { return }
        let (script, args) = ProbeScripts.logs(source, lines: lines)
        let windowsArgs = [WindowsProbeScripts.logName(source), String(max(lines, 10))]
        do {
            let platform = await executor.resolvedPlatform()
            logText = try await executor.output(RemoteScript(script, windows: WindowsProbeScripts.logs),
                                                arguments: platform.isWindows ? windowsArgs : args, timeout: 30, purpose: "logs")
        } catch {
            logText = ""
            self.error = error.localizedDescription
        }
    }

    public func serviceLogs(_ unit: String, lines: Int) async -> String {
        (try? await executor.output(RemoteScript(#"journalctl -u "$1" -n "$2" --no-pager -o short-iso 2>&1"#,
                                                 windows: WindowsProbeScripts.serviceLogs),
                                    arguments: [unit, String(lines)], timeout: 30, purpose: "logs")) ?? ""
    }

    /// The name the host gives an address (for "where does this connection go"); nil when it has none.
    public func hostName(of address: String) async -> String? {
        guard !frozen, !address.isEmpty, address != "*" else { return nil }
        let r = await executor.run(RemoteScript(ProbeScripts.reverseLookup, windows: WindowsProbeScripts.reverseLookup),
                                   arguments: [address], timeout: 10, purpose: "monitor")
        let name = r.output.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return name.isEmpty || name == address ? nil : name
    }

    /// Stops a running command and everything it started (`ProbeScripts.stopCommand`). Returns a
    /// message when something could not be stopped, nil when all of it ended.
    public func stopCommand(_ processes: [CommandProcess], shellPid: Int?, signal: String) async -> String? {
        guard !frozen, let leader = processes.first else { return nil }
        let args = [signal, String(shellPid ?? 0), leader.group.map(String.init) ?? ""] + processes.map { String($0.pid) }
        let r = await executor.run(RemoteScript(ProbeScripts.stopCommand, windows: WindowsProbeScripts.stopCommand),
                                   arguments: args, timeout: 20, purpose: "kill")
        guard r.succeeded else {
            let msg = DiagnosticLog.tail(r.errorOutput)
            return msg.isEmpty ? "Stopping failed with code \(r.status)." : msg
        }
        let alive = r.output.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("alive ") }.count
        guard alive > 0 else { return nil }
        return signal == "KILL"
            ? "\(alive) process\(alive == 1 ? "" : "es") could not be stopped (owned by another user, e.g. started with sudo)."
            : "\(alive) process\(alive == 1 ? "" : "es") still running after \(signal) — use Kill to end them at once."
    }

    /// Sends a signal to a remote process. Returns an error message on failure.
    public func signal(_ pid: Int, signal: String) async -> String? {
        let r = await executor.run(RemoteScript(ProbeScripts.kill, windows: WindowsProbeScripts.kill), arguments: [signal, String(pid)], timeout: 15, purpose: "kill")
        if r.succeeded {
            await refreshProcesses()
            return nil
        }
        let msg = r.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.isEmpty ? "kill failed with code \(r.status)" : msg
    }

    /// start / stop / restart a service. Returns an error message on failure.
    public func service(_ action: String, _ unit: String) async -> String? {
        let r = await executor.run(RemoteScript(ProbeScripts.serviceAction, windows: WindowsProbeScripts.serviceAction), arguments: [action, unit], timeout: 60, purpose: "service")
        await refreshServices()
        if r.succeeded { return nil }
        let msg = r.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.contains("password is required") || msg.contains("a password")
            ? "Needs root: passwordless sudo is not available for this user." : (msg.isEmpty ? "Failed (\(r.status))" : msg)
    }

    /// start / stop / restart / logs for a container. Returns output (logs) or an error.
    public func container(_ action: String, _ c: ContainerEntry) async -> (ok: Bool, output: String) {
        let r = await executor.run(RemoteScript(ProbeScripts.containerAction, windows: WindowsProbeScripts.containerAction), arguments: [c.engine, action, c.id],
                                   timeout: 60, purpose: "containers")
        if action != "logs" { await refreshContainers() }
        return (r.succeeded, r.output + r.errorOutput)
    }

    /// Drops a server session from the list right away (it was just ended); a refresh confirms it.
    public func forgetRemoteSession(named name: String) {
        remoteSessions.removeAll { $0.name == name }
    }

    public func killRemoteSession(_ entry: RemoteSessionEntry) async {
        let script = entry.kind == .tmux ? "tmux kill-session -t \"=$1\"" : "screen -S \"$1\" -X quit"
        _ = await executor.run(script: script, arguments: [entry.name], timeout: 15, purpose: "sessions")
        await refreshRemoteSessions()
    }

    /// Kills every Tether-created session that is not currently open in the app.
    public func cleanUpOrphans(keeping open: Set<String>) async -> Int {
        let orphans = remoteSessions.filter { $0.isTether && !open.contains($0.name) && !$0.attached }
        for o in orphans {
            let script = o.kind == .tmux ? "tmux kill-session -t \"=$1\"" : "screen -S \"$1\" -X quit"
            _ = await executor.run(script: script, arguments: [o.name], timeout: 15, purpose: "sessions")
        }
        await refreshRemoteSessions()
        return orphans.count
    }

    #if DEBUG
    /// Debug builds only: fills the monitor with prepared probe output (in the real probe formats,
    /// so the real parsers run) and stops it from contacting the host. Used for demo screenshots.
    public func loadDemo(_ demo: DemoData) {
        frozen = true
        stopStream()
        var snap = ProbeParser.system(demo.systemFrame, previous: nil)
        for i in snap.interfaces.indices {
            if let r = demo.rates[snap.interfaces[i].name] { snap.interfaces[i].rxRate = r.rx; snap.interfaces[i].txRate = r.tx }
        }
        snap.cpuUsage = demo.history.last?.cpu
        snapshot = snap
        let now = Date()
        history = demo.history.enumerated().map { i, h in
            Sample(date: now.addingTimeInterval(Double(i - demo.history.count) * 5), cpu: h.cpu, memory: h.memory,
                   gpu: h.gpu, rx: h.rx, tx: h.tx)
        }
        containers = ProbeParser.containers(demo.containers)
        processes = ProbeParser.processes(demo.processes)
        services = ProbeParser.services(demo.services)
        listeningPorts = ProbeParser.listening(demo.listening, containers: containers)
        let parsed = ProbeParser.connections(demo.connections)
        logins = parsed.logins
        connections = parsed.connections
        remoteSessions = ProbeParser.remoteSessions(demo.remoteSessions)
        gpuProcesses = ProbeParser.gpuProcesses(demo.gpuProcesses)
        logText = demo.logs
        commandLatency = demo.latency
        error = nil
    }

    public struct DemoData {
        public var systemFrame = ""
        public var rates: [String: (rx: Double, tx: Double)] = [:]
        public var history: [(cpu: Double, memory: Double, gpu: Double?, rx: Double?, tx: Double?)] = []
        public var processes = ""
        public var services = ""
        public var containers = ""
        public var listening = ""
        public var connections = ""
        public var remoteSessions = ""
        public var gpuProcesses = ""
        public var logs = ""
        public var latency: Double?
        public init() {}
    }
    #endif
}
