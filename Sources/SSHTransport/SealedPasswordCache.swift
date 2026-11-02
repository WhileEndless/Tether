import Foundation
import Security
import CryptoKit

/// Encrypts and decrypts with a key the process cannot read (see `SecureEnclaveSealer`).
public protocol PasswordSealer: Sendable {
    func seal(_ plain: Data) -> Data?
    func open(_ sealed: Data) -> Data?
}

/// A P-256 key created inside the Secure Enclave for this run of the app only: not saved anywhere,
/// not exportable, gone when the app quits. Data sealed with it can be opened only by this process
/// on this Mac, so a copy of the app's memory — a dump, a swap file — holds nothing usable.
public final class SecureEnclaveSealer: PasswordSealer, @unchecked Sendable {
    private let privateKey: SecKey
    private let publicKey: SecKey
    private static let algorithm = SecKeyAlgorithm.eciesEncryptionCofactorVariableIVX963SHA256AESGCM

    /// nil on a Mac without a Secure Enclave (Intel without T2) or when it is unavailable.
    ///
    /// Usable after the first unlock, also while the screen is locked: a connection that ended while
    /// the user was away is signed in again before they are back. Only this process holds the key.
    public init?() {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error)
        else { return nil }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false, kSecAttrAccessControl as String: access],
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error), let pub = SecKeyCopyPublicKey(key) else { return nil }
        privateKey = key
        publicKey = pub
    }

    public func seal(_ plain: Data) -> Data? {
        SecKeyCreateEncryptedData(publicKey, Self.algorithm, plain as CFData, nil) as Data?
    }

    public func open(_ sealed: Data) -> Data? {
        SecKeyCreateDecryptedData(privateKey, Self.algorithm, sealed as CFData, nil) as Data?
    }
}

/// A key made in memory for this run only (AES-GCM), on a Mac without a Secure Enclave: used for
/// the minute a typed answer is handed to further sign-ins of the same connection, never for
/// passwords remembered longer (those need the Secure Enclave).
public final class MemorySealer: PasswordSealer, @unchecked Sendable {
    private let key = SymmetricKey(size: .bits256)
    public init() {}
    public func seal(_ plain: Data) -> Data? { try? AES.GCM.seal(plain, using: key).combined }
    public func open(_ sealed: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}

/// How a sign-in ended, for what it was answered with (see `SealedPasswordCache.discard`).
public enum SignInEnd: Sendable, Equatable {
    case succeeded
    /// The server said no, or hung up after an answer was sent (fail2ban, pam_faillock, network
    /// devices hang up instead of asking again): what was sent is not sent again.
    case failed
    /// Ended before the server could judge what it was sent: the way to it failed (no answer, no
    /// route, the network changed), or Tether stopped it (a tab closed, Retry, a sign-in stuck before
    /// any question, Tether locked). What was answered stays.
    case notJudged
    /// An answer was sent and the server then said nothing at all until Tether gave up: perhaps a
    /// slow server, perhaps one that goes silent instead of refusing. A remembered password is sent
    /// once more, then forgotten.
    case unanswered
}

/// Sign-in passwords remembered while the app runs, so one typed password signs in every
/// connection the same server needs — further shared connections past the server's session limit,
/// reconnects after the connection really ended — without asking again.
///
/// Rules (see docs/connections-and-passwords.md):
/// - Only sealed (`PasswordSealer`); nothing unsealed is ever kept.
/// - Per connection: an entry belongs to the connection the sign-in was for (`bind`:
///   `SharedConnections.Resolution.identity` — host name, port, user and jump hosts as ssh works them
///   out) and to the login ssh named in its question (the caller's `savedPasswordKey`). Another port,
///   another jump host, another user is another entry — a password is never offered to a different
///   server.
/// - Kept only after the sign-in it was given to succeeded (`commit`); dropped when refused.
/// - A typed answer is handed to the same connection's other sign-ins for a minute (`handOff`),
///   also with remembering turned off: the further connections a server needs, a file window, a
///   retry — one question per server, not one per connection.
/// - Kept through sleep and screen lock (unless *Also forget them when the screen locks* is on),
///   also one first read from the keychain: Touch ID is asked when the keychain is read, not again
///   for every reconnect while it is remembered.
/// - Never one-time codes or new-password questions; never terminal prompts such as sudo.
public final class SealedPasswordCache: @unchecked Sendable {
    public enum Source: Sendable { case typed, keychain }

