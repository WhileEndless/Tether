import Foundation
import Observation
import TetherCore
import SSHTransport

/// Runs port forwards on each host's shared (ControlMaster) connection.
///
/// - Forwards belong to the host, not to a tab: several sessions to the same host share them.
/// - Ports are checked before starting; conflicts name the culprit and suggest a free port.
/// - The shared connection stays open by itself (`SharedConnections`); it is checked every 30 s on
///   this Mac (nothing is sent to the server), and active forwards are restored when a session to
///   the host reconnects.
@MainActor
@Observable
public final class ForwardManager {
    public enum Status: Equatable, Sendable {
        case inactive
        case starting
        case active
        case failed(String)

        public var isActive: Bool { self == .active }
    }

    public private(set) var status: [UUID: Status] = [:]
    /// Which host each running forward belongs to.
    @ObservationIgnored private var owners: [UUID: (target: ConnectionTarget, forward: PortForward)] = [:]
    /// Hosts with active forwards: their shared connection is checked every 30 s.
    @ObservationIgnored private var deviceWatch: [String: Task<Void, Never>] = [:]
    /// Which sign-in of its host's connection each forward was made on (`SharedConnections.generation`).
    @ObservationIgnored private var madeOn: [UUID: Int] = [:]

    /// Notices when the shared connection carrying the host's forwards has ended — or was replaced by
    /// a new one (closed as dead after waking, then signed in again): forwards live in the connection
    /// that made them, so they are made again on the new one. Only Tether's own state and the
    /// socket are asked: a channel that printed something every few seconds made the server give
    /// up on the connection while the Mac slept (nothing acknowledged what it sent).
    private func watchConnection(_ target: ConnectionTarget) {
        guard deviceWatch[target.key] == nil else { return }
        let executor = RemoteExecutor(target: target, options: optionsProvider())
        let options = optionsProvider()
        deviceWatch[target.key] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                let alive = await executor.isMasterAlive()
                let generation = await SharedConnections.shared.generation(of: target, options: options)
                guard let self else { return }
                // Not known right now (ssh could not work the connection out): nothing is decided.
                if generation == 0 { continue }
                let mine = self.owners.filter { $0.value.target == target }
                let replaced = mine.contains { self.madeOn[$0.key] != generation }
                guard !alive || replaced else { continue }
                ConnectionLog.shared.notice(alive ? "Port forwards are made again on the new connection" : "Port forwards stopped with their connection",
                                            .forward, host: target.key)
                for (id, owner) in mine {
                    self.owners[id] = nil
                    self.madeOn[id] = nil
                    self.status[id] = alive ? .inactive : .failed("Connection lost — will restore on reconnect")
                    if alive { Task { await self.start(owner.forward, on: target) } } else { self.pendingRestore.insert(id) }
                }
                if !alive || self.owners.values.allSatisfy({ $0.target != target }) {
                    self.deviceWatch[target.key] = nil
                    return
                }
            }
        }
    }
    /// Forwards that were active when their connection died; restored on the next connect.
    @ObservationIgnored private var pendingRestore: Set<UUID> = []
    @ObservationIgnored private let optionsProvider: () -> SSHOptions

    public init(options: @escaping () -> SSHOptions) {
        optionsProvider = options
    }

    public func status(of forward: PortForward) -> Status { status[forward.id] ?? .inactive }

    public func activeCount(for target: ConnectionTarget) -> Int {
        owners.values.filter { $0.target == target && status[$0.forward.id] == .active }.count
    }

    /// Starts a forward. Returns an error message (also stored in `status`) on failure.
    @discardableResult
    public func start(_ forward: PortForward, on target: ConnectionTarget) async -> String? {
        if status[forward.id] == .active || status[forward.id] == .starting { return nil }
        if let conflict = localConflict(forward, target: target) {
            status[forward.id] = .failed(conflict)
            return conflict
        }
        status[forward.id] = .starting
        let options = optionsProvider()
        guard options.useControlMaster, !target.isLocal else {
            let msg = target.isLocal ? "Port forwarding needs a remote host." : "Port forwarding needs connection sharing (Settings ▸ SSH)."
            status[forward.id] = .failed(msg)
            return msg
        }
        // The host's shared connection (signing in once if it is not there; a network device signs
        // in the same way, without running anything).
        let ready: SSHOptions
        switch await RemoteExecutor(target: target, options: options).prepared(purpose: "forward") {
        case .ready(let executor):
            ready = executor.options
        case .refused(let result):
            let msg = Self.clean(result.errorOutput, fallback: "Could not connect to \(target.displayName).")
            status[forward.id] = .failed(msg)
            return msg
        }
        // Stopped while the connection was being prepared: not started after all.
        guard status[forward.id] == .starting else { return nil }
        let generation = await SharedConnections.shared.generation(of: target, options: options)
        let args = ready.commonOptions() + ["-O", "forward", forward.kind.flag, forward.specification] + ready.destination(target)
        let r = await ProcessRunner.run(options.sshBinary, arguments: args, timeout: 20)
        guard r.status == 0 else {
            let msg = Self.explain(r.errorOutput + r.output, forward)
            status[forward.id] = .failed(msg)
            ConnectionLog.shared.problem("A port forward could not be made", .forward, host: target.key, detail: msg)
            return msg
        }
        owners[forward.id] = (target, forward)
        ConnectionLog.shared.info("Port forward made", .forward, host: target.key, detail: forward.kind.flag + " " + forward.specification)
        madeOn[forward.id] = generation
        guard status[forward.id] == .starting else {
            // Stopped while it was being made: undone at once.
            Task { await self.stop(forward) }
            return nil
        }
        status[forward.id] = .active
        watchConnection(target)
        return nil
    }

    public func stop(_ forward: PortForward) async {
        madeOn[forward.id] = nil
        guard let owner = owners.removeValue(forKey: forward.id) else {
            status[forward.id] = .inactive
            return
        }
        let options = optionsProvider()
        // Only an open connection has the forward to cancel: never a sign-in for this.
        if let ready = await SharedConnections.shared.readyOptions(owner.target, options: options) {
            let args = ready.commonOptions() + ["-O", "cancel", forward.kind.flag, owner.forward.specification] + ready.destination(owner.target)
            _ = await ProcessRunner.run(options.sshBinary, arguments: args, timeout: 15)
        }
        status[forward.id] = .inactive
        if activeCount(for: owner.target) == 0 {
            deviceWatch.removeValue(forKey: owner.target.key)?.cancel()
        }
    }

    /// Starts forwards marked auto-start, and re-establishes active ones after a reconnect.
    public func sessionConnected(to target: ConnectionTarget, saved: [PortForward]) {
        for f in saved where f.autoStart || pendingRestore.contains(f.id) {
            pendingRestore.remove(f.id)
            Task { await start(f, on: target) }
        }
    }

    // MARK: Conflicts

    private func localConflict(_ forward: PortForward, target: ConnectionTarget) -> String? {
        guard forward.listensLocally else { return nil }
        if let other = owners.first(where: { $0.value.forward.listensLocally && $0.value.forward.listenPort == forward.listenPort
                                             && $0.key != forward.id && status[$0.key] == .active }) {
            return "Port \(forward.listenPort) is already used by the forward \"\(other.value.forward.summary)\" on \(other.value.target.displayName)."
        }
        if !LocalPorts.isFree(forward.listenPort, address: forward.bindAddress) {
            let suggestion = LocalPorts.nextFree(from: forward.listenPort + 1, address: forward.bindAddress)
            return "Port \(forward.listenPort) is in use on this Mac" + (suggestion.map { " — try \($0)." } ?? ".")
        }
        if forward.listenPort < 1024 && forward.bindAddress.isEmpty == false {
            return "Ports below 1024 need administrator rights on macOS."
        }
        return nil
    }

    static func explain(_ text: String, _ forward: PortForward) -> String {
        let t = text.lowercased()
        if t.contains("remote port forwarding failed") || (forward.kind == .remote && t.contains("failed")) {
            return "Port \(forward.listenPort) could not be opened on the server (in use, or not allowed by sshd)."
        }
        if t.contains("address already in use") || t.contains("bind") {
            return "Port \(forward.listenPort) is already in use."
        }
        if t.contains("no such file") || t.contains("control socket") {
            return "The shared connection is not running; connect to the host first."
        }
        return clean(text, fallback: "Port forwarding failed.")
    }

    static func clean(_ text: String, fallback: String) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.isEmpty ? fallback : lines.suffix(2).joined(separator: " ")
    }
}
