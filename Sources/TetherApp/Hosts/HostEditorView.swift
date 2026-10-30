import SwiftUI
import TetherCore
import SSHConfigKit
import KeySetupKit

/// Create or edit a Host block in the ssh config, plus Tether-only metadata.
struct HostEditorView: View {
    enum AuthMethod: String, CaseIterable, Identifiable {
        case key = "SSH Key", password = "Password", agent = "Agent / Default"
        var id: String { rawValue }
    }

    struct ExtraOption: Identifiable, Hashable {
        let id = UUID()
        var key: String
        var value: String
    }

    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let request: HostEditorRequest

    @State private var alias = ""
    @State private var hostName = ""
    @State private var user = ""
    @State private var port = ""
    @State private var proxyJump = ""
    @State private var auth: AuthMethod = .agent
    @State private var identityFile = ""
    @State private var password = ""
    @State private var hasSavedPassword = false
    @State private var forwardAgent = false
    @State private var identifyByName = false
    @State private var extras: [ExtraOption] = []
    @State private var groupID: UUID?
    @State private var color: TagColor = .none
    @State private var persistence: PersistenceMode?
    @State private var notes = ""
    @State private var setUpKeyAfterSave = false
    @State private var error: String?
    @State private var keys: [KeySetup.LocalKey] = []

