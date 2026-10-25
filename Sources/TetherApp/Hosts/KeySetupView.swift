import SwiftUI
import TetherCore
import SSHTransport
import KeySetupKit

/// Wizard: pick or generate a key, install it on the host, verify, update the config.
struct KeySetupView: View {
    enum Step: Int { case choose, working, done }

    struct LogLine: Identifiable {
        let id = UUID()
        var text: String
        var state: State
        enum State { case running, ok, failed }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: KeySetupRequest

    @State private var step: Step = .choose
    @State private var keys: [KeySetup.LocalKey] = []
    @State private var useExisting = false
    @State private var selectedKey: URL?
    @State private var keyName = ""
    @State private var passphrase = ""
    @State private var log: [LogLine] = []
    @State private var succeeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 28)).foregroundStyle(.tint)
                    .wiggleEffect(value: step)
                VStack(alignment: .leading) {
                    Text("Set Up SSH Key").font(.title3.weight(.semibold))
                    Text("for \(request.alias)").foregroundStyle(.secondary)
                }
            }

            switch step {
            case .choose: chooser
            case .working, .done: progress
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                if step == .choose {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Install Key") { Task { await run() } }
                        .keyboardShortcut(.defaultAction)
                        .prominentGlassButtonStyle()
                        .disabled(useExisting ? selectedKey == nil : keyName.isEmpty)
                } else {
                    Button(step == .done ? "Done" : "Working…") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(step != .done)
                }
            }
        }
        .padding(24)
        .frame(width: 500, height: 440)
        .animation(.smooth, value: step)
        .onAppear {
            keys = KeySetup.existingKeys()
            keyName = KeySetup.suggestedKeyURL(for: request.alias).lastPathComponent
            selectedKey = keys.first?.privateKeyURL
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $useExisting) {
                Text("Generate a new key").tag(false)
                Text("Use an existing key").tag(true)
            }
            .pickerStyle(.radioGroup)
            .disabled(keys.isEmpty)

            if useExisting {
                Picker("Key", selection: $selectedKey) {
                    ForEach(keys) { Text("\($0.name) — \($0.type)").tag(URL?.some($0.privateKeyURL)) }
                }
            } else {
                Form {
                    TextField("File name", text: $keyName)
                    SecureField("Passphrase (optional)", text: $passphrase)
                }
                .formStyle(.columns)
                Text("An Ed25519 key is created in ~/.ssh. A passphrase is stored in your macOS keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Tether appends the public key to ~/.ssh/authorized_keys on the server (you may be asked for your password once), verifies key login, then updates your SSH config.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(log) { line in
                HStack(spacing: 8) {
                    switch line.state {
                    case .running: ProgressView().controlSize(.small)
                    case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                    Text(line.text).textSelection(.enabled)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if step == .done {
                Label(succeeded ? "Key login works. Passwords are no longer needed for this host."
                                : "Setup did not finish. Your config was not changed.",
                      systemImage: succeeded ? "party.popper.fill" : "info.circle")
                    .foregroundStyle(succeeded ? .green : .secondary)
                    .padding(.top, 6)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring, value: log.count)
    }

    private func begin(_ text: String) -> Int {
        log.append(LogLine(text: text, state: .running))
        return log.count - 1
    }

    private func end(_ i: Int, ok: Bool, _ text: String? = nil) {
        log[i].state = ok ? .ok : .failed
        if let text { log[i].text = text }
    }

    private func run() async {
        step = .working
        defer { step = .done }
        let target = ConnectionTarget.alias(request.alias)
        let options = SSHOptions(settings: model.settings)

        var key: KeySetup.LocalKey
        if useExisting, let url = selectedKey, let k = keys.first(where: { $0.privateKeyURL == url }) {
            key = k
        } else {
            let i = begin("Generating key \(keyName)…")
            do {
                key = try await KeySetup.generate(at: AppPaths.userSSHDirectory.appendingPathComponent(keyName),
                                                  comment: "tether-\(request.alias)", passphrase: passphrase)
                end(i, ok: true, "Generated \(keyName)")
            } catch {
                end(i, ok: false, error.localizedDescription)
                return
            }
        }

        let i2 = begin("Installing public key on \(request.alias)…")
        do {
            try await KeySetup.install(key, executor: RemoteExecutor(target: target, options: options))
            end(i2, ok: true, "Public key installed")
        } catch {
            end(i2, ok: false, error.localizedDescription)
            return
        }

        let i3 = begin("Verifying key login…")
        guard await KeySetup.verify(key, target: target, options: options) else {
            end(i3, ok: false, "Key login failed (the server may not allow public keys)")
            return
        }
        end(i3, ok: true, "Key login verified")

        let i4 = begin("Updating SSH config…")
        do {
            try model.editConfig(alias: request.alias) { doc in
                try doc.setOption("IdentityFile", value: "~/.ssh/" + key.name, forHost: request.alias)
                try doc.setOption("IdentitiesOnly", value: "yes", forHost: request.alias)
            }
            end(i4, ok: true, "Config updated")
            succeeded = true
        } catch {
            end(i4, ok: false, error.localizedDescription)
        }
    }
}
