import SwiftUI
import TetherCore
import SSHTransport
import KeySetupKit

/// Wizard: pick or generate a key (optionally with a passphrase), install it on the host, verify
/// that it alone logs in, then update the config.
struct KeySetupView: View {
    enum Step: Int { case choose, working, done }

    struct LogLine: Identifiable {
        let id = UUID()
        var text: String
        var state: State
        enum State { case running, ok, failed, note }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: KeySetupRequest

    @State private var step: Step = .choose
    @State private var keys: [KeySetup.LocalKey] = []
    @State private var useExisting = false
    @State private var selectedKey: URL?
    @State private var keyType: KeySetup.KeyType = .ed25519
    @State private var keyName = ""
    @State private var passphrase = ""
    @State private var confirmation = ""
    /// The passphrase of an existing key, when it has one and Tether does not know it yet.
    @State private var existingPassphrase = ""
    @State private var remember = true
    @State private var addToAgent = false
    @State private var log: [LogLine] = []
    @State private var succeeded = false

    private var keyURL: URL { AppPaths.userSSHDirectory.appendingPathComponent(keyName) }
    private var selected: KeySetup.LocalKey? { keys.first { $0.privateKeyURL == selectedKey } }

    /// What keeps the wizard from going on, said in a few words (nil: ready).
    private var problem: String? {
        if useExisting { return selected == nil ? "Choose a key." : nil }
        let name = keyName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty || name.contains("/") || name.hasPrefix(".") { return "Enter a file name." }
        if KeySetup.isTaken(keyURL) { return "A key with this name exists; it is never replaced." }
        if passphrase != confirmation { return "The passphrases do not match." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                if step == .choose, let problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if step == .choose {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(useExisting ? "Install Key" : "Create and Install") { Task { await run() } }
                        .keyboardShortcut(.defaultAction)
                        .prominentGlassButtonStyle()
                        .disabled(problem != nil)
                } else {
                    Button(step == .done ? "Done" : "Working…") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(step != .done)
                }
            }
        }
        .padding(24)
        .frame(width: 540, height: 560)
        .animation(.smooth, value: step)
        .onAppear {
            keys = KeySetup.existingKeys()
            keyName = KeySetup.suggestedKeyURL(for: request.alias, type: keyType).lastPathComponent
            selectedKey = keys.first?.privateKeyURL
            remember = model.settings.rememberKeyPassphrases
            addToAgent = model.settings.addNewKeysToAgent
        }
        .onChange(of: keyType) { old, new in
            // Follow the type in the suggested name, unless the user typed their own.
            if keyName == KeySetup.suggestedKeyURL(for: request.alias, type: old).lastPathComponent {
                keyName = KeySetup.suggestedKeyURL(for: request.alias, type: new).lastPathComponent
            }
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $useExisting) {
                Text("Create a new key").tag(false)
                Text("Use an existing key").tag(true)
            }
            .pickerStyle(.radioGroup)
            .disabled(keys.isEmpty)

