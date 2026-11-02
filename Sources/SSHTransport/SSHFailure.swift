import Foundation

/// What ssh's own words say about a failure — one place for the phrases ssh, scp and the server
/// use, so every feature reads them the same way.
///
/// The questions are different on purpose, and so are their answers:
/// - `isNetwork`: the way to the server failed, so a sign-in was not judged by it (a remembered
///   password stays). A refused or reset connection is *not* one: a server may hang up instead of
///   saying no.
/// - `isUnreachable`: the server cannot be reached now (tried again in shared rounds per host).
/// - `isBrokenConnection`: a connection that was there broke off (tried again, whatever was said
///   before it).
/// - `isPermanent`: will not pass by itself (a refused sign-in, a host name that does not exist, a
///   changed host key, a broken ssh_config).
/// - `isLostSharedConnection`: a client of a shared connection found no master there.
/// - `isLostDuringTransfer`: a running copy lost its connection.
/// - `isJumpCannotReachTarget`: the jump host answered, but could not reach the server behind it.
public enum SSHFailure {
    /// A jump host (ProxyJump) answered, but could not reach the server behind it: ssh's
    /// `channel 0: open failed: connect failed: …` and `stdio forwarding failed`. Checked before
    /// `isSessionRefused`: a jump host that is up says nothing about the server's session limit.
    public static func isJumpCannotReachTarget(_ text: String) -> Bool {
        let l = text.lowercased()
        return l.contains("stdio forwarding failed") || (l.contains("channel") && l.contains("open failed: connect failed"))
    }

    /// One sentence for why ssh could not get a command to `host`, for messages outside a tab
    /// (a file listing, a check): nil when its words are not one of the well-known failures (they
    /// are then shown as they are).
    public static func describe(_ text: String, host: String) -> String? {
        if isJumpCannotReachTarget(text) {
            return "The jump host could not reach \(host)" + (jumpFailureReason(text).map { " (\($0))." } ?? ".")
        }
        if isNameNotFound(text) { return "The name \(host) could not be resolved (check its name, DNS or VPN)." }
        if contains(text, ["connection timed out", "operation timed out"]) { return "\(host) did not answer (timed out)." }
        if contains(text, ["no route to host", "network is unreachable", "host is down"]) { return "\(host) cannot be reached from this network." }
        if contains(text, ["connection refused"]) { return "\(host) refused the connection." }
        if isLostSharedConnection(text) { return "The connection to \(host) ended; it is opened again on the next try." }
        if isRefusedSignIn(text) { return "\(host) did not accept the sign-in." }
        return nil
    }

    /// What the jump host said about reaching the server ("No route to host"), when it said it.
    public static func jumpFailureReason(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            guard let r = line.range(of: "open failed: connect failed:", options: .caseInsensitive) else { continue }
            let why = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if !why.isEmpty { return why }
        }
        return nil
    }

    public static func isNetwork(_ text: String) -> Bool {
        contains(text, ["operation timed out", "connection timed out", "network is unreachable", "network is down",
                        "no route to host", "host is down", "can't assign requested address",
                        "could not resolve hostname", "nodename nor servname"])
    }

    public static func isUnreachable(_ text: String) -> Bool {
        contains(text, ["connection timed out", "operation timed out", "connection refused", "no route to host",
                        "network is unreachable", "host is down", "could not resolve hostname",
                        "kex_exchange_identification", "banner exchange"]) || isJumpCannotReachTarget(text)
    }

    public static func isBrokenConnection(_ line: String) -> Bool {
        contains(line, ["broken pipe", "connection reset", "connection closed", "timed out", "network is unreachable",
                        "no route to host", "host is down"])
    }

    public static func isNameNotFound(_ text: String) -> Bool {
        contains(text, ["could not resolve hostname"])
    }

    public static func isPermanent(_ text: String) -> Bool {
        let l = text.lowercased()
        // A key file named in ssh_config that is not there is skipped, not a failure.
        if l.contains("no such identity") || (l.contains("identity file") && l.contains("not accessible")) { return false }
        return contains(l, ["permission denied", "could not resolve hostname", "host key verification failed", "no such file",
                            "bad configuration", "too many authentication failures"])
    }

    /// The server (or ssh, for a host key) said no to the sign-in.
    public static func isRefusedSignIn(_ text: String) -> Bool {
        contains(text, ["permission denied (", "too many authentication failures", "host key verification failed",
                        "no more authentication methods"])
    }

    /// The server's limit of sessions per connection (MaxSessions), not a lost connection.
    public static func isSessionRefused(_ text: String) -> Bool {
        contains(text, ["session open refused", "administratively prohibited", "session request failed"])
    }

    /// A client of a shared connection (ProxyCommand `/usr/bin/false`) found no master: it ended at
    /// once, or the socket refused it.
    public static func isLostSharedConnection(_ text: String) -> Bool {
        text.contains("UNKNOWN port 65535") || text.contains("Control socket connect")
    }

    /// What ssh and scp say when the connection went away under a running copy.
    public static func isLostDuringTransfer(_ text: String) -> Bool {
        let l = text.lowercased()
        return contains(l, ["broken pipe", "connection reset", "connection closed", "closed by remote host", "client_loop",
                            "lost connection", "connection timed out", "timeout, server", "read from master failed", "mux_client",
                            "network is unreachable", "no route to host", "connection refused", "control socket connect"])
            || (l.contains("connection to") && l.contains("closed"))
    }

    /// How an ssh that signed in by itself (no shared connection) ended, for what it was answered
    /// with (`SignInEnd`): stopped by Tether or timed out, or failed because the network did, the
    /// server judged nothing; ssh's own failure (255) otherwise counts as refused. A command's own
    /// words (a status other than 255) never count as the network's.
    public static func signInEnd(status: Int32, stderr: String, stopped: Bool) -> SignInEnd {
        if stopped || status < 0 { return .notJudged }
        if status == 255 { return isNetwork(stderr) ? .notJudged : .failed }
        return .succeeded
    }

    private static func contains(_ text: String, _ phrases: [String]) -> Bool {
        let l = text.lowercased()
        return phrases.contains { l.contains($0) }
    }
}