    private struct Entry {
        var sealed: Data
        var source: Source
        var login: String
        /// The user@host ssh named in its question: the same server reached under another name
        /// (another alias, Quick Connect) finds it too.
        var named: String?
        var at = Date()
        /// Sent once and never judged (`SignInEnd.unanswered`): sent at most once more.
        var unconfirmed = false
    }

    /// What the settings show for an entry (never the password).
    public struct Item: Identifiable, Sendable {
        public var id: String
        public var login: String
        public var since: Date
        public var fromKeychain: Bool
    }
    private struct Pending { var key: String; var entry: Entry; var at: TimeInterval }
    /// A typed answer handed to the same connection's further sign-ins for a short while.
    private struct HandOff { var entry: Entry; var until: TimeInterval }

    private let lock = NSLock()
    private let sealer: PasswordSealer?
    private var entries: [String: Entry] = [:]
    /// Given to a sign-in still in progress, by askpass token and entry: kept once that sign-in
    /// succeeded. One sign-in can be given several (a key's passphrase, then the server's password;
    /// a jump host's and the target's).
    private var pending: [String: [String: Pending]] = [:]
    private var handOffs: [String: HandOff] = [:]
    /// Which connection each sign-in's token is for.
    private var connections: [String: (connection: String, at: TimeInterval)] = [:]
    /// The entries each sign-in was answered from (true: from a hand-off), judged by how it ended.
    private var used: [String: [String: Bool]] = [:]
    /// Typed answers each sign-in handed on (also with remembering off): a failed sign-in takes its
    /// hand-off back.
    private var handedOn: [String: Set<String>] = [:]
    /// Why an entry was let go, by entry (no password): told when ssh asks again (`whyNotRemembered`).
    private var forgotten: [String: String] = [:]
    private var _checked = false
    private var _isEnabled = true
    private var _sshNamesItsQuestions = false
    private var _maxAge: TimeInterval?
    public var isEnabled: Bool {
        get { lock.withLock { _isEnabled } }
        set { lock.withLock { _isEnabled = newValue } }
    }
    /// False for an ssh that does not put `(user@host)` before the server's own questions (before
    /// OpenSSH 8.4): a server could then word a question as another host's password prompt.
    public var sshNamesItsQuestions: Bool {
        get { lock.withLock { _sshNamesItsQuestions } }
        set { lock.withLock { _sshNamesItsQuestions = newValue; _checked = true } }
    }
    /// Whether the ssh program's version has been looked at yet.
    public var sshChecked: Bool {
        get { lock.withLock { _checked } }
        set { lock.withLock { _checked = newValue } }
    }
    /// Entries older than this are forgotten (nil: kept until Tether quits).
    public var maxAge: TimeInterval? {
        get { lock.withLock { _maxAge } }
        set { lock.withLock { _maxAge = newValue } }
    }

    /// How a key file's passphrase is named (`passphrase:<key file>`, as in the keychain).
    public static let passphrasePrefix = "passphrase:"
    /// How long a typed answer is handed to the same connection's further sign-ins.
    public static let handOffTime: TimeInterval = 60

    public init(sealer: PasswordSealer?) {
        self.sealer = sealer
        handOffSealer = sealer ?? MemorySealer()
    }
    /// Seals hand-offs: the Secure Enclave's key, or one in memory where there is none.
    private let handOffSealer: PasswordSealer

    /// Whether passwords can be remembered at all (a Secure Enclave is there).
    public var isAvailable: Bool { sealer != nil }

    /// A password held for a moment elsewhere (Quick Connect), sealed like the hand-offs (by the
    /// Secure Enclave, or a key in memory where there is none).
    public func seal(_ password: String) -> Data {
        handOffSealer.seal(Data(password.utf8)) ?? Data()
    }

