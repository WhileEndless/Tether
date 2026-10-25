import Foundation
import CryptoKit
import CommonCrypto
import TetherCore
import RecordingKit

/// Where the key of encrypted recordings lives.
///
/// - App Lock off or Touch ID / Mac password: in the login keychain, readable without a prompt only
///   by Tether.
/// - Tether password: only wrapped (AES-GCM) with a key derived from the password (PBKDF2-SHA256,
///   600,000 rounds, random salt). Nothing on disk opens the recordings without the password; the
///   wrapped key also checks the password at unlock.
enum RecordingKeyStore {
    private static let service = "Tether Recording Key"
    private static let plainAccount = "key"
    private static let wrappedAccount = "password-wrapped-key"
    static let rounds = 600_000

    struct Wrapped: Codable {
        var salt: Data
        var rounds: Int
        var box: Data
        /// Id of the wrapped key (not secret): tells whether a keychain copy is really the same key.
        var keyID: Data?
    }

    // MARK: Plain (keychain)

    static func storedKey() -> SymmetricKey? {
        Keychain.read(service: service, account: plainAccount).flatMap { $0.count == 32 ? SymmetricKey(data: $0) : nil }
    }

    /// The stored key, if recordings are encrypted with it (a key that encrypts nothing is not trusted).
    static func trustedStoredKey() -> SymmetricKey? {
        guard let key = storedKey(), RecordingStore.anyEncrypted(keyID: RecordingCrypto.keyID(key)) else { return nil }
        return key
    }

    static func store(_ key: SymmetricKey) {
        key.withUnsafeBytes {
            _ = Keychain.write(Data($0), service: service, account: plainAccount, label: "Tether recording encryption key")
        }
    }

    // MARK: Password-wrapped

    static var hasPassword: Bool { wrapped() != nil }

    /// A copy of the password-wrapped key next to the recordings. It is useless without the Tether
    /// password, and keeps the recordings readable if the login keychain is ever reset (e.g. after a
    /// forgotten Mac password).
    private static var backupURL: URL { AppPaths.supportDirectory.appendingPathComponent("recording-key.wrapped") }

    private static func wrapped() -> Wrapped? {
        let data = Keychain.read(service: service, account: wrappedAccount)
            ?? (try? Data(contentsOf: backupURL))
        return data.flatMap { try? JSONDecoder().decode(Wrapped.self, from: $0) }
    }

    private static func writeBackup(_ data: Data?) {
        guard let data else { try? FileManager.default.removeItem(at: backupURL); return }
        FileManager.default.createFile(atPath: backupURL.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    /// The key behind the password, or nil when the password is wrong. Slow on purpose (~½ s).
    static func unwrap(password: String) -> SymmetricKey? {
        guard let w = wrapped(), let kek = derive(password, salt: w.salt, rounds: w.rounds),
              let box = try? AES.GCM.SealedBox(combined: w.box),
              let raw = try? AES.GCM.open(box, using: kek) else { return nil }
        // Opened from the backup file (the keychain was reset): put the keychain copy back.
        if Keychain.read(service: service, account: wrappedAccount) == nil, let data = try? JSONEncoder().encode(w) {
            Keychain.write(data, service: service, account: wrappedAccount, label: "Tether password-protected recording key")
        }
        return SymmetricKey(data: raw)
    }

    /// Puts `key` behind `password`. The plain keychain copy is kept only when Touch ID may unlock too.
    @discardableResult
    static func setPassword(_ password: String, for key: SymmetricKey, keepKeychainCopy: Bool) -> Bool {
        var salt = Data(count: 32)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess,
              let kek = derive(password, salt: salt, rounds: rounds),
              let box = key.withUnsafeBytes({ try? AES.GCM.seal(Data($0), using: kek).combined }),
              let data = try? JSONEncoder().encode(Wrapped(salt: salt, rounds: rounds, box: box, keyID: RecordingCrypto.keyID(key))),
              Keychain.write(data, service: service, account: wrappedAccount, label: "Tether password-protected recording key")
        else { return false }
        writeBackup(data)
        setKeychainCopy(keepKeychainCopy, of: key)
        return true
    }

    /// Keeps (or removes) the keychain copy that lets Touch ID unlock alongside the Tether password.
    static func setKeychainCopy(_ keep: Bool, of key: SymmetricKey) {
        if keep { store(key) } else { Keychain.delete(service: service, account: plainAccount) }
    }

    /// The key Touch ID unlocks with a Tether password set: the keychain copy, only if it is the
    /// same key the password protects.
    static func keychainCopyOfPasswordKey() -> SymmetricKey? {
        guard let id = wrapped()?.keyID, let key = storedKey(), RecordingCrypto.keyID(key) == id else { return nil }
        return key
    }

    /// Back to a keychain-held key (the Tether password is switched off).
    static func removePassword(keeping key: SymmetricKey) {
        store(key)
        Keychain.delete(service: service, account: wrappedAccount)
        writeBackup(nil)
    }

    /// Forgets every key (the Tether password was forgotten): encrypted recordings can no longer be opened.
    /// Recordings still being written with the key stop and remove themselves.
    static func forgetAll() {
        for id in [wrapped()?.keyID, RecordingCrypto.lockedSealing?.keyID, RecordingCrypto.key.map(RecordingCrypto.keyID),
                   storedKey().map(RecordingCrypto.keyID)].compactMap({ $0 }) {
            RecordingCrypto.revoke(keyID: id)
        }
        Keychain.delete(service: service, account: wrappedAccount)
        Keychain.delete(service: service, account: plainAccount)
        writeBackup(nil)
        Keychain.delete(service: service, account: sealingAccount)
        RecordingCrypto.lockedSealing = nil
    }

    /// The public half of the key: what output and history are sealed to while Tether is locked
    /// (`RecordingCrypto.LockedSealing`). Not secret, but kept in the keychain like the key, so no
    /// other program can put its own public key there and receive what is written while locked.
    private static let sealingAccount = "locked-sealing"

    /// Keeps the public half of the key in memory current in the keychain.
    static func saveSealing() {
        guard let data = RecordingCrypto.encodedLockedSealing,
              Keychain.read(service: service, account: sealingAccount) != data else { return }
        Keychain.write(data, service: service, account: sealingAccount, label: "Tether recording key (public half, for while locked)")
    }

    /// Tells the recordings where to find it when something must be sealed while locked.
    static func provideSealing() {
        RecordingCrypto.lockedSealingLoader = { Keychain.read(service: service, account: sealingAccount) }
    }

    private static func derive(_ password: String, salt: Data, rounds: Int) -> SymmetricKey? {
        var out = Data(count: 32)
        let pw = Array(password.utf8)
        let status = out.withUnsafeMutableBytes { o in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { CChar(bitPattern: $0) }, pw.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                                     o.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return status == kCCSuccess ? SymmetricKey(data: out) : nil
    }
}
