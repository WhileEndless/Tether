import AppKit
import LocalAuthentication
import TetherCore
import SSHConfigKit
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
        // Behind the lock screen nobody should be asked (a reconnect needing a saved password waits).
        await AppLock.shared.waitUntilUnlocked()
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

    /// The key file named by an `Enter passphrase for key '/path':` prompt, when it exists here.
    static func localKeyPath(in prompt: String) -> String? {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = p.firstMatch(of: #/passphrase for (?:key )?'(.+)'/#) else { return nil }
        let path = (String(m.1) as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue ? path : nil
    }

    /// The keychain item for a password prompt shown inside a terminal on `hostKey`.
    @MainActor
    /// `program` (the one asking, when known) keeps generic "Password:" prompts of different programs
    /// apart — su's password is never offered to another program's prompt.
    /// `process` (the one asking, as the host sees it) decides whose password is meant: sudo asks for
    /// its caller's, su for its target user's — also when the prompt only says "Password:" (macOS) —
    /// and other programs' "Password:" prompts are kept apart per program and user.
    static func remote(_ prompt: PasswordPrompt, hostKey: String, process: ForegroundProcess? = nil, program: String? = nil) -> String {
        if let p = process, prompt.kind == .sudo || prompt.kind == .generic {
            switch p.command {
            case "sudo": return "sudo:\(hostKey):\(prompt.user ?? p.user)"
            case "su": return "su:\(hostKey):\(p.suTarget)"
            case "doas": return "doas:\(hostKey):\(p.user)"
            default: break
            }
        }
        switch prompt.kind {
        case .sudo: return "sudo:\(hostKey):\(prompt.user ?? "self")"
        case .login:
            // ssh from inside the session: reuse the saved login password of a known host.
            let model = AppModel.shared
            if let host = prompt.host {
                // Only the saved host for this very user (several may point at the same server).
                func userMatches(_ entry: SSHHostEntry) -> Bool { prompt.user == nil || entry.user == nil || entry.user == prompt.user }
                if let entry = model.hosts.first(where: { $0.alias == host }), userMatches(entry) { return host }
                let candidates = model.hosts.filter { $0.hostName == host && userMatches($0) }.compactMap(\.alias)
                if candidates.count == 1 { return candidates[0] }
            }
            return "login:\(prompt.user ?? "")@\(prompt.host ?? "")"
        case .passphrase:
            // A key on this Mac: the same item ssh's own prompt (askpass) uses, so its passphrase is
            // kept once. A key on a server stays with that host.
            if hostKey == ConnectionTarget.local.key, let path = localKeyPath(in: prompt.text) { return passphrase(keyPath: path) }
            return "passphrase:\(hostKey):\(prompt.text)"
        case .generic:
            let asker = (process?.command ?? program).flatMap { $0.isEmpty || TerminalSession.shells.contains($0) ? nil : $0 }
            let user = process.map { ":" + $0.user } ?? ""
            return "prompt:\(hostKey):\(asker.map { $0 + user + ":" } ?? "")\(prompt.user ?? prompt.text)"
        }
    }

    /// Readable description of a keychain item name for the settings list.
    static func describe(_ account: String) -> (symbol: String, title: String, detail: String) {
        let parts = account.split(separator: ":", maxSplits: 2).map(String.init)
        switch parts.first {
        case "sudo" where parts.count == 3:
            return ("lock.shield", "sudo on \(parts[1])", parts[2] == "self" ? "your account" : "for \(parts[2])")
        case "su" where parts.count == 3:
            return ("person.2.badge.key", "su on \(parts[1])", "to \(parts[2])")
        case "doas" where parts.count == 3:
            return ("lock.shield", "doas on \(parts[1])", "for \(parts[2])")
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
