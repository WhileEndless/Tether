import Foundation
import Security

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

/// Sign-in passwords remembered while the app runs, so one typed password signs in every
/// connection the same server needs — further shared connections past the server's session limit,
/// reconnects after the connection really ended — without asking again.
///
/// Rules (see docs/connections-and-passwords.md):
/// - Only sealed (`PasswordSealer`); nothing unsealed is ever kept.
/// - Per connection: an entry belongs to the connection the sign-in was for (`bind`: ssh's own
///   socket name, derived from host name, port, user and jump host) and to the login ssh named in
///   its question (the caller's `savedPasswordKey`). Another port, another jump host, another user
///   is another entry — a password is never offered to a different server.
/// - Kept only after the sign-in it was given to succeeded (`commit`); dropped when refused.
/// - Never one-time codes or new-password questions; never terminal prompts such as sudo.
public final class SealedPasswordCache: @unchecked Sendable {
    public enum Source: Sendable { case typed, keychain }

    private struct Entry { var sealed: Data; var source: Source; var login: String; var at = Date() }

    /// What the settings show for an entry (never the password).
    public struct Item: Identifiable, Sendable {
        public var id: String
        public var login: String
        public var since: Date
        public var fromKeychain: Bool
    }
    private struct Pending { var key: String; var entry: Entry; var at: TimeInterval }

    private let lock = NSLock()
    private let sealer: PasswordSealer?
    private var entries: [String: Entry] = [:]
    /// Given to a sign-in still in progress, by askpass token and entry: kept once that sign-in
    /// succeeded. One sign-in can be given several (a key's passphrase, then the server's password;
    /// a jump host's and the target's).
    private var pending: [String: [String: Pending]] = [:]
    /// Which connection each sign-in's token is for.
    private var connections: [String: (connection: String, at: TimeInterval)] = [:]
    /// The entries each sign-in was answered from (dropped if that sign-in is refused).
    private var used: [String: Set<String>] = [:]
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

    public init(sealer: PasswordSealer?) {
        self.sealer = sealer
    }

    /// Whether passwords can be remembered at all (a Secure Enclave is there).
    public var isAvailable: Bool { sealer != nil }

    /// Read inside the lock only.
    private var activeLocked: Bool { _isEnabled && _sshNamesItsQuestions && sealer != nil }
    private var active: Bool { lock.withLock { activeLocked } }
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The sign-in with this askpass token is for this connection (only such sign-ins take part).
    public func bind(token: String, connection: String) {
        lock.withLock {
            let cutoff = Self.now - 600
            connections = connections.filter { $0.value.at > cutoff }
            pending = pending.compactMapValues { byKey in
                let kept = byKey.filter { $0.value.at > cutoff }
                return kept.isEmpty ? nil : kept
            }
            used = used.filter { connections[$0.key] != nil }
            connections[token] = (connection, Self.now)
        }
    }

    private func key(token: String, login: String) -> String? {
        // A key file's passphrase belongs to the key on this Mac, not to a server: the same key
        // opens with it whatever it signs in to.
        if login.hasPrefix(Self.passphrasePrefix) { return "key\u{0}" + login }
        return connections[token].map { $0.connection + "\u{0}" + login }
    }

    /// A password given to the sign-in with this token (kept only if that sign-in succeeds).
    public func offer(_ password: String, login: String, token: String, source: Source) {
        guard active, let sealer, let sealed = sealer.seal(Data(password.utf8)) else { return }
        lock.withLock {
            guard let key = key(token: token, login: login) else { return }
            pending[token, default: [:]][key] = Pending(key: key, entry: Entry(sealed: sealed, source: source, login: login), at: Self.now)
        }
    }

    /// The sign-in with this token succeeded: what was given to it is remembered, from now on. (An
    /// answer taken from here is not given again — see `AppModel.answer` —, so *Forget them after …*
    /// counts from when a password was typed, not from its last use.)
    public func commit(token: String) {
        lock.withLock {
            connections[token] = nil
            used[token] = nil
            guard let given = pending.removeValue(forKey: token), activeLocked else { return }
            for var p in given.values {
                p.entry.at = Date()
                entries[p.key] = p.entry
            }
        }
    }

