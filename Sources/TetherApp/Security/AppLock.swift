import AppKit
import CryptoKit
import LocalAuthentication
import Observation
import RecordingKit
import TetherCore

/// Optional lock for the whole app (Settings ▸ Security ▸ App Lock).
///
/// While locked every Tether window is covered, no terminal receives keys, menu commands do nothing,
/// and the key of encrypted recordings is dropped from memory (search and transcripts cannot read
/// them). Sessions that are already open keep running and keep recording. At launch nothing is
/// restored until Tether is unlocked.
@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()

    private(set) var isLocked = false
    /// A wrong password slows the next attempt down (1, 2, 4 … 60 s).
    private(set) var retryAfter: Date?
    private(set) var unlocking = false

    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var afterFirstUnlock: [() -> Void] = []
    @ObservationIgnored private var observing = false

    private var settings: AppSettings { AppModel.shared.settings }
    var mode: AppLockMode { settings.appLockMode }

    // MARK: Launch

    /// Locks at launch when App Lock is on; `work` (restoring sessions) runs once unlocked.
    func start(then work: @escaping () -> Void) {
        observeSleep()
        // A Tether password exists in the keychain: never open without it, whatever the
        // preferences say (they may have been edited, or their keychain copy removed).
        if RecordingKeyStore.hasPassword && mode != .password {
            AppModel.shared.settings.appLockMode = .password
        }
        // Set before anything can record: with encryption on and no key yet, output is sealed to
        // the key's public half (saved earlier), or not recorded at all when there is none.
        RecordingKeyStore.provideSealing()
        RecordingCrypto.encryptNew = settings.encryptRecordings
        if mode == .off {
            installKey(RecordingKeyStore.trustedStoredKey())
            work()
        } else {
            isLocked = true
            afterFirstUnlock.append(work)
        }
    }

    /// Runs `work` now if unlocked, otherwise right after the next unlock.
    func whenUnlocked(_ work: @escaping () -> Void) {
        if isLocked { afterFirstUnlock.append(work) } else { work() }
    }

    // MARK: Unlocking

    var methodName: String { SecretGate.shared.methodName }

    /// Touch ID can unlock: the system lock, or a Tether password with "also unlock with Touch ID".
    var canUseSystemUnlock: Bool { mode == .system || (mode == .password && settings.unlockWithTouchID) }

    /// Touch ID / Apple Watch / the Mac's password.
    func unlockWithSystem() async {
        guard isLocked, canUseSystemUnlock, !unlocking, !screenAway else { return }
        // With a Tether password, Touch ID needs the keychain copy of the very same key.
        let key = mode == .password ? RecordingKeyStore.keychainCopyOfPasswordKey() : RecordingKeyStore.trustedStoredKey()
        if mode == .password && key == nil { return }
        unlocking = true
        defer { unlocking = false }
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return }
        do {
            try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock Tether")
            didUnlock(key: key)
        } catch {}
    }

    /// The Tether password. Returns false when it is wrong (and delays the next try).
    func unlock(password: String) async -> Bool {
        guard isLocked, mode == .password, !unlocking else { return false }
        if let retryAfter, retryAfter > Date() { return false }
        unlocking = true
        defer { unlocking = false }
        // Key derivation is deliberately slow: off the main thread.
        let key = await Task.detached(priority: .userInitiated) { RecordingKeyStore.unwrap(password: password) }.value
        guard let key else {
            failures += 1
            retryAfter = Date().addingTimeInterval(min(pow(2, Double(failures - 1)), 60))
            return false
        }
        didUnlock(key: key)
        return true
    }

    private func didUnlock(key: SymmetricKey?) {
        failures = 0
        retryAfter = nil
        installKey(key)
        isLocked = false
        showHiddenWindows()
        let work = afterFirstUnlock
        afterFirstUnlock = []
        work.forEach { $0() }
    }

    /// Makes the recording key available to readers and (when encryption is on) new recordings.
    /// Encryption needs the Tether password: without its key nothing new is recorded.
    func installKey(_ key: SymmetricKey?) {
        RecordingCrypto.key = key
        if key != nil { RecordingKeyStore.saveSealing() }
        RecordingCrypto.encryptNew = settings.encryptRecordings
        // Command history files encrypted with this key can be read now.
        if key != nil { AppModel.shared.commandHistory.reload() }
    }

    // MARK: Locking

    func lock() {
        guard mode != .off, !isLocked else { return }
        isLocked = true
        RecordingCrypto.key = nil          // open recorders keep writing with their own copy
        SecretGate.shared.lock()
        AppModel.shared.transientPasswords.removeAll()
        AppModel.shared.recentPasswords.removeAll()
        AskPassPanel.shared.update(nil)
        // Sheets show the lock screen themselves (`appLockCover`), so Tether can be unlocked from
        // them too and nothing behind them gets the keyboard. Rename prompts are closed.
        for case let state? in NSApp.windows.map({ AppModel.shared.workspaces.state(of: $0) }) { state.renamingSession = nil }
        // Panels would stay above the lock screen: hidden until unlocked.
        for window in NSApp.windows where window.isVisible && window is NSPanel && !window.isSheet {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            hiddenWhileLocked.append(window)
        }
        for window in NSApp.windows { window.makeFirstResponder(nil) }   // minimized ones too
        NSApp.windows.first { $0.isVisible && !$0.isSheet && !($0 is NSPanel) }?.makeKey()
    }

    @ObservationIgnored private var hiddenWhileLocked: [NSWindow] = []

    private func showHiddenWindows() {
        for window in hiddenWhileLocked {
            window.alphaValue = 1
            window.ignoresMouseEvents = false
        }
        hiddenWhileLocked = []
        AppModel.shared.refreshPromptPanel()
    }

    /// The Mac is asleep, its display is off, or its screen is locked: no one is there to answer Touch ID.
    var screenAway: Bool { systemAsleep || displayAsleep || screenLocked }
    @ObservationIgnored private var systemAsleep = false
    @ObservationIgnored private var displayAsleep = false
    @ObservationIgnored private var screenLocked = false

    private func observeSleep() {
        guard !observing else { return }
        observing = true
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping @MainActor (AppLock) -> Void) {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { change(AppLock.shared) }
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        on(workspace, NSWorkspace.willSleepNotification) { $0.systemAsleep = true; $0.lockIfWanted() }
        on(workspace, NSWorkspace.didWakeNotification) { $0.systemAsleep = false; $0.offerSystemUnlock() }
        on(workspace, NSWorkspace.screensDidSleepNotification) { $0.displayAsleep = true; $0.lockIfWanted() }
        on(workspace, NSWorkspace.screensDidWakeNotification) { $0.displayAsleep = false; $0.offerSystemUnlock() }
        on(distributed, .init("com.apple.screenIsLocked")) { $0.screenLocked = true; $0.lockIfWanted() }
        on(distributed, .init("com.apple.screenIsUnlocked")) { $0.screenLocked = false; $0.offerSystemUnlock() }
        // Coming back to Tether (a click on its window, the Dock, ⌘Tab) asks for Touch ID right away.
        on(NotificationCenter.default, NSApplication.didBecomeActiveNotification) { $0.offerSystemUnlock() }
    }

    private func lockIfWanted() {
        if settings.lockOnSleep { lock() }
    }

    /// Asks for Touch ID now if it can unlock and someone is there to answer: Tether is the active app
    /// and the Mac's screen is not locked. (A prompt raised while the screen is locked would be gone by
    /// the time the user is back, leaving only the Unlock button.)
    func offerSystemUnlock() {
        guard isLocked, canUseSystemUnlock, !unlocking, !screenAway, NSApp.isActive else { return }
        Task { await unlockWithSystem() }
    }

    /// Suspends until Tether is unlocked (immediately if it is not locked).
    func waitUntilUnlocked() async {
        guard isLocked else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            afterFirstUnlock.append { cont.resume() }
        }
    }

    // MARK: Changing the mode (Settings ▸ Security)

    /// Confirms it is really the user before switching the lock off or changing how it works.
    func confirmWithSystem(_ reason: String) async -> Bool {
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }

    /// Switches to the Tether password (from off or the system lock).
    func enablePassword(_ password: String) -> Bool {
        // The key in memory (encrypted recordings exist), or a brand-new one — never one found in the
        // keychain, which another program could have placed there.
        let key = RecordingCrypto.key ?? SymmetricKey(size: .bits256)
        guard RecordingKeyStore.setPassword(password, for: key, keepKeychainCopy: settings.unlockWithTouchID) else { return false }
        RecordingCrypto.key = key
        RecordingKeyStore.saveSealing()
        AppModel.shared.settings.appLockMode = .password
        return true
    }

    /// Changes the Tether password (the current one is checked).
    func changePassword(current: String, new: String) async -> Bool {
        guard let key = await Task.detached(operation: { RecordingKeyStore.unwrap(password: current) }).value else { return false }
        return RecordingKeyStore.setPassword(new, for: key, keepKeychainCopy: settings.unlockWithTouchID)
    }

    /// Leaves the Tether password for `mode` (the current password is checked).
    func disablePassword(current: String, to mode: AppLockMode) async -> Bool {
        guard !settings.encryptRecordings else { return false }   // encryption needs the password
        guard let key = await Task.detached(operation: { RecordingKeyStore.unwrap(password: current) }).value else { return false }
        RecordingKeyStore.removePassword(keeping: key)
        RecordingCrypto.key = key
        RecordingKeyStore.saveSealing()
        AppModel.shared.settings.appLockMode = mode
        return true
    }

    /// Checks the Tether password (for turning encryption off and similar).
    func verify(password: String) async -> Bool {
        await Task.detached(operation: { RecordingKeyStore.unwrap(password: password) }).value != nil
    }

    /// Lets Touch ID unlock alongside the Tether password (after the Mac confirms it is its owner),
    /// or stops it. Only while unlocked: the key comes from memory.
    func setTouchIDUnlock(_ on: Bool) async -> Bool {
        guard mode == .password, let key = RecordingCrypto.key else { return false }
        if on, await !confirmWithSystem("unlock Tether with Touch ID") { return false }
        RecordingKeyStore.setKeychainCopy(on, of: key)
        AppModel.shared.settings.unlockWithTouchID = on
        return true
    }

    /// The Tether password is forgotten: start over, after the Mac's own check (Touch ID or the Mac
    /// password — so someone at the Mac cannot simply reset the lock away). Recordings encrypted until
    /// now (and encrypted command history files) cannot be opened any more and are deleted, as
    /// nothing could ever read them.
    func resetForgottenPassword() async -> Bool {
        guard await confirmWithSystem("reset the Tether password") else { return false }
        RecordingKeyStore.forgetAll()
        RecordingCrypto.key = nil
        Task { await RecordingStore.perform { RecordingStore.deleteEncrypted() } }
        AppModel.shared.commandHistory.forgetEncryptedFiles()
        AppModel.shared.settings.appLockMode = .off
        // Encryption needs a Tether password; it starts again once a new one is set.
        AppModel.shared.settings.encryptRecordings = false
        AppModel.shared.settings.unlockWithTouchID = false
        didUnlock(key: nil)
        return true
    }
}
