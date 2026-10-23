import SwiftUI
import TetherCore

/// Sheet shown when ssh asks for a password, passphrase or confirmation.
struct AskPassPromptView: View {
    @Environment(AppModel.self) private var model
    let prompt: PendingPrompt
    @State private var answer = ""
    @State private var save = false
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
            Text(prompt.request.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if prompt.request.isConfirmation {
                HStack {
                    Spacer()
                    Button("Cancel") { model.resolvePrompt(prompt, answer: "no", save: false) }
                        .keyboardShortcut(.cancelAction)
                    Button("Trust and Continue") { model.resolvePrompt(prompt, answer: "yes", save: false) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
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

                if prompt.request.isPasswordPrompt {
                    Toggle("Remember in Keychain", isOn: $save)
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
        .onAppear { focused = true }
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
        if prompt.request.prompt.lowercased().contains("passphrase") { return "key.fill" }
        return "lock.fill"
    }

    private var title: String {
        if prompt.request.isConfirmation { return "Verify Host" }
        if prompt.request.prompt.lowercased().contains("passphrase") { return "Key Passphrase" }
        if prompt.request.isPasswordPrompt { return "Password Required" }
        return "Authentication"
    }
}
