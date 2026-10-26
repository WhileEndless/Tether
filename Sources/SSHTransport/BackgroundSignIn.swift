import Foundation

/// Hosts where background work (monitoring, latency, the platform check) found that signing in
/// needs the user: a password (or a key's passphrase) or a host key not seen yet. Background work
/// then skips the host — no ssh is started, so no failed logins pile up in the server's log (and no
/// fail2ban ban) — until a tab signs in; its shared connection serves background work from then on.
public final class BackgroundSignIn: @unchecked Sendable {
    public static let shared = BackgroundSignIn()

    public enum Reason: Sendable {
        /// The server wants a password, or the key needs its passphrase.
        case password
        /// The server's identity (host key) has not been confirmed yet.
        case hostKey
    }

    /// Prefix of every message background work reports for a waiting host (panels recognise it).
    public static let marker = "Sign in to see this host's details"

    /// What the host panel says, by reason; without connection sharing a tab cannot help.
    public static func message(_ reason: Reason, sharing: Bool) -> String {
        guard sharing else {
            return marker + ": live details need connection sharing (Settings ▸ SSH), because Tether asks for passwords only in tabs you open."
        }
        switch reason {
        case .password: return marker + ": this server asks for a password, and Tether asks for one only in tabs you open."
        case .hostKey: return marker + ": Tether has not confirmed this server's identity yet. Open a terminal to it once."
        }
    }

    private let lock = NSLock()
    private var waiting: [String: Reason] = [:]

    public func isWaiting(_ key: String) -> Bool { reason(key) != nil }

    public func reason(_ key: String) -> Reason? {
        lock.lock(); defer { lock.unlock() }
        return waiting[key]
    }

    public func markWaiting(_ key: String, reason: Reason = .password) {
        lock.lock(); waiting[key] = reason; lock.unlock()
    }

    /// A tab signed in (or the user changed something): background work may try again.
    public func clear(_ key: String) {
        lock.lock(); waiting[key] = nil; lock.unlock()
    }

    /// Why a BatchMode ssh exit needed someone, from ssh's own lines only (a remote program's
    /// "Permission denied" while reading /proc must not count). nil: some other failure.
    public static func reasonFor(stderr: String) -> Reason? {
        for line in stderr.split(whereSeparator: \.isNewline) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("Host key verification failed") { return .hostKey }
            if l.range(of: #"Permission denied \((publickey|password|keyboard-interactive|gssapi|hostbased)"#, options: .regularExpression) != nil
                || l.hasPrefix("Received disconnect") && l.contains("Too many authentication failures")
                || l.contains("No more authentication methods to try") {
                return .password
            }
        }
        return nil
    }

    public static func needsInteraction(_ stderr: String) -> Bool { reasonFor(stderr: stderr) != nil }

    /// Notes the outcome of a quiet (BatchMode) ssh: an exit that needed the user marks the host.
    func noteQuietResult(_ key: String, status: Int32, stderr: String) {
        if status == 255, let reason = Self.reasonFor(stderr: stderr) { markWaiting(key, reason: reason) }
    }
}

extension RemoteExecutor {
    /// Whether quiet background work may start an ssh for this host now: not when the host is known
    /// to need the user, unless a tab's shared connection is up again (then the mark is dropped).
    public func backgroundWorkAllowed() async -> Bool {
        let key = target.key
        guard !target.isLocal, BackgroundSignIn.shared.isWaiting(key) else { return true }
        if await isMasterAlive() {
            BackgroundSignIn.shared.clear(key)
            return true
        }
        return false
    }

    /// What background work says while it waits for a sign-in (see `BackgroundSignIn.message`).
    public var backgroundWaitingMessage: String {
        BackgroundSignIn.message(BackgroundSignIn.shared.reason(target.key) ?? .password, sharing: options.useControlMaster)
    }
}