    /// The password `seal` made.
    public func open(_ sealed: Data) -> String? {
        guard var plain = handOffSealer.open(sealed) else { return nil }
        defer { plain.resetBytes(in: 0..<plain.count) }
        return String(decoding: plain, as: UTF8.self)
    }

    /// Read inside the lock only.
    private var activeLocked: Bool { _isEnabled && _sshNamesItsQuestions && sealer != nil }
    /// Hand-offs work also with remembering turned off, and without a Secure Enclave (inside the lock only).
    private var handsOffLocked: Bool { _sshNamesItsQuestions }
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The sign-in with this askpass token is for this connection (only such sign-ins take part).
    public func bind(token: String, connection: String) {
        lock.withLock {
            // Sign-ins still running (a question open for long, Tether locked meanwhile) keep theirs.
            let cutoff = Self.now - 600
            func stale(_ token: String, _ at: TimeInterval) -> Bool { at <= cutoff && !AskPassBridge.shared.isLive(token) }
            connections = connections.filter { !stale($0.key, $0.value.at) }
            pending = pending.compactMapValues { byKey in
                let kept = byKey.filter { $0.value.at > cutoff }
                return kept.isEmpty ? nil : kept
            }
            used = used.filter { connections[$0.key] != nil }
            handedOn = handedOn.filter { connections[$0.key] != nil }
            handOffs = handOffs.filter { $0.value.until > Self.now }
            connections[token] = (connection, Self.now)
        }
    }

    private func key(token: String, login: String) -> String? {
        // A key file's passphrase belongs to the key on this Mac, not to a server: the same key
        // opens with it whatever it signs in to.
        if login.hasPrefix(Self.passphrasePrefix) { return "key\u{0}" + login }
        return connections[token].map { $0.connection + "\u{0}" + login }
    }

    /// A password given to the sign-in with this token (kept only if that sign-in succeeds). A typed
    /// one is also handed to the same connection's further sign-ins for `handOffTime`.
    /// `named`: the user@host ssh named in its question.
    public func offer(_ password: String, login: String, token: String, source: Source, named: String? = nil) {
        guard lock.withLock({ handsOffLocked }), let sealed = handOffSealer.seal(Data(password.utf8)) else { return }
        lock.withLock {
            guard let key = key(token: token, login: login) else { return }
            let entry = Entry(sealed: sealed, source: source, login: login, named: named)
            if source == .typed {
                handOffs[key] = HandOff(entry: entry, until: Self.now + Self.handOffTime)
                handedOn[token, default: []].insert(key)
            }
            guard activeLocked else { return }
            pending[token, default: [:]][key] = Pending(key: key, entry: entry, at: Self.now)
        }
    }

    /// The sign-in with this token succeeded: what was given to it is remembered, from now on. (An
    /// answer taken from here is not given again — see `AppModel.answer` —, so *Forget them after …*
    /// counts from when a password was typed, not from its last use.) Returns the logins remembered.
    @discardableResult
    public func commit(token: String) -> [String] {
        lock.withLock {
            connections[token] = nil
            let usedKeys = used.removeValue(forKey: token) ?? [:]
            // Handed on for another minute from now: further sign-ins of this server still waiting
            // (more connections for many tabs, one after the other) take it — the server has just
            // accepted it.
            for key in (handedOn.removeValue(forKey: token) ?? []).union(usedKeys.filter(\.value).keys) {
                handOffs[key]?.until = Self.now + Self.handOffTime
            }
            // What it was answered with worked: no longer in doubt.
            for key in usedKeys.keys {
                entries[key]?.unconfirmed = false
                handOffs[key]?.entry.unconfirmed = false
            }
            guard let given = pending.removeValue(forKey: token), activeLocked else { return [] }
            for var p in given.values {
                p.entry.at = Date()
                p.entry.unconfirmed = false
                entries[p.key] = p.entry
                forgotten[p.key] = nil
            }
            return given.values.map(\.entry.login).sorted()
        }
    }

