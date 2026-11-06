import Foundation
import TetherCore

/// A password / passphrase / confirmation prompt raised by ssh through SSH_ASKPASS.
public struct AskPassRequest: Sendable {
    public var token: String
    public var targetKey: String
    public var purpose: String
    /// ssh's question (fixed: what is worked out from it below is worked out once, in `init`).
    public let prompt: String
    /// The terminal tab whose login asks, if any (only the tab in front shows its prompt).
    public var sessionID: UUID? = nil
    /// How many prompts this token has produced so far (1-based). Used to detect wrong saved passwords.
    public var sequence: Int
    /// The process that asks (the helper's parent: the ssh itself, or the ssh ProxyJump started for
    /// a jump host, which has the same token). 0 when unknown.
    public var askerPID: Int32 = 0
    /// What ssh set `SSH_ASKPASS_PROMPT` to: "confirm" for a yes/no question (AddKeysToAgent=ask),
    /// "none" for a notice that needs no answer (touch the security key); nil for a question.
    public var askpassKind: String? = nil
    /// The ssh asking is one that marks a server's own questions (OpenSSH 8.4 and later; checked by
    /// its program file, see `AskingProcess`): only then is a passphrase question known to be its own.
    public var askerNamesItsQuestions = false
    /// The key file named by ssh's own passphrase prompt (`Enter passphrase for key '/path':`).
    public let keyPath: String?
    /// `keyPath` is a file on this Mac and the question is not marked as a server's.
    private let namesLocalKeyFile: Bool

    public init(token: String, targetKey: String, purpose: String, prompt: String, sequence: Int) {
        self.token = token
        self.targetKey = targetKey
        self.purpose = purpose
        self.prompt = prompt
        self.sequence = sequence
        // Looked at once (file checks, and for a cut path a walk through folders), here — off the
        // main thread when the bridge makes the request — not each time a view asks.
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = p.wholeMatch(of: #/Enter passphrase for (?:key )?'(.+)': ?/#).map { Self.untruncated(String($0.1)) }
        keyPath = path
        var isDir: ObjCBool = false
        namesLocalKeyFile = path.map { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath, isDirectory: &isDir) && !isDir.boolValue } == true
            && p.prefixMatch(of: Self.serverPrefix) == nil
    }

    /// A notice ssh shows while it waits (a security key's "Confirm user presence"): no answer is
    /// read; ssh ends the helper when it is done.
    public var isNotice: Bool { askpassKind == "none" }

    /// A yes/no question ssh asks for itself (`Add key … to agent?`): "yes" allows, anything else
    /// does not.
    public var isPermissionQuestion: Bool { askpassKind == "confirm" && !isServerText }

    public var isSecret: Bool {
        guard askpassKind == nil else { return false }
        let p = prompt.lowercased()
        return p.contains("password") || p.contains("passphrase") || p.contains("pin") || p.contains("verification code")
    }

    public var isPasswordPrompt: Bool { prompt.lowercased().contains("password") }

    /// ssh's `(user@host) ` before a keyboard-interactive question. The user part may hold "@" (a
    /// directory account such as `user@corp.example.com`); the host never does.
    static let serverPrefix = #/\(([^\s()]+)@([^@)\s]+)\) /#

    /// What the server asks after ssh's `(user@host) ` prefix; nil without the prefix.
    public var serverQuestion: String? {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = p.prefixMatch(of: Self.serverPrefix) else { return nil }
        return String(p[m.range.upperBound...])
    }

    /// Words of a question for something other than the account's password: a one-time code, a
    /// second factor, a new or changed password. Matched as whole words, case-insensitively.
    static let notLoginWords: Set<String> = ["otp", "onetime", "new", "current", "old", "verification", "verify", "code",
                                             "token", "passcode", "confirm", "retype", "repeat", "again", "temporary",
                                             "expired", "2fa", "mfa", "totp", "pin", "challenge", "yubikey", "sms",
                                             "push", "second", "factor", "duo"]

