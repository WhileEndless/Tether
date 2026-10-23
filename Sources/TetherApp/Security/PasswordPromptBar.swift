import SwiftUI
import TetherCore
import SessionKit

extension AppModel {
    /// The keychain item for the password prompt showing in `session`, if any.
    func credentialKey(for session: TerminalSession) -> String? {
        session.passwordPrompt.map { CredentialKey.remote($0, hostKey: session.descriptor.target.key) }
    }

    func hasSavedPassword(for session: TerminalSession) -> Bool {
        credentialKey(for: session).map(PasswordVault.hasPassword(for:)) ?? false
    }

    /// Types the saved password into the prompt, after Touch ID (if required). The password is
    /// only sent if the same prompt is still waiting afterwards.
    func fillSavedPassword(in session: TerminalSession) {
        guard let prompt = session.passwordPrompt, let key = credentialKey(for: session),
              let password = PasswordVault.password(for: key) else { return }
        Task {
            let host = session.descriptor.target.displayName
            guard await SecretGate.shared.authorize("enter the \(Self.label(prompt)) on \(host)") else { return }
            guard session.passwordPrompt == prompt else { return }
            session.send(Array((password + "\r").utf8)[...])
        }
    }

    /// A prompt just appeared. With a saved password and auto-fill on, it is filled right away:
    /// the only thing left to do is Touch ID (nothing at all during the grace period).
    /// Prompts for *another* host's login (`user@host's password:`) are never filled on their own,
    /// since any server could print one; those wait for ⌥⌘P or a click.
    func passwordPromptAppeared(_ prompt: PasswordPrompt, in session: TerminalSession) {
        guard settings.autoFillPasswordPrompts, prompt.kind != .login,
              let key = credentialKey(for: session), PasswordVault.hasPassword(for: key) else { return }
        // The same prompt again right after filling means the password was wrong: let the user type.
        if let last = autoFilled[session.id], last.key == key, Date().timeIntervalSince(last.date) < 30 {
            autoFilled[session.id] = nil
            return
        }
        autoFilled[session.id] = (key, Date())
        fillSavedPassword(in: session)
    }

    /// ⌥⌘P: fill the saved password, or open the secure entry sheet when there is none.
    func fillOrEnterPassword(in session: TerminalSession, state: WindowState?) {
        guard session.passwordPrompt != nil else { return }
        if hasSavedPassword(for: session) { fillSavedPassword(in: session) } else { state?.passwordEntry = session }
    }

    /// Types a password the user just entered, optionally saving it for this kind of prompt.
    func enterPassword(_ password: String, in session: TerminalSession, save: Bool) {
        if save, let key = credentialKey(for: session) { PasswordVault.setPassword(password, for: key) }
        session.send(Array((password + "\r").utf8)[...])
    }

    static func label(_ prompt: PasswordPrompt) -> String {
        switch prompt.kind {
        case .sudo: prompt.user.map { "sudo password for \($0)" } ?? "sudo password"
        case .login: "password for \(prompt.user ?? "")@\(prompt.host ?? "")"
        case .passphrase: "key passphrase"
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
        GlassPill {
            HStack(spacing: 10) {
                Image(systemName: prompt.kind == .sudo ? "lock.shield.fill" : "key.fill")
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, value: prompt.text)
                Text("The terminal is asking for the \(AppModel.label(prompt))")
                    .lineLimit(1)
                if saved {
                    Button {
                        model.fillSavedPassword(in: session)
                    } label: {
                        Label(SecretGate.shared.isRequired ? "Fill with \(SecretGate.shared.methodName)" : "Fill Saved Password",
                              systemImage: "touchid")
                    }
                    .buttonStyle(.glassProminent)
                    .help("Types the saved password into the terminal (⌥⌘P)")
                }
                Button(saved ? "Other…" : "Enter…") { state.passwordEntry = session }
                    .help("Type the password here; you can save it in the keychain")
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
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Save in Keychain for this prompt", isOn: $save)
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
                    .buttonStyle(.glassProminent)
                    .disabled(password.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear { focused = true }
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
