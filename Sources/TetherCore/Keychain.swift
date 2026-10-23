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
        if inMemory { memoryLock.lock(); memory[memoryKey(service, account)] = data; memoryLock.unlock(); return true }
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

    public static func delete(service: String, account: String) {
        if inMemory { memoryLock.lock(); memory[memoryKey(service, account)] = nil; memoryLock.unlock(); return }
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

    public static func hasPassword(for account: String) -> Bool {
        Keychain.exists(service: service, account: account)
    }

    @discardableResult
    public static func setPassword(_ password: String, for account: String) -> Bool {
        Keychain.write(Data(password.utf8), service: service, account: account, label: "Tether: \(account)")
    }

    public static func deletePassword(for account: String) {
        Keychain.delete(service: service, account: account)
    }

    public static func allAccounts() -> [String] {
        Keychain.accounts(service: service)
    }
}