    /// A password question for the account's own password — ssh's `user@host's password:`, or a
    /// server's question that asks for a password and for nothing else (not a one-time code, not a
    /// new password). Only these are filled from the keychain, counted as refused when asked again,
    /// and saved.
    public var isLoginPasswordPrompt: Bool {
        guard askpassKind == nil, isPasswordPrompt else { return false }
        if isOwnPasswordQuestion { return true }
        var text = (serverQuestion ?? prompt).lowercased()
        // "Password for user@REALM:" names an account, whose name says nothing about the question.
        text = text.replacing(#/ for [^\s:]+/#, with: "")
        if text.contains("one-time") || text.contains("one time") { return false }
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return !words.contains { Self.notLoginWords.contains($0) }
    }

    /// ssh's own `user@host's password:` (password authentication: never server text).
    private var isOwnPasswordQuestion: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of: #/[^\s'()]+@[^@'\s()]+'s password:/#) != nil
    }

    /// A password question from an ssh that does not mark a server's questions (before OpenSSH 8.4,
    /// or one that could not be checked — a ProxyCommand may run another ssh): a jump host could
    /// have written it. Never answered by itself, from the keychain or from memory.
    public var isUnverifiedPasswordPrompt: Bool { askpassKind == nil && isPasswordPrompt && !askerNamesItsQuestions }

    /// ssh's own password question (`user@host's password:`, or keyboard-interactive's plain
    /// `(user@host) Password:`) — not a one-time code or "New password:" a server asks for, which
    /// must never be remembered or replayed.
    ///
    /// Also `(user@host) password:` in any case and `(user@host) Password for <account>:`, as PAM
    /// stacks word it.
    public var isPlainPasswordPrompt: Bool {
        if isOwnPasswordQuestion { return true }
        guard let question = serverQuestion else { return false }
        return question.wholeMatch(of: #/password(?: for [^\s:]+)?:/#.ignoresCase()) != nil
    }

    /// ssh puts `(user@host) ` before every keyboard-interactive prompt: what follows was written by
    /// the server, so it is never treated as ssh's own key-passphrase or host-key question.
    public var isServerText: Bool {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefixMatch(of: Self.serverPrefix) != nil
    }

    /// `Enter passphrase for key '/path/to/key':` exactly as ssh writes it (never server text), for a
    /// key file that exists on this Mac, asked by an ssh that marks a server's questions.
    public var isPassphrasePrompt: Bool { askpassKind == nil && namesLocalKeyFile && askerNamesItsQuestions }

    /// The account's own password or a key's passphrase: what a saved or remembered answer may be
    /// sent to, counted as refused when asked again, and saved (never a one-time code or a new password).
    public var isSecretOfTheAccount: Bool { isLoginPasswordPrompt || isPassphrasePrompt }

    /// What a remembered answer is filled into: ssh's plain password question or a key's passphrase.
    public var takesRememberedAnswer: Bool { isPlainPasswordPrompt || isPassphrasePrompt }

    /// Worded as ssh's question for a key on this Mac, but asked by an ssh that does not mark a
    /// server's questions (before OpenSSH 8.4, or one that could not be checked): the server may
    /// have written it. Never answered from the keychain, never saved under the key.
    public var isUnverifiedPassphrasePrompt: Bool { askpassKind == nil && namesLocalKeyFile && !askerNamesItsQuestions }

    /// ssh writes at most 100 bytes of the key's path in its prompt: a longer path is completed to
    /// the one file on this Mac that it starts (otherwise it stays as written).
    static func untruncated(_ path: String) -> String {
        let fm = FileManager.default
        let expanded = (path as NSString).expandingTildeInPath
        guard path.utf8.count == 100, !fm.fileExists(atPath: expanded) else { return path }
        // The deepest folder that exists whole; the cut is somewhere below it.
        var base = (expanded as NSString).deletingLastPathComponent
        while !base.isEmpty, base != "/", !fm.fileExists(atPath: base) { base = (base as NSString).deletingLastPathComponent }
        guard base.count > 1, let walk = fm.enumerator(atPath: base) else { return path }
        var found: [String] = []
        var seen = 0
        while let rel = walk.nextObject() as? String, seen < 5_000, found.count < 2 {
            seen += 1
            if walk.level > 6 { walk.skipDescendants(); continue }
            let full = (base as NSString).appendingPathComponent(rel)
            guard full.hasPrefix(expanded) || expanded.hasPrefix(full) else { walk.skipDescendants(); continue }
            var isDir: ObjCBool = false
            if full.hasPrefix(expanded), !full.hasSuffix(".pub"), fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
                found.append(full)
            }
        }
        return found.count == 1 ? found[0] : path
    }