    /// The sign-in with this token ended without success. A remembered password it was answered
    /// with is never sent again, whatever the reason: the server may have said no, or hung up
    /// instead of asking again (fail2ban, pam_faillock, network devices), and retrying it on every
    /// reconnect would lock the account. (It is looked up only when ssh asks for it, so a sign-in
    /// that never got that far — no route, host not found — forgets nothing.) A key's passphrase
    /// stays: the key opened with it (a wrong one makes ssh ask again, see `reject`); the server
    /// refused something else — the key itself, or a password.
    public func discard(token: String) {
        lock.withLock {
            pending[token] = nil
            connections[token] = nil
            guard let keys = used.removeValue(forKey: token) else { return }
            for key in keys where !Self.isPassphraseEntry(key) { entries[key] = nil }
        }
    }

    private static func isPassphraseEntry(_ key: String) -> Bool { key.hasPrefix("key\u{0}" + passphrasePrefix) }

    /// The password remembered for this sign-in's connection and login, opened just for it.
    public func password(token: String, login: String) -> (password: String, source: Source)? {
        guard active, let sealer, let entry = lock.withLock({ () -> Entry? in
            guard let key = key(token: token, login: login), let entry = entries[key] else { return nil }
            if let maxAge = _maxAge, Date().timeIntervalSince(entry.at) > maxAge { entries[key] = nil; return nil }
            used[token, default: []].insert(key)
            return entry
        }), var plain = sealer.open(entry.sealed) else { return nil }
        defer { plain.resetBytes(in: 0..<plain.count) }
        return (String(decoding: plain, as: UTF8.self), entry.source)
    }

    /// The server refused it (changed or wrong): never sent again.
    public func reject(token: String, login: String) {
        lock.withLock {
            guard let key = key(token: token, login: login) else { return }
            entries[key] = nil
            pending[token]?[key] = nil
        }
    }

    /// What was given to this sign-in for this login is not kept (a key the user skipped).
    public func withdraw(token: String, login: String) {
        lock.withLock {
            guard let key = key(token: token, login: login) else { return }
            pending[token]?[key] = nil
        }
    }

    /// Entries that came from the keychain (Touch ID locks again: they need it again), also those
    /// still waiting for their sign-in to finish.
    public func removeKeychainEntries() {
        lock.withLock {
            entries = entries.filter { $0.value.source != .keychain }
            pending = pending.compactMapValues { byKey in
                let kept = byKey.filter { $0.value.entry.source != .keychain }
                return kept.isEmpty ? nil : kept
            }
        }
    }

    /// The connection the sign-in with this token is for (nil: one Tether did not start as a
    /// shared connection's sign-in).
    public func connection(token: String) -> String? {
        lock.withLock { connections[token]?.connection }
    }

    /// Everything is forgotten (App Lock locks, the setting is turned off, "Forget Now").
    public func removeAll() {
        lock.withLock {
            entries.removeAll()
            pending.removeAll()
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
    public func forget(_ id: String) { lock.withLock { _ = entries.removeValue(forKey: id) } }

    /// Forgets every entry for this login (a key whose passphrase was just changed).
    public func forget(login: String) {
        lock.withLock {
            entries = entries.filter { $0.value.login != login }
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

    /// `ssh -V` of this program (it prints and exits at once; one that does not counts as no).
    public static func namesItsQuestions(binary: String) async -> Bool {
        let r = await ProcessRunner.run(binary, arguments: ["-V"], timeout: 3)
        return !r.timedOut && namesItsQuestions(r.errorOutput + r.output)
    }
}

/// Which ssh programs on this Mac mark a server's questions, by program file: each is asked `-V`
/// once, and again when the file changes (an update).
public final class SSHVersionCheck: @unchecked Sendable {
    public static let shared = SSHVersionCheck()

    private let lock = NSLock()
    private var results: [String: (identity: String, answer: Task<Bool, Never>)] = [:]

    public init() {}

    public func namesItsQuestions(path: String) async -> Bool {
        guard let identity = Self.identity(of: path) else { return false }
        let answer: Task<Bool, Never> = lock.withLock {
            if let known = results[path], known.identity == identity { return known.answer }
            let task = Task { await SSHVersion.namesItsQuestions(binary: path) }
            results[path] = (identity, task)
            return task
        }
        return await answer.value
    }

    /// The file as it is now (device, inode, size, modification time); nil when it is not there.
    static func identity(of path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return "\(st.st_dev):\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
    }
}
