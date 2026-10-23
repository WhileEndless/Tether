import Foundation

/// The settings that protect secrets and recordings, kept in the keychain as well as in the
/// preferences file.
///
/// Preferences are a plain file that any program running as the user can rewrite silently — for
/// instance to switch off the app lock or encryption, to drop the Touch ID check for saved
/// passwords, or to point Tether at another `ssh` program (which would then be handed passwords).
/// The keychain copy can only be changed by Tether without asking the user, so at launch it wins:
/// a mismatch is put back and reported. Everything that decides where passwords go, whether they
/// need Touch ID, and how recordings and the app are protected is in here.
public struct SecuritySettings: Codable, Equatable, Sendable {
    public var appLockMode: AppLockMode
    public var encryptRecordings: Bool
    public var requireAuthForSavedPasswords: Bool
    public var autoFillPasswordPrompts: Bool
    public var sshBinary: String
    public var sshConfigPath: String
    public var scpBinary: String
    public var authGraceSeconds: Int
    public var lockOnSleep: Bool
    public var unlockWithTouchID: Bool
    public var secureKeyboardAtPasswordPrompts: Bool
    public var hostKeyPolicy: HostKeyPolicy
    public var useControlMaster: Bool
    public var detectPasswordPrompts: Bool

    /// Tolerant: a field added in a later version takes its default instead of failing, so an older
    /// keychain copy is never thrown away (which would let the preferences file decide).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SecuritySettings(AppSettings())
        appLockMode = try c.decodeIfPresent(AppLockMode.self, forKey: .appLockMode) ?? d.appLockMode
        encryptRecordings = try c.decodeIfPresent(Bool.self, forKey: .encryptRecordings) ?? d.encryptRecordings
        requireAuthForSavedPasswords = try c.decodeIfPresent(Bool.self, forKey: .requireAuthForSavedPasswords) ?? d.requireAuthForSavedPasswords
        autoFillPasswordPrompts = try c.decodeIfPresent(Bool.self, forKey: .autoFillPasswordPrompts) ?? d.autoFillPasswordPrompts
        sshBinary = try c.decodeIfPresent(String.self, forKey: .sshBinary) ?? d.sshBinary
        sshConfigPath = try c.decodeIfPresent(String.self, forKey: .sshConfigPath) ?? d.sshConfigPath
        scpBinary = try c.decodeIfPresent(String.self, forKey: .scpBinary) ?? d.scpBinary
        authGraceSeconds = try c.decodeIfPresent(Int.self, forKey: .authGraceSeconds) ?? d.authGraceSeconds
        lockOnSleep = try c.decodeIfPresent(Bool.self, forKey: .lockOnSleep) ?? d.lockOnSleep
        unlockWithTouchID = try c.decodeIfPresent(Bool.self, forKey: .unlockWithTouchID) ?? d.unlockWithTouchID
        secureKeyboardAtPasswordPrompts = try c.decodeIfPresent(Bool.self, forKey: .secureKeyboardAtPasswordPrompts) ?? d.secureKeyboardAtPasswordPrompts
        hostKeyPolicy = try c.decodeIfPresent(HostKeyPolicy.self, forKey: .hostKeyPolicy) ?? d.hostKeyPolicy
        useControlMaster = try c.decodeIfPresent(Bool.self, forKey: .useControlMaster) ?? d.useControlMaster
        detectPasswordPrompts = try c.decodeIfPresent(Bool.self, forKey: .detectPasswordPrompts) ?? d.detectPasswordPrompts
    }

    public init(_ s: AppSettings) {
        appLockMode = s.appLockMode
        encryptRecordings = s.encryptRecordings
        requireAuthForSavedPasswords = s.requireAuthForSavedPasswords
        autoFillPasswordPrompts = s.autoFillPasswordPrompts
        sshBinary = s.sshBinary
        sshConfigPath = s.sshConfigPath
        scpBinary = s.scpBinary
        authGraceSeconds = s.authGraceSeconds
        lockOnSleep = s.lockOnSleep
        unlockWithTouchID = s.unlockWithTouchID
        secureKeyboardAtPasswordPrompts = s.secureKeyboardAtPasswordPrompts
        hostKeyPolicy = s.hostKeyPolicy
        useControlMaster = s.useControlMaster
        detectPasswordPrompts = s.detectPasswordPrompts
    }

    /// An ssh or scp program that can actually be used: an existing executable file outside any
    /// temporary folder. Anything else (a deleted or planted file) falls back to the system one.
    public static func usableProgram(_ path: String, fallback: String) -> String {
        let p = (path as NSString).expandingTildeInPath
        guard p.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: p) else { return fallback }
        let temporary = [FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path, "/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
        let resolved = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
        if temporary.contains(where: { resolved.hasPrefix($0 + "/") }) { return fallback }
        return p
    }

    public func apply(to s: inout AppSettings) {
        s.appLockMode = appLockMode
        s.encryptRecordings = encryptRecordings
        s.requireAuthForSavedPasswords = requireAuthForSavedPasswords
        s.autoFillPasswordPrompts = autoFillPasswordPrompts
        s.sshBinary = sshBinary
        s.sshConfigPath = sshConfigPath
        s.scpBinary = scpBinary
        s.authGraceSeconds = authGraceSeconds
        s.lockOnSleep = lockOnSleep
        s.unlockWithTouchID = unlockWithTouchID
        s.secureKeyboardAtPasswordPrompts = secureKeyboardAtPasswordPrompts
        s.hostKeyPolicy = hostKeyPolicy
        s.useControlMaster = useControlMaster
        s.detectPasswordPrompts = detectPasswordPrompts
    }

    /// Names of the settings that differ (for the warning shown at launch).
    public func differences(from other: SecuritySettings) -> [String] {
        var names: [String] = []
        if appLockMode != other.appLockMode { names.append("App Lock") }
        if encryptRecordings != other.encryptRecordings { names.append("Encrypt recordings") }
        if requireAuthForSavedPasswords != other.requireAuthForSavedPasswords { names.append("Touch ID for saved passwords") }
        if autoFillPasswordPrompts != other.autoFillPasswordPrompts { names.append("Fill saved passwords automatically") }
        if sshBinary != other.sshBinary { names.append("ssh program") }
        if sshConfigPath != other.sshConfigPath { names.append("SSH config file") }
        if scpBinary != other.scpBinary { names.append("scp program") }
        if authGraceSeconds != other.authGraceSeconds { names.append("Touch ID grace period") }
        if lockOnSleep != other.lockOnSleep { names.append("Lock on sleep") }
        if unlockWithTouchID != other.unlockWithTouchID { names.append("Unlock with Touch ID") }
        if secureKeyboardAtPasswordPrompts != other.secureKeyboardAtPasswordPrompts { names.append("Secure Keyboard Entry") }
        if hostKeyPolicy != other.hostKeyPolicy { names.append("Unknown host keys") }
        if useControlMaster != other.useControlMaster { names.append("Shared connections") }
        if detectPasswordPrompts != other.detectPasswordPrompts { names.append("Password prompt detection") }
        return names
    }

    private static let service = "Tether Security Settings"
    private static let account = "settings"

    public static func pinned() -> SecuritySettings? {
        Keychain.read(service: service, account: account).flatMap { try? JSONDecoder().decode(SecuritySettings.self, from: $0) }
    }

    public static func pin(_ settings: SecuritySettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        Keychain.write(data, service: service, account: account, label: "Tether security settings")
    }
}
