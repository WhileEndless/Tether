import SwiftUI
import TetherCore
import KeySetupKit

/// Settings ▸ SSH ▸ Keys: the key pairs in ~/.ssh, whether each has a passphrase, and adding,
/// changing or removing it. Defaults for new keys made by the key setup wizard.
struct SSHKeysSection: View {
    @Environment(AppModel.self) private var model
    @State private var keys: [KeySetup.LocalKey] = []
    @State private var editing: KeySetup.LocalKey?

    var body: some View {
        @Bindable var store = model.settingsStore
        Section {
            if keys.isEmpty {
                Text("No key pairs in ~/.ssh yet. “Set Up SSH Key…” on a host creates one.")
                    .foregroundStyle(.secondary)
            }
            ForEach(keys) { key in
                HStack {
                    Image(systemName: key.isEncrypted == true ? "lock.fill" : "key")
                        .foregroundStyle(key.isEncrypted == true ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 18)
                        .help(key.isEncrypted == true ? "Protected with a passphrase" : key.isEncrypted == false ? "No passphrase" : "Unknown format")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(key.name)
                        Text([key.type, key.comment].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Menu {
                        Button(key.isEncrypted == true ? "Change or Remove Passphrase…" : "Add Passphrase…") { editing = key }
                            .disabled(key.isEncrypted == nil)
                        Button("Copy Public Key") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(key.publicKey + (key.comment.isEmpty ? "" : " " + key.comment), forType: .string)
                        }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([key.privateKeyURL]) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            Toggle("Remember passphrases of new keys in Tether", isOn: $store.settings.rememberKeyPassphrases)
            Toggle("Also add new keys to the macOS ssh-agent", isOn: $store.settings.addNewKeysToAgent)
                .help("For Terminal, git and other programs: the passphrase goes to the macOS keychain, and the host's config gets AddKeysToAgent and UseKeychain")
        } header: {
            Text("Keys")
        } footer: {
            Text("When ssh asks for a key's passphrase, Tether answers with the one it keeps (after Touch ID, if that is on in Passwords), or asks you and can remember it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { keys = KeySetup.existingKeys() }
        .sheet(item: $editing) { key in
            PassphraseSheet(key: key) { keys = KeySetup.existingKeys() }
        }
    }
}

/// Adds, changes or removes a key's passphrase (`KeySetup.changePassphrase`).
private struct PassphraseSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let key: KeySetup.LocalKey
    let changed: () -> Void

    @State private var old = ""
    @State private var new = ""
    @State private var again = ""
    @State private var remember = true
    @State private var working = false
    @State private var error: String?

    private var account: String { CredentialKey.passphraseItem(keyPath: key.privateKeyURL.path) }
    private var hasOld: Bool { key.isEncrypted == true }
    private var savedOld: Bool { hasOld && PasswordVault.hasPassword(for: account) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(hasOld ? "Change the Passphrase of \(key.name)" : "Add a Passphrase to \(key.name)")
                .font(.headline)
            Form {
                if hasOld && !savedOld {
                    SecureField("Current passphrase", text: $old)
                }
                SecureField(hasOld ? "New passphrase (empty removes it)" : "Passphrase", text: $new)
                SecureField("Again", text: $again)
                Toggle("Remember it in Tether", isOn: $remember).disabled(new.isEmpty)
            }
            .formStyle(.columns)
            Text("The key file is changed in place; a copy is kept until it is done, and put back if anything fails. Servers need nothing new: the key stays the same.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Working…" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .prominentGlassButtonStyle()
                    .disabled(working || new != again || (!hasOld && new.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { remember = model.settings.rememberKeyPassphrases }
    }

    private func save() async {
        working = true
        defer { working = false }
        var current = old
        if hasOld && savedOld {
            // The kept passphrase is used, after Touch ID when that is on.
            guard await SecretGate.shared.authorize("change the passphrase of \(key.name)"),
                  let saved = await PasswordVault.passwordOffThread(for: account) else { error = "The saved passphrase could not be used."; return }
            current = saved
        }
        do {
            _ = try await KeySetup.changePassphrase(key, old: current, new: new)
            // Saved under the key's own name (an item an earlier version named differently goes).
            let item = CredentialKey.passphrase(keyPath: key.privateKeyURL.path), earlier = account
            if earlier != item { PasswordVault.deletePassword(for: earlier) }
            if remember && !new.isEmpty { PasswordVault.setPassword(new, for: item) } else { PasswordVault.deletePassword(for: item) }
            // The old passphrase remembered for this run opens nothing any more.
            model.passwordCache.forget(login: earlier)
            model.passwordCache.forget(login: item)
            changed()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