    /// The sign-in with this token ended without success (`SignInEnd`).
    /// - `failed`: a remembered or handed-off password it was answered with is never sent again,
    ///   whatever the server did: it may have said no, or hung up instead of asking again (fail2ban,
    ///   pam_faillock, network devices), and retrying it on every reconnect would lock the account.
    ///   (It is looked up only when ssh asks for it, so a sign-in that never got that far — no
    ///   route, host not found — forgets nothing.)
    /// - `notJudged`: the server never judged it: everything stays, also a typed answer's hand-off.
    /// - `unanswered`: sent, then silence: kept, but sent at most once more.
    ///
    /// A key's passphrase stays in every case: the key opened with it (a wrong one makes ssh ask
    /// again, see `reject`); the server refused something else. One typed for this sign-in is kept
    /// as if it had succeeded.
    public func discard(token: String, end: SignInEnd = .failed) {
        lock.withLock {
            let given = pending.removeValue(forKey: token) ?? [:]
            let handed = handedOn.removeValue(forKey: token) ?? []
            connections[token] = nil
            if activeLocked {
                for p in given.values where Self.isPassphraseEntry(p.key) {
                    var e = p.entry
                    e.at = Date()
                    entries[p.key] = e
                    forgotten[p.key] = nil
                }
            }
            let keys = used.removeValue(forKey: token) ?? [:]
            switch end {
            case .succeeded, .notJudged:
                return
            case .failed:
                for key in keys.keys where !Self.isPassphraseEntry(key) {
                    if let gone = entries.removeValue(forKey: key) {
                        forgotten[key] = "a sign-in it was sent to failed"
                        Self.logForgotten(gone.login, "a sign-in it was sent to failed (the server refused it or hung up)")
                    }
                    handOffs[key] = nil
                }
                // A typed answer the server refused or hung up on: not handed on either.
                for key in Set(given.keys).union(handed) where !Self.isPassphraseEntry(key) { handOffs[key] = nil }
            case .unanswered:
                for (key, fromHandOff) in keys where !Self.isPassphraseEntry(key) {
                    if fromHandOff {
                        if handOffs[key]?.entry.unconfirmed == true { handOffs[key] = nil } else { handOffs[key]?.entry.unconfirmed = true }
                    } else if entries[key]?.unconfirmed == true {
                        if let gone = entries[key] { Self.logForgotten(gone.login, "it was sent twice and the server never answered") }
                        entries[key] = nil
                        handOffs[key] = nil
                        forgotten[key] = "it was sent twice and the server never answered"
                    } else {
                        entries[key]?.unconfirmed = true
                    }
                }
            }
        }
    }

