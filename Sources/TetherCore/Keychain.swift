import Foundation
import Security

/// Small secrets in the login keychain: encrypted by macOS, unlocked with the user's login, and
/// readable without a prompt only by Tether itself (other apps have to ask the user). Items are
/// created non-synchronizable (SecItemAdd's default), so they never leave this Mac through iCloud.
public enum Keychain {
    /// Tests and debug runs with their own settings (the demo, self-tests) keep secrets in memory, so
    /// they never read or change the user's keychain.
    private static let inMemory = AppPaths.debugOverride("TETHER_DEFAULTS_SUITE") != nil || AppPaths.isRunningTests
    nonisolated(unsafe) private static var memory: [String: Data] = [:]
    nonisolated(unsafe) private static var memoryAttributes: [String: Data] = [:]
    private static let memoryLock = NSLock()
    private static func memoryKey(_ service: String, _ account: String) -> String { service + "\u{0}" + account }

    private static func base(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public static func read(service: String, account: String) -> Data? {
        if inMemory { memoryLock.lock(); defer { memoryLock.unlock() }; return memory[memoryKey(service, account)] }
        var query = base(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    public static func exists(service: String, account: String) -> Bool {
        if inMemory { return read(service: service, account: account) != nil }
        return SecItemCopyMatching(base(service: service, account: account) as CFDictionary, nil) == errSecSuccess
    }

    /// Stores `data` in a new item that only Tether can read without asking the user. An existing
    /// item is removed first rather than updated: one created beforehand by another program (with
    /// an access list that lets everyone read it) must never end up holding a secret. If adding
    /// fails, the previous value is put back.
    @discardableResult
    public static func write(_ data: Data, service: String, account: String, label: String) -> Bool {
        if inMemory {
            memoryLock.lock(); memory[memoryKey(service, account)] = data; memoryAttributes[memoryKey(service, account)] = nil; memoryLock.unlock(); return true
        }
        let previous = read(service: service, account: account)
        SecItemDelete(base(service: service, account: account) as CFDictionary)
        var add = base(service: service, account: account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { return true }
        if let previous {
            var restore = base(service: service, account: account)
            restore[kSecValueData as String] = previous
            restore[kSecAttrLabel as String] = label
            SecItemAdd(restore as CFDictionary, nil)
        }
        return false
    }

    /// Whether an item exists and the value kept in its "generic" attribute. Attributes are read
    /// without the access list's prompt, so this suits values that must not be changed silently but
    /// are not secret. (Tether is ad-hoc signed: every build is a new app to the keychain, and
    /// reading an item's data would ask the user again after each update.)
    public enum Lookup: Equatable, Sendable { case missing, found(Data?) }

    public static func lookUpAttribute(service: String, account: String) -> Lookup {
        if inMemory {
            memoryLock.lock(); defer { memoryLock.unlock() }
            return memoryAttributes[memoryKey(service, account)].map { .found($0) } ?? (memory[memoryKey(service, account)] != nil ? .found(nil) : .missing)
        }
        var query = base(service: service, account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return .missing }
        return .found((item as? [String: Any])?[kSecAttrGeneric as String] as? Data)
    }

    /// Stores `value` in the "generic" attribute of a new item (see `lookUpAttribute`), replacing any
    /// existing one like `write`. If adding fails, the previous value is put back.
    @discardableResult
    public static func writeAttribute(_ value: Data, service: String, account: String, label: String) -> Bool {
        if inMemory {
            memoryLock.lock(); defer { memoryLock.unlock() }
            memory[memoryKey(service, account)] = nil
            memoryAttributes[memoryKey(service, account)] = value
            return true
        }
        let previous = lookUpAttribute(service: service, account: account)
        SecItemDelete(base(service: service, account: account) as CFDictionary)
        func add(_ value: Data) -> Bool {
            var add = base(service: service, account: account)
            add[kSecAttrGeneric as String] = value
            add[kSecValueData as String] = Data()
            add[kSecAttrLabel as String] = label
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        if add(value) { return true }
        if case .found(let old?) = previous { _ = add(old) }
        return false
    }

    public static func delete(service: String, account: String) {
        if inMemory {
            memoryLock.lock(); memory[memoryKey(service, account)] = nil; memoryAttributes[memoryKey(service, account)] = nil; memoryLock.unlock(); return
        }
        SecItemDelete(base(service: service, account: account) as CFDictionary)
    }

    public static func accounts(service: String) -> [String] {
        if inMemory {
            memoryLock.lock(); defer { memoryLock.unlock() }
            return memory.keys.compactMap { k in
                let parts = k.split(separator: "\u{0}", maxSplits: 1).map(String.init)
                return parts.count == 2 && parts[0] == service ? parts[1] : nil
            }.sorted()
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[String: Any]] else { return [] }
        return list.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }
}

/// Stores SSH passwords in the login keychain, keyed by connection target.
public enum PasswordVault {
    private static let service = "Tether SSH Password"

    public static func password(for account: String) -> String? {
        Keychain.read(service: service, account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Whether one is saved (no password read, no dialog). Asked while drawing (the prompt bar
    /// says whether Fill is possible): answers are kept for a few seconds instead of asking the
    /// keychain on every redraw. Saving and deleting through here update them at once.
    public static func hasPassword(for account: String) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let (known, generation) = existsLock.withLock { (exists[account], existsGeneration) }
        if let known, now - known.at < 5 { return known.value }
        let value = Keychain.exists(service: service, account: account)
        existsLock.withLock {
            // Saved or deleted while asking: that answer may be old, so it is not kept.
            guard existsGeneration == generation else { return }
            if exists.count > 256 { exists.removeAll() }
            exists[account] = (value, now)
        }
        return value
    }

    private static let existsLock = NSLock()
    nonisolated(unsafe) private static var exists: [String: (value: Bool, at: TimeInterval)] = [:]
    nonisolated(unsafe) private static var existsGeneration = 0

    private static func forgetExists(_ account: String) {
        existsLock.withLock {
            exists.removeValue(forKey: account)
            existsGeneration &+= 1
        }
    }

    @discardableResult
    public static func setPassword(_ password: String, for account: String) -> Bool {
        defer { forgetExists(account) }
        return Keychain.write(Data(password.utf8), service: service, account: account, label: "Tether: \(account)")
    }

    public static func deletePassword(for account: String) {
        Keychain.delete(service: service, account: account)
        forgetExists(account)
    }

    public static func allAccounts() -> [String] {
        Keychain.accounts(service: service)
    }

    /// Reading a password can block until macOS's "allow access" dialog is answered: one read at a
    /// time on a queue of its own, never on a thread the rest of Tether's work shares (many sign-ins
    /// waiting on a dialog would otherwise stall every connection).
    private static let readQueue = DispatchQueue(label: "tether.keychain-read")

    public static func passwordOffThread(for account: String) async -> String? {
        await withCheckedContinuation { cont in readQueue.async { cont.resume(returning: password(for: account)) } }
    }
}
