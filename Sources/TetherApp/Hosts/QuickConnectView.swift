import SwiftUI
import TetherCore
import SSHConfigKit
import KeySetupKit

/// ⌘N: connect to a saved host (searchable) or directly with user / host / port, without saving.
struct QuickConnectView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case saved = "Saved Hosts", direct = "Direct"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @AppStorage("quickConnectMode") private var mode: Mode = .saved

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)

            switch mode {
            case .saved: SavedHostPicker(onDone: { dismiss() })
            case .direct: DirectConnectForm(onDone: { dismiss() })
            }
        }
        .frame(width: 560)
        .onAppear {
            if model.hosts.isEmpty { mode = .direct }
            else if state.quickConnectSearch { mode = .saved }
            state.quickConnectSearch = false
        }
    }
}

/// Type-to-filter list of hosts from ssh config, plus This Mac. Typing `user@host:port` also works.
private struct SavedHostPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let onDone: () -> Void
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var matches: [SSHHostEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = model.ordered(model.hosts)
        guard !q.isEmpty else { return all }
        return all.filter { h in
            [h.alias, h.hostName, h.user].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    private var adhoc: ConnectionTarget? {
        guard let t = ConnectionTarget.parse(query, knownAliases: model.aliases), case .adhoc = t else { return nil }
        return t
    }

    /// "This Mac" (a local terminal): listed with no search, or when the search names it.
    private var showsLocal: Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return ["This Mac", "local", "localhost", localMachineName].contains { $0.localizedCaseInsensitiveContains(q) }
    }

    private var localIndex: Int { matches.count }
    private var adhocIndex: Int { matches.count + (showsLocal ? 1 : 0) }
    private var rowCount: Int { adhocIndex + (adhoc == nil ? 0 : 1) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search hosts, or type user@host:port", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { connect(newWindow: NSEvent.modifierFlags.contains(.command)) }
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(rowCount - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        // Saved hosts come first: typing part of a host's name selects that host,
                        // and the direct connection is offered after them.
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, host in
                            row(index: index, icon: host.proxyJump == nil ? "server.rack" : "point.3.connected.trianglepath.dotted",
                                title: host.alias ?? "",
                                subtitle: [host.user, host.hostName].compactMap { $0 }.joined(separator: "@")
                                    + (host.port.map { ":\($0)" } ?? "") + (host.proxyJump.map { "  via \($0)" } ?? ""))
                                .id(index)
                        }
                        if showsLocal {
                            row(index: localIndex, icon: "laptopcomputer", title: "This Mac",
                                subtitle: "Local terminal · \(localMachineName)")
                                .id(localIndex)
                        }
                        if let adhoc {
                            row(index: adhocIndex, icon: "arrow.right.circle", title: "Connect to \(adhoc.displayName)",
                                subtitle: "Direct connection (not saved)")
                                .id(adhocIndex)
                        }
                        if rowCount == 0 {
                            Text(model.hosts.isEmpty ? "No saved hosts yet — use Direct." : "No matching hosts")
                                .foregroundStyle(.secondary).padding(20)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: highlighted) { _, v in proxy.scrollTo(v) }
            }
            .frame(height: 300)
            Divider()
            HStack {
                Text("↩ Connect   ⌘↩ New window   ↑↓ Select").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .onAppear {
            focused = true
            // The sheet becomes key a moment after it appears; focus again once it has.
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func row(index: Int, icon: String, title: String, subtitle: String) -> some View {
        let selected = index == highlighted
        return HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(selected ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
                }
            }
            Spacer()
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background { if selected { RoundedRectangle(cornerRadius: 8).fill(Color.accentColor) } }
        .contentShape(Rectangle())
        .onTapGesture { highlighted = index; connect(newWindow: false) }
    }

    private func connect(newWindow: Bool) {
        let target: ConnectionTarget?
        if let host = matches[safe: highlighted] {
            target = host.alias.map { .alias($0) }
        } else if showsLocal && highlighted == localIndex {
            target = .local
        } else {
            target = adhoc
        }
        guard let target else { return }
        onDone()
        state.connect(target, mode: newWindow ? .window : .tab)
    }
}

/// Connect with plain fields. Optionally save the result as a host in ssh config.
private struct DirectConnectForm: View {
    enum Auth: String, CaseIterable, Identifiable {
        case auto = "Automatic", password = "Password", key = "Key File"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let onDone: () -> Void

    @AppStorage("direct.user") private var user = ""
    @AppStorage("direct.host") private var host = ""
    @AppStorage("direct.port") private var port = ""
    @AppStorage("direct.jump") private var jump = ""
    @State private var auth: Auth = .auto
    @State private var password = ""
    @State private var rememberPassword = false
    @State private var keyFile = ""
    @State private var saveAsHost = false
    @State private var alias = ""
    @State private var error: String?
    @State private var keys: [KeySetup.LocalKey] = []

    private var portNumber: Int? { Int(port.trimmingCharacters(in: .whitespaces)) }
    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && (port.isEmpty || (portNumber.map { 1...65535 ~= $0 } ?? false))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Host or IP", text: $host, prompt: Text("192.0.2.10 or server.example.com"))
                    TextField("User", text: $user, prompt: Text("Default (your Mac user name)"))
                    TextField("Port", text: $port, prompt: Text("22"))
                    HStack {
                        TextField("Jump host", text: $jump, prompt: Text("None — e.g. user@jump.example.com:2222"))
                        Menu {
                            ForEach(model.ordered(model.hosts).compactMap(\.alias), id: \.self) { a in
                                Button(a) { jump = jump.isEmpty ? a : jump + "," + a }
                            }
                        } label: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Use a saved host as jump host")
                    }
                }
                Section("Authentication") {
                    Picker("Method", selection: $auth) {
                        ForEach(Auth.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    switch auth {
                    case .auto:
                        Text("Uses your SSH agent and default keys; you are asked for a password if needed.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .password:
                        SecureField("Password", text: $password)
                        Toggle("Remember in Keychain", isOn: $rememberPassword)
                    case .key:
                        Picker("Key", selection: $keyFile) {
                            Text("Choose…").tag("")
                            ForEach(keys) { Text("\($0.name) (\($0.type))").tag("~/.ssh/" + $0.name) }
                        }
                    }
                }
                Section {
                    Toggle("Save as host", isOn: $saveAsHost)
                    if saveAsHost {
                        TextField("Name", text: $alias, prompt: Text(host.split(separator: ".").first.map(String.init) ?? "server"))
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 400)
            Divider()
            HStack {
                if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(!canConnect)
            }
            .padding(12)
        }
        .onAppear { keys = KeySetup.existingKeys() }
    }

    private func connect() {
        let h = host.trimmingCharacters(in: .whitespaces)
        let u = user.trimmingCharacters(in: .whitespaces)
        let j = jump.trimmingCharacters(in: .whitespaces)
        var target = ConnectionTarget.adhoc(user: u.isEmpty ? nil : u, host: h, port: portNumber, jump: j.isEmpty ? nil : j,
                                            identity: auth == .key && !keyFile.isEmpty ? keyFile : nil)
        if saveAsHost {
            let name = alias.trimmingCharacters(in: .whitespaces).isEmpty
                ? (h.split(separator: ".").first.map(String.init) ?? h) : alias.trimmingCharacters(in: .whitespaces)
            var options: [(String, String)] = [("HostName", h), ("User", u), ("Port", port), ("ProxyJump", j)]
            if auth == .key && !keyFile.isEmpty { options += [("IdentityFile", keyFile), ("IdentitiesOnly", "yes")] }
            do {
                try model.editConfig(alias: nil) { try $0.addHost(name, options: options) }
            } catch {
                self.error = error.localizedDescription
                return
            }
            target = .alias(name)
        }
        if auth == .password && !password.isEmpty {
            if rememberPassword || saveAsHost { PasswordVault.setPassword(password, for: target.key) }
            else { model.transientPasswords[target.key] = password }
        }
        onDone()
        state.connect(target)
    }
}
