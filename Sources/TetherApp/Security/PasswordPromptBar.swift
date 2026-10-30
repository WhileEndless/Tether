import SwiftUI
import TetherCore
import SessionKit
import SSHTransport

extension AppModel {
    /// The keychain item for the password prompt showing in `session`, if any (with the last known
    /// foreground program; good enough for showing whether a saved password exists).
    func credentialKey(for session: TerminalSession) -> String? {
        guard let prompt = session.passwordPrompt else { return nil }
        // Resolved when the prompt appeared (with whose password it is), else a best guess.
        if let resolved = resolvedCredentials[session.id], resolved.prompt == prompt { return resolved.key }
        return CredentialKey.remote(prompt, hostKey: session.descriptor.target.key, program: session.activity?.command)
    }

    /// The keychain item for `prompt`, with the program asking right now (asked fresh from tmux), so
    /// saving and filling always agree on it.
    func currentCredentialKey(for prompt: PasswordPrompt, in session: TerminalSession) async -> String {
        let process = await session.foregroundProcess()
        let program = process == nil ? await session.foregroundCommand() ?? session.activity?.command : nil
        let key = CredentialKey.remote(prompt, hostKey: session.descriptor.target.key, process: process, program: program)
        resolvedCredentials[session.id] = (prompt, key)
        return key
    }

    func hasSavedPassword(for session: TerminalSession) -> Bool {
        credentialKey(for: session).map(PasswordVault.hasPassword(for:)) ?? false
    }

    /// Types the saved password into the prompt, after Touch ID (if required). The password is
    /// only sent if the same prompt is still waiting afterwards.
    func fillSavedPassword(in session: TerminalSession) {
        guard let prompt = session.passwordPrompt else { return }
        Task {
            let key = await currentCredentialKey(for: prompt, in: session)
            guard PasswordVault.hasPassword(for: key) else { return }
            let host = session.descriptor.target.displayName
            // Touch ID (if enabled) first; the password is read from the keychain only afterwards.
            guard await !refuseIfShell(prompt, in: session) else { return }
            let localKey = Self.isLocalKeyPassphrase(key)
            if localKey, await refuseUnlessReadingLocally(prompt, in: session) { return }
            guard await SecretGate.shared.authorize("enter the \(Self.label(prompt)) on \(host)") else { return }
            // Touch ID can take a while: check again that a shell has not come to the foreground meanwhile.
            if localKey, await refuseUnlessReadingLocally(prompt, in: session) { return }
            guard session.passwordPrompt == prompt, await !refuseIfShell(prompt, in: session),
                  let password = await PasswordVault.passwordOffThread(for: key),
                  session.passwordPrompt == prompt else { return }
            // Reading the keychain can wait for macOS's dialog: still the same program asking?
            if localKey, await refuseUnlessReadingLocally(prompt, in: session) { return }
            session.send(Array((password + "\r").utf8)[...])
            lastFilled[session.id] = Date()
        }
    }

    /// A prompt just appeared. With a saved password and auto-fill on, it is filled right away:
    /// the only thing left to do is Touch ID (nothing at all during the grace period).
    /// Prompts for *another* host's login (`user@host's password:`) are never filled on their own,
    /// since any server could print one; those wait for ⌥⌘P or a click.
    func passwordPromptAppeared(_ prompt: PasswordPrompt, in session: TerminalSession) {
        Task {
            // Whose password is it (sudo's caller, su's target user, …)? Also tells the bar whether
            // one is saved for exactly that.
            let key = await currentCredentialKey(for: prompt, in: session)
            // Automatically only for sudo (the user's own password), and only while sudo itself is
            // waiting — its "[sudo] password for alice:" or, on macOS, plain "Password:". su (often
            // root) and other prompts are filled with a click: a process name alone proves little.
            guard settings.autoFillPasswordPrompts, prompt.kind == .sudo || prompt.kind == .generic,
                  key.hasPrefix("sudo:"), PasswordVault.hasPassword(for: key),
                  case .waiting = await passwordTarget(for: PasswordPrompt(kind: .sudo, text: prompt.text), in: session),
                  session.passwordPrompt == prompt else { return }
            autoFillVerified(prompt, key: key, in: session)
        }
    }

    private func autoFillVerified(_ prompt: PasswordPrompt, key: String, in session: TerminalSession) {
        // The same prompt again right after filling means the password was wrong: let the user type.
        if let last = autoFilled[session.id], last.key == key, Date().timeIntervalSince(last.date) < 30 {
            autoFilled[session.id] = nil
            return
        }
        autoFilled[session.id] = (key, Date())
        fillSavedPassword(in: session)
    }

