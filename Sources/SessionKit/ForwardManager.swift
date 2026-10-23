import Foundation
import Observation
import TetherCore
import SSHTransport

/// Runs port forwards on each host's shared (ControlMaster) connection.
///
/// - Forwards belong to the host, not to a tab: several sessions to the same host share them.
/// - Ports are checked before starting; conflicts name the culprit and suggest a free port.
/// - A tiny keep-alive channel holds the master open while forwards are active and tells us when
///   the connection dies; active forwards are restored when a session to the host reconnects.
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
    @ObservationIgnored private var keepAlive: [String: RemoteStream] = [:]
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
        // Make sure a master connection exists (this authenticates if needed).
        let executor = RemoteExecutor(target: target, options: options)
        let probe = await executor.run(script: ":", timeout: 30, purpose: "forward")
        guard probe.succeeded else {
            let msg = Self.clean(probe.errorOutput, fallback: "Could not connect to \(target.displayName).")
            status[forward.id] = .failed(msg)
            return msg
        }
        let args = options.commonOptions() + ["-O", "forward", forward.kind.flag, forward.specification]
            + SSHOptions.destinationArguments(for: target)
        let r = await ProcessRunner.run(options.sshBinary, arguments: args, timeout: 20)
        guard r.status == 0 else {
            let msg = Self.explain(r.errorOutput + r.output, forward)
            status[forward.id] = .failed(msg)
            return msg
        }
        owners[forward.id] = (target, forward)
        status[forward.id] = .active
        ensureKeepAlive(for: target)
        return nil
    }

    public func stop(_ forward: PortForward) async {
        guard let owner = owners.removeValue(forKey: forward.id) else {
            status[forward.id] = .inactive
            return
        }
        let options = optionsProvider()
        let args = options.commonOptions() + ["-O", "cancel", forward.kind.flag, owner.forward.specification]
            + SSHOptions.destinationArguments(for: owner.target)
        _ = await ProcessRunner.run(options.sshBinary, arguments: args, timeout: 15)
        status[forward.id] = .inactive
        if activeCount(for: owner.target) == 0 { keepAlive.removeValue(forKey: owner.target.key)?.stop() }
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

    // MARK: Keep-alive

    /// Holds the master open while forwards are active and notices when it dies.
    private func ensureKeepAlive(for target: ConnectionTarget) {
        guard keepAlive[target.key] == nil else { return }
        let stream = RemoteStream(separator: "\n")
        stream.onEnd = { [weak self] _, _ in
            guard let self else { return }
            self.keepAlive[target.key] = nil
            for (id, owner) in self.owners where owner.target == target {
                self.owners[id] = nil
                self.pendingRestore.insert(id)
                self.status[id] = .failed("Connection lost — will restore on reconnect")
            }
        }
        keepAlive[target.key] = stream
        let executor = RemoteExecutor(target: target, options: optionsProvider())
        Task {
            let platform = await executor.resolvedPlatform()
            stream.start(executor: executor,
                         script: RemoteScript("while sleep 30; do echo; done",
                                              windows: "while ($true) { Start-Sleep -Seconds 30; '' }"),
                         platform: platform, arguments: [], purpose: "forward")
        }
    }
}
