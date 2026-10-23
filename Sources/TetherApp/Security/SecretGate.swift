import AppKit
import LocalAuthentication
import TetherCore
import SessionKit

/// Asks for Touch ID (or the Mac's login password, or an Apple Watch) before a saved password
/// is used. Optional: Settings ▸ Passwords. After a successful check, saved passwords can be used
/// without asking again for a short time; locking the screen or sleeping ends that period.
///
/// Passwords themselves stay in the login keychain (encrypted by macOS and unlocked with the
/// user's login), so this is an extra check that someone at an unlocked Mac cannot use them silently.
@MainActor
final class SecretGate {
    static let shared = SecretGate()
    private var lastSuccess: Date?
    private var pending: Task<Bool, Never>?

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SecretGate.shared.lock() }
        }
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SecretGate.shared.lock() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SecretGate.shared.lock() }
        }
    }

    /// "Touch ID", or what macOS will ask for instead.
    var methodName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        return ctx.biometryType == .touchID ? "Touch ID" : "your Mac's password"
    }

    var isRequired: Bool { AppModel.shared.settings.requireAuthForSavedPasswords }

    /// True when the user confirmed (or no confirmation is required right now).
    func authorize(_ reason: String) async -> Bool {
        let settings = AppModel.shared.settings
        guard settings.requireAuthForSavedPasswords else { return true }
        if let last = lastSuccess, Date().timeIntervalSince(last) < Double(settings.authGraceSeconds) { return true }
        // Several connections may need a password at once; one prompt answers all of them.
        if let pending { return await pending.value }
        let task = Task<Bool, Never> { @MainActor in
            let ctx = LAContext()
            ctx.localizedCancelTitle = "Type It Instead"
            var error: NSError?
            guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
            do {
                try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
                return true
            } catch {
                return false
            }
        }
        pending = task
        let ok = await task.value
        pending = nil
        if ok { lastSuccess = Date() }
        return ok
    }

    /// Ends the grace period: the next saved password needs a new check.
    func lock() {
        lastSuccess = nil
    }
}

/// Names of keychain items. Login passwords keep the plain host key (as in earlier versions).
enum CredentialKey {
    static func passphrase(keyPath: String) -> String { "passphrase:" + keyPath }

    /// The keychain item for a password prompt shown inside a terminal on `hostKey`.
    @MainActor
    static func remote(_ prompt: PasswordPrompt, hostKey: String) -> String {
        switch prompt.kind {
        case .sudo: return "sudo:\(hostKey):\(prompt.user ?? "self")"
        case .login:
            // ssh from inside the session: reuse the saved login password of a known host.
            let model = AppModel.shared
            if let host = prompt.host {
                if model.aliases.contains(host) { return host }
                if let alias = model.hosts.first(where: { $0.hostName == host })?.alias { return alias }
            }
            return "login:\(prompt.user ?? "")@\(prompt.host ?? "")"
        case .passphrase: return "passphrase:\(hostKey):\(prompt.text)"
        case .generic: return "prompt:\(hostKey):\(prompt.user ?? prompt.text)"
        }
    }

    /// Readable description of a keychain item name for the settings list.
    static func describe(_ account: String) -> (symbol: String, title: String, detail: String) {
        let parts = account.split(separator: ":", maxSplits: 2).map(String.init)
        switch parts.first {
        case "sudo" where parts.count == 3:
            return ("lock.shield", "sudo on \(parts[1])", parts[2] == "self" ? "your account" : "for \(parts[2])")
        case "passphrase":
            return ("key.fill", "Key passphrase", parts.dropFirst().joined(separator: ":"))
        case "prompt" where parts.count == 3:
            return ("terminal", "Password on \(parts[1])", parts[2])
        case "login":
            return ("person.badge.key", "Login", parts.dropFirst().joined(separator: ":"))
        default:
            return ("network", "Login to \(account)", "SSH password")
        }
    }
}