    private static let managedKeys: Set<String> = ["hostname", "user", "port", "proxyjump", "identityfile",
                                                   "identitiesonly", "forwardagent", "hostkeyalias"]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Connection") {
                    TextField("Name (alias)", text: $alias, prompt: Text("my-server"))
                    TextField("Host name or IP", text: $hostName, prompt: Text("server.example.com"))
                    TextField("User", text: $user, prompt: Text("Default"))
                    TextField("Port", text: $port, prompt: Text("22"))
                }

                Section {
                    JumpChainEditor(chain: $proxyJump, excluding: alias)
                } header: {
                    Text("Jump Hosts")
                } footer: {
                    Text("Connections go through these hosts in order (ProxyJump). Each hop uses its own saved settings and password.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Authentication") {
                    Picker("Method", selection: $auth) {
                        ForEach(AuthMethod.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch auth {
                    case .key:
                        Picker("Key", selection: $identityFile) {
                            Text("Choose…").tag("")
                            ForEach(keys) { k in Text("\(k.name) (\(k.type))").tag("~/.ssh/" + k.name) }
                            if !identityFile.isEmpty && !keys.contains(where: { "~/.ssh/" + $0.name == identityFile }) {
                                Text(identityFile).tag(identityFile)
                            }
                        }
                        HStack {
                            Button("Browse…") { browseKey() }
                            Spacer()
                            if !keyAlreadyWorks {
                                Toggle("Generate & install a new key after saving", isOn: $setUpKeyAfterSave)
                                    .toggleStyle(.checkbox)
                            }
                        }
                    case .password:
                        SecureField("Password", text: $password,
                                    prompt: Text(hasSavedPassword ? "Saved — type to replace" : "Stored in your keychain"))
                        Text("The password is kept in the macOS keychain and offered to ssh automatically. It is never written to the config file.")
                            .font(.caption).foregroundStyle(.secondary)
                        if !keyAlreadyWorks {
                            Toggle("Set up an SSH key after saving (recommended)", isOn: $setUpKeyAfterSave)
                        }
                    case .agent:
                        Text("ssh will use your agent and default keys (~/.ssh/id_*).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Forward SSH agent", isOn: $forwardAgent)
                    Toggle("Identify by name, not by address", isOn: $identifyByName)
                        .help("Adds HostKeyAlias: the host key is remembered under this name, so another machine that happens to have the same IP (e.g. on a different network) is not confused with it.")
                }

                Section("Tether") {
                    Picker("Group", selection: $groupID) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.groups) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    Picker("Color", selection: $color) {
                        ForEach(TagColor.allCases) { c in
                            Label { Text(c.title) } icon: {
                                Image(systemName: "circle.fill").foregroundStyle(c.color ?? .secondary)
                            }
                            .tag(c)
                        }
                    }
                    Picker("Session persistence", selection: $persistence) {
                        Text("Default (\(model.settings.defaultPersistence.title))").tag(PersistenceMode?.none)
                        ForEach(PersistenceMode.allCases) { Text($0.title).tag(PersistenceMode?.some($0)) }
                    }
                    TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...4)
                }

                // Saved at once (they are Tether's own, not part of the ssh config).
                if let existing = request.alias {
                    HostFeaturesSection(target: .alias(existing))
                }

                Section {
                    ForEach($extras) { $opt in
                        HStack {
                            TextField("Option", text: $opt.key).frame(width: 170)
                            TextField("Value", text: $opt.value)
                            Button {
                                extras.removeAll { $0.id == opt.id }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                    }
                    Menu("Add Option") {
                        ForEach(SSHConfigKeywords.common.filter { !Self.managedKeys.contains($0.key.lowercased()) }, id: \.key) { kw in
                            Button(kw.key) { extras.append(ExtraOption(key: kw.key, value: "")) }
                                .help(kw.help)
                        }
                        Divider()
                        Button("Custom…") { extras.append(ExtraOption(key: "", value: "")) }
                    }
                } header: {
                    Text("Advanced Options")
                } footer: {
                    Text("Written to your SSH config as-is. Port forwards: LocalForward 8080 localhost:80")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.caption).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.alias == nil ? "Add Host" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .prominentGlassButtonStyle()
                    .disabled(alias.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 560, height: 680)
        .onAppear(perform: load)
    }

    private var keyAlreadyWorks: Bool {
        request.alias.map { !model.offersKeySetup($0) } ?? false
    }

    private func load() {
        keys = KeySetup.existingKeys()
        if let a = request.alias, let entry = model.config.entry(for: a) {
            alias = a
            hostName = entry.hostName ?? ""
            user = entry.user ?? ""
            port = entry.value("Port") ?? ""
            proxyJump = entry.proxyJump ?? ""
            identityFile = entry.identityFiles.first ?? ""
            forwardAgent = entry.value("ForwardAgent")?.lowercased() == "yes"
            identifyByName = entry.value("HostKeyAlias") != nil
            extras = entry.options
                .filter { !Self.managedKeys.contains($0.key.lowercased()) }
                .map { ExtraOption(key: $0.key, value: $0.value) }
            if !identityFile.isEmpty { auth = .key }
            // The saved password is never read into the form (it would bypass Touch ID); typing a new one replaces it.
            else if PasswordVault.hasPassword(for: a) { auth = .password; hasSavedPassword = true }
            let meta = model.metadata(for: a)
            groupID = meta.groupID
            color = meta.color
            persistence = meta.persistence
            notes = meta.notes
        } else if case .adhoc(let u, let h, let p, let j, let identity)? = request.prefill {
            if let identity { identityFile = identity; auth = .key }
            alias = h.split(separator: ".").first.map(String.init) ?? h
            hostName = h
            user = u ?? ""
            port = p.map(String.init) ?? ""
            proxyJump = j ?? ""
        }
    }

    private func browseKey() {
        let panel = NSOpenPanel()
        panel.directoryURL = AppPaths.userSSHDirectory
        panel.showsHiddenFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            identityFile = url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        }
    }

    private func save() {
        let newAlias = alias.trimmingCharacters(in: .whitespaces)
        var options: [(String, String)] = [
            ("HostName", hostName), ("User", user), ("Port", port), ("ProxyJump", proxyJump),
        ]
        if auth == .key && !identityFile.isEmpty {
            options += [("IdentityFile", identityFile), ("IdentitiesOnly", "yes")]
        }
        if forwardAgent { options.append(("ForwardAgent", "yes")) }
        if identifyByName { options.append(("HostKeyAlias", newAlias)) }
        options += extras.filter { !$0.key.isEmpty }.map { ($0.key, $0.value) }

        do {
            if let old = request.alias {
                try model.editConfig(alias: old) { doc in
                    try doc.renameHost(old, to: newAlias)
                    try doc.replaceOptions(forHost: newAlias, with: options)
                }
                if old != newAlias {
                    model.updateMetadata(for: newAlias) { $0 = model.metadata(for: old) }
                    // Read off the main thread: macOS may ask whether Tether may use the item first.
                    Task {
                        if let pw = await PasswordVault.passwordOffThread(for: old) {
                            PasswordVault.setPassword(pw, for: newAlias)
                            PasswordVault.deletePassword(for: old)
                        }
                    }
                }
            } else {
                try model.editConfig(alias: nil) { try $0.addHost(newAlias, options: options) }
            }
            model.updateMetadata(for: newAlias) {
                $0.groupID = groupID
                $0.color = color
                $0.persistence = persistence
                $0.notes = notes
            }
            if auth == .password && !password.isEmpty {
                PasswordVault.setPassword(password, for: newAlias)
            } else if auth != .password {
                PasswordVault.deletePassword(for: newAlias)
            }
            dismiss()
            if setUpKeyAfterSave {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    state.keySetupTarget = KeySetupRequest(alias: newAlias)
                }
            }
        } catch {
            withAnimation { self.error = error.localizedDescription }
        }
    }
}