    /// An answer that looks like a one-time code (only digits, 4 to 10 of them), not a password: typed
    /// for the same login question asked again, it is a second step, not a new password.
    public static func looksLikeOneTimeCode(_ answer: String) -> Bool {
        (4...10).contains(answer.count) && answer.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// ssh's last words say the network failed (no answer, no route), not the server: a sign-in
    /// that ended so keeps what it was answered with (see `discard`). A connection that was closed
    /// or reset is not one of them: a server may hang up instead of saying no.
    public static func isNetworkFailure(_ text: String) -> Bool { SSHFailure.isNetwork(text) }

    private static func isPassphraseEntry(_ key: String) -> Bool { key.hasPrefix("key\u{0}" + passphrasePrefix) }

    /// The moment one is let go, and why (a key by its file name only: no folder in the log).
    private static func logForgotten(_ login: String, _ why: String) {
        let host = login.hasPrefix(passphrasePrefix) ? "key " + (String(login.dropFirst(passphrasePrefix.count)) as NSString).lastPathComponent : login
        ConnectionLog.shared.notice("Forgot a remembered password", .signIn, host: host, detail: why)
    }

    /// The password remembered (or just typed, see `handOffTime`) for this sign-in's connection and
    /// login, opened just for it. `named`: the user@host ssh named — an entry made under another
    /// name for the same server and user answers too.
    public func password(token: String, login: String, named: String? = nil) -> (password: String, source: Source)? {
        let sealer = handOffSealer
        guard let found = lock.withLock({ () -> Entry? in
            guard handsOffLocked, let key = key(token: token, login: login) else { return nil }
            if activeLocked, let (k, entry) = rememberedLocked(key: key, token: token, named: named) {
                used[token, default: [:]][k] = false
                return entry
            }
            // The same account under another name on the same connection (another alias) too.
            var handKey = key
            if handOffs[key] == nil, let named, let connection = connections[token]?.connection {
                let prefix = connection + "\u{0}"
                handKey = handOffs.keys.sorted().first { $0.hasPrefix(prefix) && handOffs[$0]?.entry.named == named } ?? key
            }
            if let h = handOffs[handKey], h.until > Self.now, _maxAge.map({ Date().timeIntervalSince(h.entry.at) <= $0 }) ?? true {
                let key = handKey
                used[token, default: [:]][key] = true
                // Remembered once this sign-in works, as if typed for it (the one it was typed for
                // may have been stopped before the server judged it).
                if activeLocked { pending[token, default: [:]][key] = Pending(key: key, entry: h.entry, at: Self.now) }
                return h.entry
            }
            return nil
        }), var plain = sealer.open(found.sealed) else { return nil }
        defer { plain.resetBytes(in: 0..<plain.count) }
        return (String(decoding: plain, as: UTF8.self), found.source)
    }

    /// Inside the lock: the remembered entry for this key — or for the same connection and the same
    /// user@host under another login name — dropping one past its time.
    private func rememberedLocked(key: String, token: String, named: String?) -> (String, Entry)? {
        func fresh(_ k: String) -> Entry? {
            guard let entry = entries[k] else { return nil }
            if let maxAge = _maxAge, Date().timeIntervalSince(entry.at) > maxAge {
                entries[k] = nil
                forgotten[k] = "it was older than the time chosen in Settings ▸ Passwords"
                return nil
            }
            return entry
        }
        if let e = fresh(key) { return (key, e) }
        guard let named, let connection = connections[token]?.connection else { return nil }
        let prefix = connection + "\u{0}"
        for k in entries.keys.sorted() where k.hasPrefix(prefix) && entries[k]?.named == named {
            if let e = fresh(k) { return (k, e) }
        }
        return nil
    }

    /// The server refused it (changed or wrong): never sent again.
    public func reject(token: String, login: String) {
        lock.withLock {
            guard let key = key(token: token, login: login) else { return }
            for k in (used[token] ?? [:]).keys where k == key || entries[k]?.login == login {
                if entries.removeValue(forKey: k) != nil { forgotten[k] = "the server did not accept it"; Self.logForgotten(login, "the server did not accept it") }
            }
            if entries.removeValue(forKey: key) != nil { forgotten[key] = "the server did not accept it"; Self.logForgotten(login, "the server did not accept it") }
            handOffs[key] = nil
            pending[token]?[key] = nil
        }
    }

    /// What was given to this sign-in for this login is not kept (a key the user skipped).
    public func withdraw(token: String, login: String) {
        lock.withLock {
            guard let key = key(token: token, login: login) else { return }
            pending[token]?[key] = nil
            handOffs[key] = nil
        }
    }

    /// The connection the sign-in with this token is for (nil: one Tether did not start as a
    /// shared connection's sign-in).
    public func connection(token: String) -> String? {
        lock.withLock { connections[token]?.connection }
    }

    /// Everything is forgotten (the setting is turned off, "Forget All", the screen locked with
    /// *Also forget them when the screen locks*). `reason`: told when ssh asks again (`whyNotRemembered`).
    public func removeAll(reason: String = "all remembered passwords were forgotten") {
        lock.withLock {
            if !entries.isEmpty {
                ConnectionLog.shared.notice("Forgot \(entries.count) remembered password\(entries.count == 1 ? "" : "s")", .signIn, detail: reason)
            }
            for key in entries.keys { forgotten[key] = reason }
            entries.removeAll()
            pending.removeAll()
            handOffs.removeAll()
        }
    }

    /// Why the sign-in with this token found nothing to answer `login` with, in words for the
    /// Connection Log (never a password, host or path).
    public func whyNotRemembered(token: String, login: String) -> String {
        lock.withLock {
            if !_isEnabled { return "remembering sign-in passwords is turned off" }
            if sealer == nil { return "this Mac has no Secure Enclave" }
            if !_checked { return "the ssh program was still being checked" }
            if !_sshNamesItsQuestions { return "the ssh program is older than OpenSSH 8.4" }
            guard let key = key(token: token, login: login) else { return "this sign-in is not one Tether started for a shared connection" }
            if let why = forgotten[key] { return "it was forgotten: " + why }
            if entries.values.contains(where: { $0.login == login }) {
                return "one is remembered for this login on another connection (another host name, port, user or jump host)"
            }
            return "nothing was remembered for this connection since Tether started"
        }
    }

    public var count: Int { lock.withLock { entries.count } }

    /// The remembered entries, newest first (for Settings: logins only, never a password).
    public func items() -> [Item] {
        lock.withLock {
            if let maxAge = _maxAge { entries = entries.filter { Date().timeIntervalSince($0.value.at) <= maxAge } }
            return entries.map { Item(id: $0.key, login: $0.value.login, since: $0.value.at, fromKeychain: $0.value.source == .keychain) }
                .sorted { $0.since > $1.since }
        }
    }

    /// Forgets one entry (Settings ▸ Passwords).
    public func forget(_ id: String) {
        lock.withLock { if entries.removeValue(forKey: id) != nil { forgotten[id] = "it was forgotten in Settings ▸ Passwords" } }
    }

    /// Forgets every entry for this login (its saved password was removed or replaced, a key's
    /// passphrase was changed). `reason`: told when ssh asks again.
    public func forget(login: String, reason: String = "its saved password or passphrase was changed") {
        lock.withLock {
            for (k, e) in entries where e.login == login { forgotten[k] = reason; Self.logForgotten(login, reason) }
            entries = entries.filter { $0.value.login != login }
            handOffs = handOffs.filter { $0.value.entry.login != login }
            for token in pending.keys { pending[token] = pending[token]?.filter { $0.value.entry.login != login } }
        }
    }
}

/// What the ssh program puts before a server's own questions.
public enum SSHVersion {
    /// OpenSSH 8.4 and later write `(user@host) ` before every keyboard-interactive question, so a
    /// server cannot pass its text off as ssh's password prompt for another host.
    public static func namesItsQuestions(_ versionOutput: String) -> Bool {
        guard let m = versionOutput.firstMatch(of: #/OpenSSH_(\d+)\.(\d+)/#), let major = Int(m.1), let minor = Int(m.2) else { return false }
        return major > 8 || (major == 8 && minor >= 4)
    }

    /// `ssh -V` of this program; nil when it did not answer in time (a busy Mac at launch: asked
    /// again later, never taken as a no).
    public static func namesItsQuestions(binary: String) async -> Bool? {
        let r = await ProcessRunner.run(binary, arguments: ["-V"], timeout: 5)
        return r.timedOut ? nil : namesItsQuestions(r.errorOutput + r.output)
    }
}

/// Which ssh programs on this Mac mark a server's questions, by program file: each is asked `-V`
/// once, and again when the file changes (an update).
public final class SSHVersionCheck: @unchecked Sendable {
    public static let shared = SSHVersionCheck()

    private let lock = NSLock()
    private var results: [String: (identity: String, answer: Task<Bool?, Never>)] = [:]

    public init() {}

    /// A program that did not answer in time counts as no for this question only: it is asked again
    /// next time.
    public func namesItsQuestions(path: String) async -> Bool {
        guard let identity = Self.identity(of: path) else { return false }
        let answer: Task<Bool?, Never> = lock.withLock {
            if let known = results[path], known.identity == identity { return known.answer }
            let task = Task { await SSHVersion.namesItsQuestions(binary: path) }
            results[path] = (identity, task)
            return task
        }
        guard let known = await answer.value else {
            lock.withLock { if results[path]?.answer == answer { results[path] = nil } }
            return false
        }
        return known
    }

    /// The file as it is now (device, inode, size, modification time); nil when it is not there.
    static func identity(of path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return "\(st.st_dev):\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
    }
}