    /// ssh's own host-key question (`… continue connecting (yes/no/[fingerprint])?`), not server text.
    public var isConfirmation: Bool {
        guard askpassKind == nil, !isServerText else { return false }
        let p = prompt.lowercased()
        return p.contains("continue connecting") && p.contains("(yes/no")
    }

    /// The host this prompt is for, taken only from text the local ssh writes itself — never from
    /// text a server can choose. ssh asks `user@host's password:` for password authentication and
    /// puts `(user@host) ` before every keyboard-interactive prompt, whose remaining text comes from
    /// the server (which could otherwise write "root@other-host's password:" to obtain the saved
    /// password of another host). nil when the prompt does not say.
    public var sshNamedHost: String? { sshNamedLogin?.host }

    /// The user and host ssh names in the prompt (same rules as `sshNamedHost`).
    public var sshNamedLogin: (user: String, host: String)? {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = p.wholeMatch(of: #/([^\s'()]+)@([^@'\s()]+)'s password:/#) { return (String(m.1), String(m.2)) }
        if let m = p.prefixMatch(of: Self.serverPrefix) { return (String(m.1), String(m.2)) }
        return nil
    }
}

/// Handles askpass prompts. Return nil to cancel.
public typealias AskPassHandler = @Sendable (AskPassRequest) async -> String?

/// Bridges ssh's SSH_ASKPASS mechanism to the app.
///
/// ssh runs the small `tether-askpass` helper, which connects to a Unix socket owned by the app and
/// forwards the prompt along with a per-process token. The app answers from the keychain or by
/// asking the user. Secrets never appear in command lines or files.
public final class AskPassBridge: @unchecked Sendable {
    public static let shared = AskPassBridge()

    private struct Context {
        var targetKey: String
        var purpose: String
        var count: Int
        var sessionID: UUID? = nil
        /// The helper hung up while its prompt waited: nobody can use an answer any more.
        var dead = false
        /// Answered without asking (a passphrase Tether hands to ssh-keygen / ssh-add itself).
        var fixedAnswer: String? = nil
        /// Answered without asking, by the prompt (`ssh-keygen -p` asks for the old passphrase,
        /// then twice for the new one).
        var answerFor: (@Sendable (String) -> String?)? = nil
        /// The processes this token was given to: only they (and what they start, e.g. the ssh for a
        /// jump host, then the helper) may use it.
        var pids: Set<pid_t> = []
        /// Questions sent to the app that have no answer yet.
        var asking = 0
        /// The question waiting now was put in front of the user (see `waitsOnUser`).
        var presented = false
        /// Answers sent back (also those given at once, from memory or the keychain).
        var answers = 0
    }

    private let lock = NSLock()
    private var contexts: [String: Context] = [:]
    private var listenFD: Int32 = -1
    private var handler: AskPassHandler?
    private var cancelHandler: (@Sendable (String) -> Void)?

