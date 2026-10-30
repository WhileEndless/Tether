import SwiftUI
import TetherCore
import SSHTransport

/// Sheet shown when ssh asks for a password, passphrase or confirmation.
struct AskPassPromptView: View {
    @Environment(AppModel.self) private var model
    let prompt: PendingPrompt
    @State private var answer = ""
    @State private var save = false
    /// A fingerprint from the server's administrator, to compare with the one ssh received.
    @State private var expected = ""
    /// The trust button arms a moment after the prompt appears, so a Return typed elsewhere just as
    /// the window pops up cannot accept a server's key by accident.
    @State private var armed = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, value: prompt.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(hostLine).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if prompt.request.isServerText {
                Label("This question was written by the server, not by ssh.", systemImage: "server.rack")
                    .font(.caption).foregroundStyle(.secondary)
            } else if prompt.request.isUnverifiedPassphrasePrompt {
                // Not saved, not answered from the keychain: the server may have written it.
                Label("This ssh does not mark a server's questions (it is older than OpenSSH 8.4, or Tether could not check it), so the server may have written this. Answer only if you know your key is being opened here; nothing is saved.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if prompt.request.isUnverifiedPasswordPrompt {
                // Not filled in by itself and not remembered: a jump host may have written it.
                Label("This ssh does not mark a server's questions (it is older than OpenSSH 8.4, or Tether could not check it), so a jump host may have written this. Saved passwords are not filled in by themselves.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let key = unknownKey {
                newHostDetails(key)
            } else {
                Text(prompt.request.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if prompt.request.isNotice {
                // ssh waits for something outside Tether (a touch on the security key) and ends
                // this notice itself; nothing is typed.
                HStack {
                    ProgressView().controlSize(.small)
                    Text(isSecurityKeyTouch ? "Touch your security key to continue." : "Waiting for ssh…")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel Sign-In") { model.resolvePrompt(prompt, answer: nil, save: false) }
                        .keyboardShortcut(.cancelAction)
                }
            } else if prompt.request.isPermissionQuestion {
                HStack {
                    Spacer()
                    // "no" declines without ending ssh (ssh reads anything but "yes" as no).
                    Button("No") { model.resolvePrompt(prompt, answer: "no", save: false) }
                        .keyboardShortcut(.cancelAction)
                    Button("Yes") { model.resolvePrompt(prompt, answer: "yes", save: false) }
                        .keyboardShortcut(.defaultAction)
                        .prominentGlassButtonStyle()
                        .disabled(!armed)
                }
            } else if prompt.request.isConfirmation {
                HStack {
                    Spacer()
                    Button("Cancel") { model.resolvePrompt(prompt, answer: "no", save: false) }
                        .keyboardShortcut(.cancelAction)
                    Button("Trust and Continue") { model.resolvePrompt(prompt, answer: "yes", save: false) }
                        .keyboardShortcut(.defaultAction)
                        .prominentGlassButtonStyle()
                        // A fingerprint that was checked and does not match must not be accepted by accident.
                        .disabled(!armed || (unknownKey.map { k in !expected.trimmingCharacters(in: .whitespaces).isEmpty && !k.matches(expected) } ?? false))
                }
            } else {
                Group {
                    if prompt.request.isSecret {
                        SecureField("Required", text: $answer)
                    } else {
                        TextField("Required", text: $answer)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { submit() }

                if prompt.savedWasRejected {
                    Label(prompt.request.isPassphrasePrompt
                          ? "The saved passphrase did not open the key — it may have been changed. Type the current one; it replaces the saved one."
                          : "The saved password was not accepted — it may have changed. Type the current one; it replaces the saved one.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if prompt.request.isPasswordPrompt || prompt.request.isPassphrasePrompt {
                    VStack(alignment: .leading, spacing: 3) {
                        Toggle(prompt.savedWasRejected ? (prompt.request.isPassphrasePrompt ? "Update the saved passphrase" : "Update the saved password")
                               : "Remember in Keychain", isOn: $save)
                        Text(SecretGate.shared.isRequired
                             ? "Saved in your login keychain. Next time, \(SecretGate.shared.methodName) signs you in."
                             : "Saved in your login keychain and used automatically next time.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    // ssh goes on without this key (the next key, or the server's password); Cancel
                    // ends the sign-in.
                    if prompt.request.isPassphrasePrompt {
                        Button("Skip This Key") { model.resolvePrompt(prompt, answer: "", save: false) }
                            .help("Sign in without this key: ssh tries the next key or another way the server offers")
                    }
                    Spacer()
                    Button("Cancel") { model.resolvePrompt(prompt, answer: nil, save: false) }
                        .keyboardShortcut(.cancelAction)
                    Button("Continue") { submit() }
                        .keyboardShortcut(.defaultAction)
                        .prominentGlassButtonStyle()
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            focused = true
            if prompt.savedWasRejected { save = true }   // a changed password replaces the old one
        }
        .task(id: prompt.id) {
            // Once the panel is the key window (a moment after it appears): the field takes the
            // keyboard, so the password can be typed at once.
            for _ in 0..<10 where !focused {
                try? await Task.sleep(for: .milliseconds(50))
                focused = true
            }
        }
        .task(id: prompt.id) {
            armed = false
            try? await Task.sleep(for: .seconds(1))
            armed = true
        }
    }

    private var unknownKey: UnknownHostKey? {
        prompt.request.isConfirmation ? UnknownHostKey.parse(prompt.request.prompt) : nil
    }

    /// First connection to a server: what is being trusted, and a way to check it.
    private func newHostDetails(_ key: UnknownHostKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This is the first connection to \(key.host ?? "this server") from this Mac. Trusting it saves its key in known_hosts; if the key ever changes, Tether warns you.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(key.keyType ?? "Host") key fingerprint").font(.caption).foregroundStyle(.secondary)
                Text(key.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            if !key.knownAs.isEmpty {
                Text("The same key is already trusted as: \(key.knownAs.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("Optional: paste the fingerprint you were given", text: $expected)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                if !expected.trimmingCharacters(in: .whitespaces).isEmpty {
                    if key.matches(expected) {
                        Label("Matches — this is the expected server", systemImage: "checkmark.seal.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        Label("Does not match — do not trust this server", systemImage: "xmark.octagon.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
    }

    /// Which host is asking. With jump hosts this can differ from the tab's host.
    private var hostLine: String {
        if prompt.request.isPassphrasePrompt {
            let file = prompt.request.keyPath.map { ($0 as NSString).lastPathComponent } ?? "key"
            return "key \(file) on this Mac, to sign in to \(prompt.request.targetKey)"
        }
        let key = model.passwordKey(for: prompt.request)
        let target = prompt.request.targetKey
        return key == target ? "for \(target)" : "for \(key) — jump host on the way to \(target)"
    }

    private func submit() {
        model.resolvePrompt(prompt, answer: answer, save: save)
    }

    /// ssh's notice while a FIDO key (sk-ed25519, sk-ecdsa) waits to be touched.
    private var isSecurityKeyTouch: Bool { prompt.request.prompt.lowercased().contains("user presence") }

    private var icon: String {
        if prompt.request.isNotice { return "hand.tap" }
        if prompt.request.isPermissionQuestion { return "questionmark.circle" }
        if prompt.request.isConfirmation { return "checkmark.shield" }
        if prompt.request.isPassphrasePrompt { return "key.fill" }
        return "lock.fill"
    }

    private var title: String {
        if prompt.request.isNotice { return isSecurityKeyTouch ? "Security Key" : "ssh" }
        if prompt.request.isPermissionQuestion { return "ssh Asks" }
        if prompt.request.isConfirmation { return "Verify Host" }
        if prompt.request.isPassphrasePrompt { return "Key Passphrase" }
        if prompt.request.isPasswordPrompt { return "Password Required" }
        return "Authentication"
    }
}
