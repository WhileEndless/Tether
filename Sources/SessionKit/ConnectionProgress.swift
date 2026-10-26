import Foundation
import TetherCore
import SSHTransport

/// What a connection is doing right now, for a step-by-step progress view.
public struct ConnectionProgress: Equatable, Sendable {
    public enum Step: Int, CaseIterable, Sendable, Comparable {
        case connect, authenticate, startSession, restore

        public var title: String {
            switch self {
            case .connect: "Connect"
            case .authenticate: "Sign in"
            case .startSession: "Start session"
            case .restore: "Restore"
            }
        }

        public static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    public var step: Step = .connect
    /// One line about the current step, e.g. "Trying key id_ed25519".
    public var detail = "Starting…"
    public var startedAt = Date()
    /// Hosts along the way (jump hosts first).
    public var hops: [String] = []
    /// Recent ssh log lines (verbose), for the details view.
    public var log: [String] = []
    /// Set when the connection failed: what went wrong and what to try.
    public var failure: String?
    public var hint: String?
    /// The restore step only applies when re-attaching to an existing session.
    public var includesRestore = false
    /// Reconnect attempt (0 = first connection).
    public var attempt = 0

    public var steps: [Step] { includesRestore ? Step.allCases : [.connect, .authenticate, .startSession] }

    /// 0…1 for a progress bar.
    public var fraction: Double {
        let all = steps
        let index = Double(all.firstIndex(of: step) ?? 0)
        return min((index + 0.5) / Double(all.count), 0.97)
    }

    public init() {}

    /// Lines from ssh's own log file (`-E`), which nothing on the server can write into.
    var sshLog: [String] = []

    /// The server's host key differs from the trusted one (ssh refused to connect). Read only from
    /// ssh's own log: text printed by the server could imitate the warning.
    public var hostKeyChange: HostKeyChange? { HostKeyChange.parse(sshLog) }

    mutating func append(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    /// Updates the step from one line of `ssh -v` output.
    mutating func ingest(_ raw: String) {
        let line = raw.hasPrefix("debug1: ") ? String(raw.dropFirst(8)) : raw
        append(line)
        sshLog.append(line)
        if sshLog.count > 400 { sshLog.removeFirst(sshLog.count - 400) }
        if let m = line.firstMatch(of: #/^Connecting to (\S+) \[([^\]]+)\] port (\d+)/#) {
            let host = String(m.1)
            if !hops.contains(host) { hops.append(host) }
            step = .connect
            detail = "Connecting to \(host) (\(m.2), port \(m.3))"
        } else if line.contains("Setting implicit ProxyCommand from ProxyJump") || line.contains("Executing proxy command") {
            detail = "Starting jump host connection"
        } else if line.hasPrefix("Connection established") {
            detail = "Connected — negotiating encryption"
        } else if line.hasPrefix("Server host key:") {
            detail = "Verifying the server's host key"
        } else if let m = line.firstMatch(of: #/^Authenticating to (\S+?):\d+ as '([^']+)'/#) {
            step = .authenticate
            detail = "Signing in to \(m.1) as \(m.2)"
        } else if let m = line.firstMatch(of: #/^Next authentication method: (\S+)/#) {
            step = .authenticate
            detail = switch m.1 {
            case "publickey": "Trying SSH keys"
            case "password": "Password required"
            case "keyboard-interactive": "Waiting for verification (password / code)"
            default: "Trying \(m.1)"
            }
        } else if let m = line.firstMatch(of: #/^(?:Offering public key|Will attempt key): (\S+)/#) {
            detail = "Trying key \((String(m.1) as NSString).lastPathComponent)"
        } else if let m = line.firstMatch(of: #/^Authenticated to (\S+) .*using "([^"]+)"/#) {
            detail = "Signed in to \(m.1) with \(m.2)"
        } else if line.hasPrefix("Entering interactive session") || line.contains("Sending command") {
            step = .startSession
            detail = "Opening a shell"
        }
        if let (problem, hint) = Self.diagnose(line) {
            failure = problem
            self.hint = hint
        }
    }

    /// Recognises well-known ssh failures and suggests what to do.
    public static func diagnose(_ line: String) -> (String, String)? {
        let l = line.lowercased()
        if l.contains("permission denied") {
            return ("The server rejected the sign-in.", "Check the user name, password or key. Use “Edit Host…” or “Set Up SSH Key…”.")
        }
        if l.contains("could not resolve hostname") {
            return ("The host name could not be resolved.", "Check the host name, your DNS or VPN connection.")
        }
        if l.contains("connection timed out") || l.contains("operation timed out") {
            return ("The server did not answer in time.", "Check the address and port, firewalls, VPN or the jump host.")
        }
        if l.contains("connection refused") {
            return ("The server refused the connection.", "SSH may not be running on that port, or a firewall blocks it.")
        }
        if l.contains("no route to host") || l.contains("network is unreachable") {
            return ("The server is unreachable from this network.", "Check your network, VPN or whether a jump host is needed.")
        }
        if l.contains("host key verification failed") || l.contains("remote host identification has changed") {
            return ("The server's host key does not match the one you trusted before.",
                    "This happens when a server is reinstalled or its keys are replaced — or when someone intercepts the connection. Only continue if you know why it changed.")
        }
        if l.contains("too many authentication failures") {
            return ("Too many keys were offered.", "Set an explicit key for this host (IdentitiesOnly) in “Edit Host…”.")
        }
        if l.contains("kex_exchange_identification") || l.contains("connection closed by remote host") {
            return ("The server closed the connection during the handshake.",
                    "It may be overloaded, blocking your address, or the port is not SSH.")
        }
        return nil
    }
}

/// Opens the shared (ControlMaster) connection for a host as a separate step, reading `ssh -v`
/// from a log file so progress can be shown without anything appearing in the terminal.
@MainActor
final class MasterConnector {
    private var process: Process?
    private var timer: Timer?
    private var offset: UInt64 = 0
    private var partial = ""
    private let logURL: URL