    public var helperPath: String? {
        let dir = Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates = [dir?.appendingPathComponent("tether-askpass").path,
                          Bundle.main.path(forAuxiliaryExecutable: "tether-askpass")]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public var isAvailable: Bool { listenFD >= 0 && helperPath != nil }

    /// Starts listening. Call once at app launch. `cancel` gets a token whose prompt can no longer be
    /// answered (its ssh ended, gave up or was stopped): a prompt still on screen for it goes away.
    public func start(handler: @escaping AskPassHandler, cancel: (@Sendable (String) -> Void)? = nil) {
        lock.lock(); self.handler = handler; self.cancelHandler = cancel; lock.unlock()
        guard listenFD < 0 else { return }
        let path = AppPaths.askPassSocket.path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        // Not handed down to processes Tether starts.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { close(fd); return }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { strncpy($0, path, maxLen - 1) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard bound == 0, listen(fd, 16) == 0 else { close(fd); return }
        chmod(path, 0o600)
        listenFD = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    /// Registers a new token for one ssh process and returns the environment to give it.
    /// - Parameter mode: "force" for non-interactive processes, "prefer" to answer even with a TTY.
    public func environment(targetKey: String, purpose: String, mode: String = "force", sessionID: UUID? = nil) -> [String: String] {
        register(Context(targetKey: targetKey, purpose: purpose, count: 0, sessionID: sessionID), mode: mode)
    }

    /// For quiet background work: every prompt is refused at once. BatchMode on the command line
    /// does not reach the ssh that ProxyJump starts for the jump host; this does.
    public func refusingEnvironment(targetKey: String, purpose: String) -> [String: String] {
        register(Context(targetKey: targetKey, purpose: purpose, count: 0, answerFor: { _ in nil }))
    }

    /// The askpass environment for an ssh with this purpose (quiet work refuses every prompt).
    public func environment(for target: String, purpose: String) -> [String: String] {
        SSHOptions.isQuietPurpose(purpose) ? refusingEnvironment(targetKey: target, purpose: purpose)
                                           : environment(targetKey: target, purpose: purpose)
    }

    /// An environment whose prompts are all answered with `answer` (for ssh-keygen and ssh-add, so a
    /// passphrase never appears in a process's arguments). Revoke it when the process has finished.
    public func environment(answering answer: String, purpose: String) -> [String: String] {
        register(Context(targetKey: "", purpose: purpose, count: 0, fixedAnswer: answer))
    }

    /// An environment whose prompts are answered by `answer(prompt)` (several different passphrases
    /// for one process, such as `ssh-keygen -p`). Revoke it when the process has finished.
    public func environment(answers answer: @escaping @Sendable (String) -> String?, purpose: String) -> [String: String] {
        register(Context(targetKey: "", purpose: purpose, count: 0, answerFor: answer))
    }

    /// A new token for `context`, and the environment that makes ssh ask through it.
    private func register(_ context: Context, mode: String = "force") -> [String: String] {
        guard isAvailable, let helperPath else { return [:] }
        let token = UUID().uuidString
        lock.withLock { contexts[token] = context }
        return [
            "SSH_ASKPASS": helperPath,
            "SSH_ASKPASS_REQUIRE": mode,
            "DISPLAY": ProcessInfo.processInfo.environment["DISPLAY"] ?? "tether:0",
            "TETHER_ASKPASS_SOCKET": AppPaths.askPassSocket.path,
            "TETHER_ASKPASS_TOKEN": token,
        ]
    }

    /// Whether any question for this target waits for an answer right now.
    public func isAsking(targetKey: String) -> Bool {
        isAsking { $0 == targetKey }
    }

    /// Whether any question for a target `matches` accepts waits for an answer right now.
    public func isAsking(where matches: (String) -> Bool) -> Bool {
        let asking = lock.withLock { contexts.values.filter { $0.asking > 0 }.map(\.targetKey) }
        return asking.contains(where: matches)
    }

    /// Whether a question of the ssh given this environment waits for an answer right now.
    public func isAsking(environment env: [String: String]) -> Bool {
        guard let token = env["TETHER_ASKPASS_TOKEN"] else { return false }
        lock.lock(); defer { lock.unlock() }
        return (contexts[token]?.asking ?? 0) > 0
    }

    // MARK: Waiting on the user

    /// Touch ID (or the Mac's password) being asked for now: it answers every question waiting.
    private var userChecks = 0

    /// The question waiting for `token` was put in front of the user (its panel shown). It counts as
    /// such until it is answered, also while the panel hides because another app is in front (the
    /// user may be copying the password from a password manager).
    public func notePresented(token: String) {
        lock.withLock { if (contexts[token]?.asking ?? 0) > 0 { contexts[token]?.presented = true } }
    }

    /// Touch ID (or the Mac's password) is being asked for; call `endUserCheck` once it is answered.
    public func beginUserCheck() { lock.withLock { userChecks += 1 } }
    public func endUserCheck() { lock.withLock { userChecks = max(0, userChecks - 1) } }

    /// The one answer to "is a person being asked, so waiting is right?" for every watchdog: a
    /// question waits *and* the user can see it (or Touch ID is up). A question nobody was shown —
    /// held back for a tab in the background, or waiting for Tether to be unlocked — does not stop
    /// timeouts: what waits for it ends and tries again when the user comes back, instead of a
    /// connection hanging on "Connecting" with nothing on screen.
    public func waitsOnUser(environment env: [String: String]) -> Bool {
        guard let token = env["TETHER_ASKPASS_TOKEN"] else { return false }
        return lock.withLock {
            guard let ctx = contexts[token], ctx.asking > 0 else { return false }
            return ctx.presented || userChecks > 0
        }
    }

    /// Whether a question in front of the user is one this tab's sign-in waits for — also a jump
    /// host's on its way (`SignInInterest`), which is asked under the jump host's name.
    public func waitsOnUser(forSession id: UUID) -> Bool {
        presentedTokens().contains { SignInInterest.waiting(for: $0)?.sessions.contains(id) == true }
    }

    /// The same for work without a tab (a file listing, a transfer, a check): a question in front
    /// of the user that such work waits for.
    public func waitsOnUserForWorkWithoutTab() -> Bool {
        presentedTokens().contains { SignInInterest.waiting(for: $0)?.unowned == true }
    }

    private func presentedTokens() -> [String] {
        lock.withLock { contexts.filter { $0.value.asking > 0 && ($0.value.presented || userChecks > 0) }.map(\.key) }
    }

    /// `waitsOnUser` for any question of a target `matches` accepts.
    public func waitsOnUser(where matches: (String) -> Bool) -> Bool {
        let waiting = lock.withLock {
            contexts.values.filter { $0.asking > 0 && ($0.presented || userChecks > 0) }.map(\.targetKey)
        }
        return waiting.contains(where: matches)
    }

    /// How many answers the ssh given this environment has been sent so far.
    public func answerCount(environment env: [String: String]) -> Int {
        guard let token = env["TETHER_ASKPASS_TOKEN"] else { return 0 }
        lock.lock(); defer { lock.unlock() }
        return contexts[token]?.answers ?? 0
    }

    /// Whether an answer for this token can still reach its ssh (not revoked, helper still there).
    public func isLive(_ token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let ctx = contexts[token] else { return false }
        return !ctx.dead
    }

    /// Ends the ssh processes a token was given to (a login whose question waited so long that the
    /// server has closed it; ssh does not notice while it waits for the answer).
    /// Children first: an ssh killed during sign-in leaves its ProxyJump ssh running, which would
    /// go on to send empty passwords to the jump host.
    public func terminateProcesses(of token: String) {
        lock.lock(); let ctx = contexts[token]; lock.unlock()
        guard let ctx, !ctx.dead else { return }
        let roots = ctx.pids.filter { $0 > 0 }
        guard !roots.isEmpty else { return }
        for pid in Self.descendants(of: roots).reversed() { kill(pid, SIGTERM) }
        for pid in roots { kill(pid, SIGTERM) }
    }

    /// Every process below the given ones, parents before children.
    static func descendants(of roots: Set<pid_t>) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        var children: [pid_t: [pid_t]] = [:]
        for p in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            children[p.kp_eproc.e_ppid, default: []].append(p.kp_proc.p_pid)
        }
        var out: [pid_t] = []
        var queue = Array(roots)
        while let next = queue.first {
            queue.removeFirst()
            for child in children[next] ?? [] where !out.contains(child) && !roots.contains(child) {
                out.append(child)
                queue.append(child)
            }
        }
        return out
    }