            if useExisting {
                Form {
                    Picker("Key", selection: $selectedKey) {
                        ForEach(keys) { k in
                            Text("\(k.name) — \(k.type)\(k.isEncrypted == true ? " · passphrase" : "")").tag(URL?.some(k.privateKeyURL))
                        }
                    }
                    if selected?.isEncrypted == true, !hasSavedPassphrase(selected) {
                        SecureField("Its passphrase", text: $existingPassphrase)
                        Toggle("Remember the passphrase in Tether", isOn: $remember)
                    }
                }
                .formStyle(.columns)
            } else {
                Form {
                    Picker("Type", selection: $keyType) {
                        ForEach(KeySetup.KeyType.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("File name", text: $keyName)
                    SecureField("Passphrase", text: $passphrase)
                    SecureField("Again", text: $confirmation)
                    Toggle("Remember the passphrase in Tether", isOn: $remember)
                        .disabled(passphrase.isEmpty)
                    Toggle("Also let other programs use the key (macOS ssh-agent)", isOn: $addToAgent)
                }
                .formStyle(.columns)
                Text(passphrase.isEmpty
                     ? "Without a passphrase, anyone who gets the key file can use it. With one, the file alone is not enough."
                     : remember ? "Tether keeps the passphrase in your keychain and gives it to ssh when it asks (after Touch ID, if you turned that on in Settings ▸ Passwords)."
                                : "ssh asks for the passphrase every time it logs in with the key.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Tether adds the public key to ~/.ssh/authorized_keys on the server (you may be asked for your password once), checks that the key alone logs in, then sets it in your SSH config.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(log) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    switch line.state {
                    case .running: ProgressView().controlSize(.small)
                    case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    case .note: Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                    Text(line.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
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

    private func hasSavedPassphrase(_ key: KeySetup.LocalKey?) -> Bool {
        key.map { PasswordVault.hasPassword(for: CredentialKey.passphrase(keyPath: $0.privateKeyURL.path)) } ?? false
    }

    private func begin(_ text: String) -> Int {
        log.append(LogLine(text: text, state: .running))
        return log.count - 1
    }

    private func end(_ i: Int, ok: Bool, _ text: String? = nil) {
        log[i].state = ok ? .ok : .failed
        if let text { log[i].text = text }
    }

    private func note(_ text: String) { log.append(LogLine(text: text, state: .note)) }

    private func run() async {
        step = .working
        defer { step = .done }
        let target = ConnectionTarget.alias(request.alias)
        let options = SSHOptions(settings: model.settings)

        // The key, and its passphrase when Tether knows it (nil: ssh asks, as at any login).
        var key: KeySetup.LocalKey
        var secret: String?
        if useExisting, let k = selected {
            key = k
            secret = existingPassphrase.isEmpty ? nil : existingPassphrase
        } else {
            let i = begin("Creating \(keyType == .ed25519 ? "an Ed25519" : "an RSA 4096") key \(keyName)…")
            do {
                key = try await KeySetup.generate(at: keyURL, comment: "tether-\(request.alias)", passphrase: passphrase, type: keyType)
                end(i, ok: true, "Created ~/.ssh/\(keyName)\(passphrase.isEmpty ? " (no passphrase)" : ", protected with a passphrase")")
            } catch {
                end(i, ok: false, error.localizedDescription)
                return
            }
            secret = passphrase.isEmpty ? nil : passphrase
        }

        let i2 = begin("Adding the public key on \(request.alias)…")
        do {
            try await KeySetup.install(key, executor: RemoteExecutor(target: target, options: options))
            end(i2, ok: true, "Public key added to ~/.ssh/authorized_keys on \(request.alias)")
        } catch {
            end(i2, ok: false, error.localizedDescription)
            return
        }

        let i3 = begin("Checking that the key alone logs in…")
        if let failure = await KeySetup.verify(key, target: target, options: options, passphrase: secret) {
            end(i3, ok: false, failure)
            return
        }
        end(i3, ok: true, "Key login works")

        // Where the passphrase is kept (only once it is known to be right).
        if let secret, remember {
            PasswordVault.setPassword(secret, for: CredentialKey.passphrase(keyPath: key.privateKeyURL.path))
            note("The passphrase is kept in Tether's keychain.")
        }
        var agentWorks = false
        if !useExisting, addToAgent {
            do {
                try await KeySetup.addToAgent(key, passphrase: secret ?? "")
                agentWorks = true
                note("Added to the macOS ssh-agent for other programs.")
            } catch {
                note("Could not add the key to the macOS ssh-agent: \(error.localizedDescription)")
            }
        }

        let i4 = begin("Updating SSH config…")
        do {
            try model.editConfig(alias: request.alias) { doc in
                try doc.setOption("IdentityFile", value: "~/.ssh/" + key.name, forHost: request.alias)
                try doc.setOption("IdentitiesOnly", value: "yes", forHost: request.alias)
                if agentWorks {
                    try doc.setOption("AddKeysToAgent", value: "yes", forHost: request.alias)
                    try doc.setOption("UseKeychain", value: "yes", forHost: request.alias)
                }
            }
            end(i4, ok: true, "Config updated: IdentityFile ~/.ssh/\(key.name)\(agentWorks ? ", AddKeysToAgent, UseKeychain" : "")")
            model.updateMetadata(for: request.alias) { $0.keyLoginWorks = true }
            succeeded = true
        } catch {
            end(i4, ok: false, error.localizedDescription)
        }
    }
}