    init() {
        logURL = AppPaths.controlSocketDirectory.appendingPathComponent("connect-\(UUID().uuidString.prefix(8)).log")
    }

    /// Returns nil on success, or the last error lines.
    func connect(target: ConnectionTarget, options: SSHOptions, environment: [String: String],
                 onLine: @escaping (String) -> Void) async -> String? {
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: options.sshBinary)
        // `exit` runs once (it works in sh, cmd and PowerShell alike); with ControlMaster=auto +
        // ControlPersist the connection stays up as master.
        p.arguments = options.commonOptions() + ["-v", "-E", logURL.path, "-o", "ConnectTimeout=20", "-T"]
            + SSHOptions.destinationArguments(for: target) + ["exit"]
        p.environment = ChildEnvironment.base.merging(environment) { $1 }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        process = p
        let poll = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readLog(onLine) }
        }
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
        let status: Int32 = await withCheckedContinuation { cont in
            // Ended by a signal (Tether stopped a login nobody answered): a failure, whatever the number.
            p.terminationHandler = { cont.resume(returning: $0.terminationReason == .uncaughtSignal ? -2 : $0.terminationStatus) }
            do {
                try p.run()
                AskPassBridge.shared.bindToken(environment, pid: p.processIdentifier)
            } catch { p.terminationHandler = nil; cont.resume(returning: -1) }
        }
        readLog(onLine)
        timer?.invalidate()
        timer = nil
        process = nil
        // The master keeps logging to this file; remove the name so nothing accumulates.
        try? FileManager.default.removeItem(at: logURL)
        // ssh itself fails with 255; any other code is `exit`'s own answer — the login worked (a
        // device CLI may not know `exit`, or may report it as an error).
        if status == -2 { return "The sign-in was stopped" }
        return status >= 0 && status != 255 ? nil : "ssh exited with code \(status)"
    }

    func cancel() {
        process?.terminate()
    }

    private func readLog(_ onLine: (String) -> Void) {
        guard let h = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        guard let data = try? h.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)
        let text = partial + String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        partial = lines.removeLast()
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { onLine(t) }
        }
    }
}
