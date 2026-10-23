import Foundation
import Observation
import SSHTransport

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
    public private(set) var snapshot: SystemSnapshot?
    public private(set) var history: [Sample] = []
    public private(set) var processes: [ProcessEntry] = []
    public private(set) var gpuProcesses: [GPUProcess] = []
    public private(set) var logins: [LoginEntry] = []
    public private(set) var connections: [ConnectionEntry] = []
    public private(set) var services: [ServiceEntry] = []
    public private(set) var containers: [ContainerEntry] = []
    public private(set) var remoteSessions: [RemoteSessionEntry] = []
    /// Sockets the server listens on (for the ports overview and quick forwarding).
    public private(set) var listeningPorts: [ListeningSocket] = []
    public private(set) var logText = ""
    public private(set) var error: String?
    public private(set) var isStreaming = false
    /// Latency of short commands over the shared connection (for hosts without a tmux session).
    public private(set) var commandLatency: Double?

    @ObservationIgnored private var stream: RemoteStream?
    @ObservationIgnored private var interest = 0
    @ObservationIgnored private var interval: TimeInterval = 3
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var lastFrameAt: Date?

    public init(executor: RemoteExecutor) {
        self.executor = executor
    }

    // MARK: Interest

    /// A view starts showing this host's data.
    public func retain(interval: TimeInterval) {
        interest += 1
        self.interval = max(interval, 1)
        if stream == nil { startStream() }
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
        s.start(executor: executor, script: ProbeScripts.systemStream, arguments: [String(Int(interval))], purpose: "monitor")
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
        do {
            let start = Date()
            let text = try await executor.output(script: ProbeScripts.system, arguments: ["1"], timeout: 20, purpose: "monitor")
            commandLatency = Date().timeIntervalSince(start)
            ingest(text)
        } catch {
            self.error = error.localizedDescription
        }
        if interest > 0 && stream == nil { startStream() }
    }

    // MARK: On-demand data

    public func refreshProcesses() async {
        if let text = try? await executor.output(script: ProbeScripts.processes, timeout: 20, purpose: "monitor") {
            processes = ProbeParser.processes(text)
        }
    }

    public func refreshListeningPorts() async {
        if let text = try? await executor.output(script: ProbeScripts.listening, timeout: 20, purpose: "monitor") {
            if containers.isEmpty { await refreshContainers() }
            listeningPorts = ProbeParser.listening(text, containers: containers)
        }
    }

    public func refreshGPUProcesses() async {
        if let text = try? await executor.output(script: ProbeScripts.gpuProcesses, timeout: 20, purpose: "monitor") {
            gpuProcesses = ProbeParser.gpuProcesses(text)
        }
    }

    public func refreshConnections() async {
        if let text = try? await executor.output(script: ProbeScripts.connections, timeout: 20, purpose: "monitor") {
            let parsed = ProbeParser.connections(text)
            logins = parsed.logins
            connections = parsed.connections
        }
    }

    public func refreshServices() async {
        if let text = try? await executor.output(script: ProbeScripts.services, timeout: 20, purpose: "monitor") {
            services = ProbeParser.services(text)
        }
    }

    public func refreshContainers() async {
        if let text = try? await executor.output(script: ProbeScripts.containers, timeout: 20, purpose: "monitor") {
            containers = ProbeParser.containers(text)
        }
    }

    public func refreshRemoteSessions() async {
        let start = Date()
        if let text = try? await executor.output(script: ProbeScripts.remoteSessions, timeout: 20, purpose: "monitor") {
            commandLatency = Date().timeIntervalSince(start)
            remoteSessions = ProbeParser.remoteSessions(text)
        }
    }

    public func loadLogs(_ source: LogSource, lines: Int) async {
        let (script, args) = ProbeScripts.logs(source, lines: lines)
        do {
            logText = try await executor.output(script: script, arguments: args, timeout: 30, purpose: "logs")
        } catch {
            logText = ""
            self.error = error.localizedDescription
        }
    }

    public func serviceLogs(_ unit: String, lines: Int) async -> String {
        (try? await executor.output(script: #"journalctl -u "$1" -n "$2" --no-pager -o short-iso 2>&1"#,
                                    arguments: [unit, String(lines)], timeout: 30, purpose: "logs")) ?? ""
    }

    /// Sends a signal to a remote process. Returns an error message on failure.
    public func signal(_ pid: Int, signal: String) async -> String? {
        let r = await executor.run(script: ProbeScripts.kill, arguments: [signal, String(pid)], timeout: 15, purpose: "kill")
        if r.succeeded {
            await refreshProcesses()
            return nil
        }
        let msg = r.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.isEmpty ? "kill failed with code \(r.status)" : msg
    }

    /// start / stop / restart a service. Returns an error message on failure.
    public func service(_ action: String, _ unit: String) async -> String? {
        let r = await executor.run(script: ProbeScripts.serviceAction, arguments: [action, unit], timeout: 60, purpose: "service")
        await refreshServices()
        if r.succeeded { return nil }
        let msg = r.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.contains("password is required") || msg.contains("a password")
            ? "Needs root: passwordless sudo is not available for this user." : (msg.isEmpty ? "Failed (\(r.status))" : msg)
    }

    /// start / stop / restart / logs for a container. Returns output (logs) or an error.
    public func container(_ action: String, _ c: ContainerEntry) async -> (ok: Bool, output: String) {
        let r = await executor.run(script: ProbeScripts.containerAction, arguments: [c.engine, action, c.id],
                                   timeout: 60, purpose: "containers")
        if action != "logs" { await refreshContainers() }
        return (r.succeeded, r.output + r.errorOutput)
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
}
