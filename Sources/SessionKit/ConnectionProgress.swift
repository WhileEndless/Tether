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
    /// What ssh itself said (its errors and warnings), without its `-v` steps: those name files
    /// that are not there on every connection (`load_hostkeys: fopen …/known_hosts2: No such file
    /// or directory`), which says nothing about why a connection failed.
    public private(set) var sshSaid: [String] = []

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
        if !raw.hasPrefix("debug") {
            sshSaid.append(raw)
            if sshSaid.count > 100 { sshSaid.removeFirst(sshSaid.count - 100) }
        }
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
        // A clearer cause said before is kept: the jump host's "cannot reach the server" is
        // followed by ssh's generic "connection closed during the handshake".
        if let (problem, hint) = Self.diagnose(line), Self.rank(line) >= failureRank {
            failure = problem
            self.hint = hint
            failureRank = Self.rank(line)
        }
    }

    private var failureRank = 0

    /// How much a line says about the cause: what the jump host said beats the generic end that
    /// follows it.
    static func rank(_ line: String) -> Int {
        // The jump host's line with its reason beats ssh's "stdio forwarding failed" after it.
        if SSHFailure.jumpFailureReason(line) != nil { return 4 }
        if SSHFailure.isJumpCannotReachTarget(line) { return 3 }
        let l = line.lowercased()
        if l.contains("kex_exchange_identification") || l.contains("connection closed by") { return 1 }
        return 2
    }

    /// The most telling diagnosis among `lines` (the last of the most telling, as ssh said them).
    public static func diagnose(lines: [String]) -> (String, String)? {
        var best: (rank: Int, found: (String, String))?
        for line in lines {
            guard let found = diagnose(line) else { continue }
            let r = rank(line)
            if best == nil || r >= best!.rank { best = (r, found) }
        }
        return best?.found
    }

    /// ssh's words for a server it could not reach at all (no answer, refused, no route, no such
    /// name, the connection closed before ssh's greeting): the same for every tab to that server,
    /// unlike a refused sign-in or a cancelled question, which belong to one login.
    public static func isUnreachable(_ text: String) -> Bool { SSHFailure.isUnreachable(text) }

    /// Recognises well-known ssh failures and suggests what to do.
    public static func diagnose(_ line: String) -> (String, String)? {
        let l = line.lowercased()
        // Before the plain words below ("connection refused", "no route to host"): here they are
        // the jump host's about the server behind it, not this Mac's about the jump host.
        if SSHFailure.isJumpCannotReachTarget(line) {
            if l.contains("administratively prohibited") {
                return ("The jump host does not allow connections through it to this server.",
                        "Its sshd may forbid forwarding (AllowTcpForwarding), or only allow some destinations.")
            }
            let why = SSHFailure.jumpFailureReason(line).map { " (\($0))" } ?? ""
            return ("The jump host answered, but could not reach the server\(why).",
                    "Check the server's address and port as the jump host sees them, and that the server is up.")
        }
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
