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
            }
            if let key = unknownKey {
                newHostDetails(key)
            } else {
                Text(prompt.request.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if prompt.request.isConfirmation {
                HStack {
                    Spacer()
                    Button("Cancel") { model.resolvePrompt(prompt, answer: "no", save: false) }
                        .keyboardShortcut(.cancelAction)
                    Button("Trust and Continue") { model.resolvePrompt(prompt, answer: "yes", save: false) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
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
                    Label("The saved password was not accepted — it may have changed. Type the current one; it replaces the saved one.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if prompt.request.isPasswordPrompt || prompt.request.isPassphrasePrompt {
                    VStack(alignment: .leading, spacing: 3) {
                        Toggle(prompt.savedWasRejected ? "Update the saved password" : "Remember in Keychain", isOn: $save)
                        Text(SecretGate.shared.isRequired
                             ? "Saved in your login keychain. Next time, \(SecretGate.shared.methodName) signs you in."
                             : "Saved in your login keychain and used automatically next time.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.resolvePrompt(prompt, answer: nil, save: false) }
                        .keyboardShortcut(.cancelAction)
                    Button("Continue") { submit() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
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
        let key = model.passwordKey(for: prompt.request)
        let target = prompt.request.targetKey
        return key == target ? "for \(target)" : "for \(key) — jump host on the way to \(target)"
    }

    private func submit() {
        model.resolvePrompt(prompt, answer: answer, save: save)
    }

    private var icon: String {
        if prompt.request.isConfirmation { return "checkmark.shield" }
        if prompt.request.isPassphrasePrompt { return "key.fill" }
        return "lock.fill"
    }

    private var title: String {
        if prompt.request.isConfirmation { return "Verify Host" }
        if prompt.request.isPassphrasePrompt { return "Key Passphrase" }
        if prompt.request.isPasswordPrompt { return "Password Required" }
        return "Authentication"
    }
}