    /// What would receive a password typed into the terminal now.
    enum PasswordTarget {
        /// A program that asks for this kind of password is in the foreground.
        case waiting
        /// Another program; it may be asking (manual entry is allowed, automatic filling is not).
        case other(String)
        /// A shell: the password would run as a command and land in the shell history and recording.
        case shell(String)
        /// Cannot tell (no tmux): manual entry only.
        case unknown
    }

    /// Programs that ask for each kind of password.
    private static let askers: [PasswordPrompt.Kind: Set<String>] = [
        .sudo: ["sudo"],
        .generic: ["su", "sudo", "doas", "login", "passwd", "chsh", "chfn", "pkexec", "runuser"],
        .passphrase: ["ssh", "scp", "sftp", "ssh-add", "ssh-keygen", "git", "rsync"],
        .login: ["ssh", "scp", "sftp", "rsync", "git"],
    ]

    func passwordTarget(for prompt: PasswordPrompt, in session: TerminalSession) async -> PasswordTarget {
        guard let command = await session.foregroundCommand()?.trimmingCharacters(in: .whitespaces), !command.isEmpty else {
            return .unknown
        }
        if TerminalSession.isShell(command) { return .shell(command) }
        return Self.askers[prompt.kind]?.contains(command) == true ? .waiting : .other(command)
    }

    /// Manual entry is refused only when a shell is in the foreground; the user is told why.
    private func refuseIfShell(_ prompt: PasswordPrompt, in session: TerminalSession) async -> Bool {
        guard case .shell(let shell) = await passwordTarget(for: prompt, in: session) else { return false }
        let alert = NSAlert()
        alert.messageText = "The password was not typed"
        alert.informativeText = "No program is waiting for a password — \(shell) is in the foreground, so the password would have been run as a command and saved in the shell history and the recording."
        alert.runModal()
        return true
    }

    /// The keychain item of a key file on this Mac (not `passphrase:<host>:…` of a key on a server).
    static func isLocalKeyPassphrase(_ key: String) -> Bool {
        key.hasPrefix(SealedPasswordCache.passphrasePrefix + "/")
    }

    /// A key on this Mac: its passphrase is typed only while an ssh tool on this Mac reads one from
    /// this terminal, and every ssh reading is one that marks a server's questions. An ssh already
    /// connected shows whatever the server prints, and an older ssh shows a server's question in
    /// the same state as its own: either would send the passphrase to the server. Refuses (and
    /// says why) otherwise, also when the terminal cannot be looked at
    /// (`LocalTTY.refusalToTypeKeyPassphrase`).
    private func refuseUnlessReadingLocally(_ prompt: PasswordPrompt, in session: TerminalSession) async -> Bool {
        var refusal = "Tether cannot look at this terminal."
        if session.descriptor.target == .local, case .posix(let pid)? = await session.shellAnchor(),
           let tty = LocalTTY.path(ofProcess: Int32(pid)) {
            // Off the main thread: it may ask an ssh program for its version once.
            guard let why = await Task.detached(operation: { await LocalTTY.refusalToTypeKeyPassphrase(path: tty) }).value else { return false }
            refusal = why
        }
        let alert = NSAlert()
        alert.messageText = "The passphrase was not typed"
        alert.informativeText = refusal + " The passphrase of your key is typed only for ssh on this Mac. If you are sure a program here is asking, type it with Enter… instead."
        alert.runModal()
        return true
    }

    /// ⌥⌘P: fill the saved password, or open the secure entry sheet when there is none.
    func fillOrEnterPassword(in session: TerminalSession, state: WindowState?) {
        guard session.passwordPrompt != nil else { return }
        let rejected = lastFilled[session.id].map { Date().timeIntervalSince($0) < 60 } == true
        if hasSavedPassword(for: session) && !rejected { fillSavedPassword(in: session) } else { state?.passwordEntry = session }
    }

    /// Types a password the user just entered, optionally saving it for this kind of prompt.
    func enterPassword(_ password: String, in session: TerminalSession, save: Bool) {
        let prompt = session.passwordPrompt
        Task {
            if let prompt, await refuseIfShell(prompt, in: session) { return }
            if save, let prompt { PasswordVault.setPassword(password, for: await currentCredentialKey(for: prompt, in: session)) }
            session.send(Array((password + "\r").utf8)[...])
        }
    }