    /// Ties a token to the process it was given to, right after that process started. A token read
    /// from the environment of a running ssh by some other program is then useless to it.
    public func bindToken(_ env: [String: String], pid: pid_t) {
        guard pid > 0, let token = env["TETHER_ASKPASS_TOKEN"] else { return }
        lock.lock(); contexts[token]?.pids.insert(pid); lock.unlock()
    }

    /// Forgets a token once its process has finished.
    public func revoke(environment env: [String: String]) {
        guard let token = env["TETHER_ASKPASS_TOKEN"] else { return }
        lock.lock(); contexts[token] = nil; let cancel = cancelHandler; lock.unlock()
        cancel?(token)
    }

    enum AcceptFailure: Equatable { case retryNow, retryLater, stop }

    /// What a failed `accept` means for the loop: only a socket that is no longer usable ends it.
    /// Before, any error ended it for good, and every later ssh question went unanswered.
    static func acceptFailure(_ code: Int32) -> AcceptFailure {
        switch code {
        case EINTR, ECONNABORTED: .retryNow
        case EBADF, EINVAL, ENOTSOCK, EOPNOTSUPP: .stop
        default: .retryLater   // EMFILE, ENFILE, ENOBUFS, ENOMEM and anything passing
        }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                switch Self.acceptFailure(errno) {
                case .retryNow: continue
                // Out of descriptors or buffers for a moment, or a helper that gave up while waiting:
                // the questions after it must still be answered.
                case .retryLater: usleep(100_000); continue
                case .stop: return
                }
            }
            // Only accept peers running as the same user, and only processes Tether started (ssh runs
            // the helper): another program of the same user that read a token from a process
            // environment cannot ask for a saved password.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid(), let peer = Self.peerPID(client),
                  Self.isDescendant(peer, of: getpid()) else { close(client); continue }
            // Answering a helper that is already gone (its ssh ended while the prompt was up) must
            // fail quietly: by default the write raises SIGPIPE, which ends the whole app.
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Not handed down to processes Tether starts: a child holding it would keep the helper's
            // end looking alive, and a prompt whose ssh has ended would not go away.
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            Thread.detachNewThread { [weak self] in self?.serve(client, peer: peer) }
        }
    }

    /// The connecting process descends from Tether (Tether → ssh → [ssh for a jump host …] → helper).
    static func peerIsOurs(_ fd: Int32) -> Bool {
        guard let pid = peerPID(fd) else { return false }
        return isDescendant(pid, of: getpid())
    }

    static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0, pid > 0 else { return nil }
        return pid
    }

    static func isDescendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        var current = pid
        for _ in 0..<16 {
            guard let parent = parentPID(of: current), parent > 1 else { return false }
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private func serve(_ fd: Int32, peer: pid_t) {
        defer { close(fd) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while !data.contains(0x0a) && data.count < 65536 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data.prefix(while: { $0 != 0x0a })) as? [String: String],
              let token = obj["token"], let prompt = obj["prompt"] else { return }

        // The peer must descend from a process this token was given to. Binding happens right after
        // launch; a prompt that comes even earlier waits a moment for it.
        var bound: Set<pid_t> = []
        for _ in 0..<60 {
            lock.lock(); let known = contexts[token]; lock.unlock()
            bound = known?.pids ?? []
            if !bound.isEmpty || known == nil { break }
            usleep(50_000)
        }
        guard bound.contains(where: { $0 == peer || Self.isDescendant(peer, of: $0) }) else { reply(fd, nil); return }

        lock.lock()
        guard var ctx = contexts[token] else { lock.unlock(); reply(fd, nil); return }
        ctx.count += 1
        contexts[token] = ctx
        let handler = self.handler
        lock.unlock()
        if let fixed = ctx.fixedAnswer { reply(fd, fixed); return }
        if let answer = ctx.answerFor { reply(fd, answer(prompt)); return }

        var request = AskPassRequest(token: token, targetKey: ctx.targetKey, purpose: ctx.purpose,
                                     prompt: prompt, sequence: ctx.count)
        request.sessionID = ctx.sessionID
        request.askerPID = Self.parentPID(of: peer) ?? 0
        if let kind = obj["kind"], ["confirm", "none"].contains(kind) { request.askpassKind = kind }
        lock.lock(); contexts[token]?.asking += 1; lock.unlock()
        defer {
            lock.lock()
            contexts[token]?.asking -= 1
            if contexts[token]?.asking == 0 { contexts[token]?.presented = false }
            lock.unlock()
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = AnswerBox()
        let asked = request
        Task {
            var request = asked
            // A question naming a key on this Mac is ssh's own only from an ssh that marks a
            // server's questions — the one asking, which may be a jump host's ssh found on PATH
            // or one a ProxyCommand ran, not only the one in Settings.
            // A password question too: a jump host reached through an older ssh (a ProxyCommand's)
            // can word its own question as the target's, and must not be answered with its password.
            if request.keyPath != nil || request.isPasswordPrompt {
                request.askerNamesItsQuestions = await AskingProcess.namesItsQuestions(pid: request.askerPID)
            }
            box.value = await handler?(request)
            semaphore.signal()
        }
        // While the user decides, watch the helper: when it goes away (ssh gave up, the server's
        // login time ran out, the tab was closed), the prompt is withdrawn instead of waiting for
        // an answer nobody can use.
        var withdrawn = false
        while semaphore.wait(timeout: .now() + 0.5) == .timedOut {
            if !withdrawn, Self.peerHungUp(fd) {
                withdrawn = true
                lock.lock(); contexts[token]?.dead = true; let cancel = cancelHandler; lock.unlock()
                cancel?(token)
            }
        }
        if !withdrawn {
            if box.value != nil { lock.lock(); contexts[token]?.answers += 1; lock.unlock() }
            reply(fd, box.value)
        }
    }

    /// The helper closed its end (it never writes after its request, so readable means closed).
    static func peerHungUp(_ fd: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
        guard poll(&p, 1, 0) > 0 else { return false }
        if p.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return true }
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
    }

    private final class AnswerBox: @unchecked Sendable { var value: String? }

    private func reply(_ fd: Int32, _ answer: String?) {
        let obj: [String: Any] = answer.map { ["ok": true, "answer": $0] } ?? ["ok": false]
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0a)
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }
}

