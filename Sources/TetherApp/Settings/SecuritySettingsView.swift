import SwiftUI
import RecordingKit
import TetherCore

/// Settings ▸ Security: App Lock, encrypted recordings, keyboard protection. Each part works on its
/// own; changing how Tether is unlocked asks for the current unlock first.
struct SecuritySettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var lock = AppLock.shared
    @State private var sheet: PasswordSheet.Purpose?
    @State private var status: (encrypted: Int, total: Int) = (0, 0)
    @State private var working: String?
    @State private var message: String?
    /// Encryption was asked for before a Tether password existed: switch it on once one is set.
    @State private var pendingEncryption = false
    @State private var showReset = false

    var body: some View {
        @Bindable var store = model.settingsStore
        Form {
            Section {
                Picker("Unlock Tether with", selection: Binding(get: { store.settings.appLockMode }, set: changeMode)) {
                    ForEach(AppLockMode.allCases) { Text($0.title).tag($0) }
                }
                if store.settings.appLockMode == .password {
                    Toggle("Also unlock with \(lock.methodName)", isOn: Binding(
                        get: { store.settings.unlockWithTouchID },
                        set: { on in Task { if await !lock.setTouchIDUnlock(on) { message = "Could not change how Tether unlocks." } } }))
                        .disabled(lock.isLocked)
                    Button("Change Tether Password…") { sheet = .change }
                    Button("Forgot the Tether Password…", role: .destructive) { showReset = true }
                }
                Toggle("Lock when the Mac sleeps or its screen locks",
                       isOn: model.guardedSetting(\.lockOnSleep, reason: "stop locking Tether on sleep") { _, new in !new })
                    .disabled(store.settings.appLockMode == .off)
                Button("Lock Now") { lock.lock() }
                    .disabled(store.settings.appLockMode == .off)
            } header: {
                Text("App Lock")
            } footer: {
                Text("When Tether opens (and after sleep, if chosen) its windows stay covered until it is unlocked; sessions are restored only then. Open sessions keep running while locked. A Tether password also protects the key of encrypted recordings. With “Also unlock with \(lock.methodName)”, a copy of that key is kept in your login keychain so Touch ID — or your Mac's login password — can open Tether too: convenient, but then whoever can sign in to this Mac as you can open the recordings as well. The Tether password always works.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Encrypt recordings", isOn: Binding(get: { store.settings.encryptRecordings }, set: setEncryption))
                    .disabled(working != nil || lock.isLocked)
                HStack {
                    Text(status.total == 0 ? "No recordings yet"
                         : "\(status.encrypted) of \(status.total) recording\(status.total == 1 ? "" : "s") encrypted")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let working {
                        ProgressView().controlSize(.small)
                        Text(working).foregroundStyle(.secondary)
                    }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Recordings")
            } footer: {
                Text("Off by default. Turning it on asks you to set a Tether password (if there is none yet) and then encrypts all recordings — existing ones too, in the background. Turning it off asks for that password and decrypts them again. Recordings still open at that moment follow once their session ends. AES-256-GCM, accelerated by the Mac's hardware; search, transcripts and scrolling back work as usual. Only files on this Mac are encrypted; servers are not affected. Host names and session titles (the sidebar and archive lists) are not encrypted, and encrypting files in place cannot erase copies a backup already holds.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Secure Keyboard Entry at password prompts",
                       isOn: model.guardedSetting(\.secureKeyboardAtPasswordPrompts, reason: "turn off Secure Keyboard Entry") { _, new in !new })
            } header: {
                Text("Typing Passwords")
            } footer: {
                Text("While a terminal waits for a password, no other app can read the keys you type. Saved passwords are typed only when the program that asks (sudo, su, ssh, …) is really in the foreground; one is never typed into a shell, where it would end up in the shell history and the recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("App Lock, encryption, the saved-password checks (Touch ID, how long it lasts, automatic filling), Secure Keyboard Entry, the ssh and scp programs, the SSH config file and host-key checking are also kept in your keychain. If another program changes them in Tether's preferences, Tether puts them back at launch and says so. Changes that weaken protection ask for Touch ID or your Mac password first.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("App Lock protects Tether itself. Connections that are open keep working while it is locked, and other programs running as you on this Mac could use them (as with any ssh connection sharing); quit Tether, or end the sessions, to close them.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Protected Settings")
            }
        }
        .formStyle(.grouped)
        .task { await refreshStatus() }
        .sheet(item: $sheet) { purpose in
            PasswordSheet(purpose: purpose) { text, outcome in
                switch outcome {
                case .passwordSet where pendingEncryption, .encryptionConfirmed: pendingEncryption = false; applyEncryption(true)
                case .encryptionStopped: applyEncryption(false); decryptExisting()
                default: break
                }
                message = text
            }
            .appLockCover()
        }
        .sheet(isPresented: $showReset) { ResetSecuritySheet().appLockCover() }
        .onChange(of: sheet == nil) { _, closed in if closed && model.settings.appLockMode != .password { pendingEncryption = false } }
    }

    // MARK: App Lock

    private func changeMode(_ new: AppLockMode) {
        let current = model.settings.appLockMode
        guard new != current else { return }
        switch (current, new) {
        case (.password, _) where model.settings.encryptRecordings:
            message = "Encrypted recordings need the Tether password. Turn off “Encrypt recordings” first."
        case (.password, _):
            sheet = .leave(to: new)           // needs the current Tether password
        case (_, .password):
            sheet = .set
        default:
            Task {
                // Switching the system lock on or off: the Mac confirms it is the user.
                guard await lock.confirmWithSystem(new == .off ? "turn off App Lock" : "turn on App Lock") else { return }
                model.settings.appLockMode = new
            }
        }
    }

    // MARK: Encryption

    private func setEncryption(_ on: Bool) {
        if on {
            // Encryption is protected by the Tether password: set one first if there is none.
            // Without a Tether password: set one (typed twice). With one: confirm it first.
            pendingEncryption = true
            sheet = model.settings.appLockMode == .password ? .startEncryption : .set
        } else {
            sheet = .stopEncryption   // the Tether password, then everything is decrypted
        }
    }

    private func applyEncryption(_ on: Bool) {
        model.settings.encryptRecordings = on
        lock.installKey(RecordingCrypto.key)
        message = on ? "Recordings are encrypted from now on." : "Recordings are no longer encrypted."
        if on { encryptExisting() } else { Task { await refreshStatus() } }
    }

    private func encryptExisting() {
        guard let key = RecordingCrypto.writerKey else { return }
        working = "Encrypting…"
        Task {
            let n = await Task.detached(priority: .utility) { RecordingStore.encryptAll(with: key) }.value
            working = nil
            message = n > 0 ? "Encrypted \(n) existing recording\(n == 1 ? "" : "s")." : message
            await refreshStatus()
        }
    }

    private func decryptExisting() {
        Task {
            working = "Decrypting…"
            let n = await Task.detached(priority: .utility) { RecordingStore.decryptAll() }.value
            working = nil
            message = "Decrypted \(n) recording\(n == 1 ? "" : "s")."
            await refreshStatus()
        }
    }

    private func refreshStatus() async {
        status = await Task.detached(priority: .utility) { RecordingStore.encryptionStatus() }.value
    }
}

/// Setting, changing or leaving the Tether password.
struct PasswordSheet: View {
    enum Purpose: Identifiable, Hashable {
        case set, change, leave(to: AppLockMode)
        /// Turning encryption off: the password, then everything is decrypted.
        case stopEncryption
        /// Turning encryption on with a Tether password already set: confirm it.
        case startEncryption
        var id: String { "\(self)" }
    }

    enum Outcome { case passwordSet, passwordChanged, lockChanged, encryptionStopped, encryptionConfirmed }

    let purpose: Purpose
    let done: (String, Outcome) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var repeated = ""
    @State private var error: String?
    @State private var busy = false

    static let minimumLength = 8

    private var needsCurrent: Bool { if case .set = purpose { false } else { true } }
    private var needsNew: Bool {
        switch purpose {
        case .set, .change: true
        case .leave, .stopEncryption, .startEncryption: false
        }
    }

    private var canSave: Bool {
        (!needsCurrent || !current.isEmpty)
            && (!needsNew || (new.count >= Self.minimumLength && new == repeated))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if needsCurrent { SecureField("Current Tether password", text: $current) }
            if needsNew {
                SecureField("New password (at least \(Self.minimumLength) characters)", text: $new)
                SecureField("Repeat the new password", text: $repeated)
                if !repeated.isEmpty && new != repeated { Text("The passwords do not match.").font(.caption).foregroundStyle(.red) }
            }

            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(actionTitle) { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(!canSave || busy)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(22)
        .frame(width: 420)
    }

    private var title: String {
        switch purpose {
        case .set: "Set a Tether Password"
        case .change: "Change the Tether Password"
        case .leave(let mode): mode == .off ? "Turn Off App Lock" : "Unlock with \(AppLock.shared.methodName) Instead"
        case .stopEncryption: "Turn Off Encryption"
        case .startEncryption: "Turn On Encryption"
        }
    }

    private var explanation: String {
        switch purpose {
        case .set: "Tether will ask for it when it opens. It also protects the key of encrypted recordings: without it they cannot be opened, so choose one you will remember."
        case .change: "Encrypted recordings stay readable; only the password that protects their key changes."
        case .leave: "Enter the current Tether password. The key of encrypted recordings then moves back to your login keychain."
        case .stopEncryption: "Enter the Tether password. All recordings are then decrypted back into ordinary files on this Mac."
        case .startEncryption: "Enter the Tether password. All recordings are then encrypted with the key it protects."
        }
    }

    private var actionTitle: String {
        switch purpose {
        case .set: "Set Password"
        case .change: "Change Password"
        case .leave: "Continue"
        case .stopEncryption: "Turn Off"
        case .startEncryption: "Turn On"
        }
    }

    private func save() {
        busy = true
        error = nil
        Task {
            defer { busy = false }
            let lock = AppLock.shared
            switch purpose {
            case .set:
                guard lock.enablePassword(new) else { error = "The password could not be saved in the keychain."; return }
                done("Tether now asks for its password when it opens.", .passwordSet)
            case .change:
                guard await lock.changePassword(current: current, new: new) else { error = "The current password is not correct."; return }
                done("The Tether password was changed.", .passwordChanged)
            case .leave(let mode):
                guard await lock.disablePassword(current: current, to: mode) else { error = "The password is not correct."; return }
                done(mode == .off ? "App Lock is off." : "Tether now unlocks with \(lock.methodName).", .lockChanged)
            case .stopEncryption:
                guard await lock.verify(password: current) else { error = "The password is not correct."; return }
                done("Encryption is off; decrypting the recordings…", .encryptionStopped)
            case .startEncryption:
                guard await lock.verify(password: current) else { error = "The password is not correct."; return }
                done("Encryption is on; encrypting the recordings…", .encryptionConfirmed)
            }
            dismiss()
        }
    }
}