    /// The file name in `Enter passphrase for key '/path/id_example':`.
    static func keyFileName(_ text: String) -> String? {
        guard let m = text.firstMatch(of: #/passphrase for (?:key )?'([^']+)'/#) else { return nil }
        return (String(m.1) as NSString).lastPathComponent
    }

    static func label(_ prompt: PasswordPrompt) -> String {
        switch prompt.kind {
        case .sudo: prompt.user.map { "sudo password for \($0)" } ?? "sudo password"
        case .login: "password for \(prompt.user ?? "")@\(prompt.host ?? "")"
        case .passphrase: keyFileName(prompt.text).map { "passphrase of key \($0)" } ?? "key passphrase"
        case .generic: prompt.user.map { "password for \($0)" } ?? "password"
        }
    }
}

/// Shown over a terminal while it waits for a password (sudo, su, ssh, …): fill a saved one with
/// Touch ID, or type one (and optionally save it). Nothing is ever typed without a click.
struct PasswordPromptBar: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let session: TerminalSession
    let prompt: PasswordPrompt
    @Binding var dismissed: PasswordPrompt?

    var body: some View {
        let saved = model.hasSavedPassword(for: session)
        // Filled moments ago and asked again: the saved password is out of date.
        let rejected = saved && model.lastFilled[session.id].map { Date().timeIntervalSince($0) < 60 } == true
        GlassPill {
            HStack(spacing: 10) {
                Image(systemName: rejected ? "exclamationmark.triangle.fill" : prompt.kind == .sudo ? "lock.shield.fill" : "key.fill")
                    .foregroundStyle(rejected ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                    .symbolEffect(.bounce, value: prompt.text)
                Text(rejected ? "The saved \(AppModel.label(prompt)) was not accepted"
                              : "The terminal is asking for the \(AppModel.label(prompt))")
                    .lineLimit(1)
                if rejected {
                    Button("Enter New Password…") { state.passwordEntry = session }
                        .prominentGlassButtonStyle()
                        .help("Type the current password; it replaces the saved one")
                } else if saved {
                    Button {
                        model.fillSavedPassword(in: session)
                    } label: {
                        Label(SecretGate.shared.isRequired ? "Fill with \(SecretGate.shared.methodName)" : "Fill Saved Password",
                              systemImage: "touchid")
                    }
                    .prominentGlassButtonStyle()
                    .help("Types the saved password into the terminal (⌥⌘P)")
                }
                if !rejected {
                    Button(saved ? "Other…" : "Enter…") { state.passwordEntry = session }
                        .help("Type the password here; you can save it in the keychain")
                }
                Button {
                    withAnimation(.snappy) { dismissed = prompt }
                } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Hide")
            }
            .font(.callout)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Typing a password for a terminal prompt in a secure field (never shown, never recorded).
struct PasswordEntrySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: TerminalSession
    @State private var password = ""
    @State private var save = false
    @FocusState private var focused: Bool

    /// The saved password was filled in moments ago and the same prompt came back.
    private var savedWasRejected: Bool {
        guard let last = model.lastFilled[session.id] else { return false }
        return Date().timeIntervalSince(last) < 60 && model.hasSavedPassword(for: session)
    }

    var body: some View {
        let prompt = session.passwordPrompt
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "key.fill").font(.system(size: 26)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.map { AppModel.label($0).capitalizedFirst } ?? "Password").font(.headline)
                    Text("on \(session.descriptor.target.displayName)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let prompt {
                Text(prompt.text).font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(enter)
            if savedWasRejected {
                Label("The saved password was just filled in and not accepted — it may have changed. Type the current one; it replaces the saved one.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Toggle(savedWasRejected ? "Update the saved password" : "Save in Keychain for this prompt", isOn: $save)
                Text(SecretGate.shared.isRequired
                     ? "Next time, fill it with \(SecretGate.shared.methodName) (⌥⌘P)."
                     : "Next time, fill it with one click (⌥⌘P).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enter") { enter() }
                    .keyboardShortcut(.defaultAction)
                    .prominentGlassButtonStyle()
                    .disabled(password.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear {
            focused = true
            if savedWasRejected { save = true }   // a changed password replaces the old one
        }
    }

    private func enter() {
        guard !password.isEmpty else { return }
        model.enterPassword(password, in: session, save: save)
        password = ""
        dismiss()
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