/// The state of a terminal on this Mac, to tell whether a program on it is reading a secret.
public enum LocalTTY {
    /// The terminal device a process on this Mac belongs to (`/dev/ttys003`), or nil.
    public static func path(ofProcess pid: Int32) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard pid > 0, sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let dev = info.kp_eproc.e_tdev
        guard dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    /// Whether the terminal waits for a typed secret: line-by-line input with echo off, as a
    /// program on this Mac reading a passphrase sets it (ssh's own `readpassphrase`). A connected
    /// ssh puts its terminal into raw mode instead, so text a server prints — even worded as a key
    /// passphrase prompt — never makes this true. nil when the terminal cannot be looked at.
    public static func isReadingSecret(path: String) -> Bool? {
        let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { return nil }
        return t.c_lflag & tcflag_t(ECHO) == 0 && t.c_lflag & tcflag_t(ICANON) != 0
    }

    /// The program files of the terminal's foreground process group (what reads typed input).
    public static func foregroundPrograms(path: String) -> [String]? {
        let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let pgid = tcgetpgrp(fd)
        guard pgid > 0 else { return nil }
        let programs = AskingProcess.group(pgid).compactMap(AskingProcess.executablePath)
        return programs.isEmpty ? nil : programs
    }

    /// Why a key's passphrase must not be typed into this terminal now, or nil when it may: an
    /// ssh tool on this Mac reads it (line mode, echo off) and every ssh among the programs reading
    /// is one that marks a server's questions — an older ssh shows a server's keyboard-interactive
    /// question, worded as this key's prompt, in exactly that state.
    public static func refusalToTypeKeyPassphrase(path: String) async -> String? {
        guard isReadingSecret(path: path) == true else {
            return "This terminal is not waiting for a passphrase on this Mac. The prompt may have been printed by a server that ssh is connected to."
        }
        guard let programs = foregroundPrograms(path: path) else { return "Tether cannot tell which program is asking." }
        let names = programs.map { ($0 as NSString).lastPathComponent }
        guard names.contains(where: ["ssh", "ssh-add", "ssh-keygen"].contains) else {
            return "No ssh program on this Mac is asking (\(names.joined(separator: ", ")))."
        }
        for program in programs where (program as NSString).lastPathComponent == "ssh" {
            guard await SSHVersionCheck.shared.namesItsQuestions(path: program) else {
                return "The ssh asking (\(program)) is older than OpenSSH 8.4: it does not mark a server's questions, so this one may come from the server."
            }
        }
        return nil
    }
}

/// Processes on this Mac: which program they run, and which ssh among them can be trusted to mark
/// a server's questions.
public enum AskingProcess {
    /// The program file a process runs (symbolic links resolved), or nil.
    public static func executablePath(_ pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return n > 0 ? String(cString: buffer) : nil
    }

    /// Whether this process is an ssh that marks a server's questions (OpenSSH 8.4 or later). A
    /// program not named `ssh` is never asked (`-V` could mean anything to it).
    public static func namesItsQuestions(pid: Int32) async -> Bool {
        guard let path = executablePath(pid), (path as NSString).lastPathComponent == "ssh" else { return false }
        return await SSHVersionCheck.shared.namesItsQuestions(path: path)
    }

    /// The processes of a process group.
    public static func group(_ pgid: Int32) -> [Int32] {
        guard pgid > 0 else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride + 8
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map(\.kp_proc.p_pid)
    }
}
