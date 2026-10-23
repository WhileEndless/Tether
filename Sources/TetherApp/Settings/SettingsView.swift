import SwiftUI
import TetherCore
import RecordingKit
import TerminalUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Terminal", systemImage: "terminal") { TerminalSettings() }
            Tab("Keyboard", systemImage: "keyboard") { KeyboardSettings() }
            Tab("Sessions", systemImage: "arrow.triangle.2.circlepath") { SessionSettings() }
            Tab("Recordings", systemImage: "record.circle") { RecordingSettings() }
            Tab("Transfers", systemImage: "arrow.up.arrow.down.circle") { TransferSettings() }
            Tab("Monitoring", systemImage: "gauge.with.dots.needle.33percent") { MonitoringSettings() }
            Tab("Passwords", systemImage: "key") { PasswordSettings() }
            Tab("SSH", systemImage: "lock.shield") { SSHSettings() }
        }
        .frame(width: 620, height: 520)
        .onChange(of: model.settings) { _, _ in model.settingsChanged() }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var store = model.settingsStore
        Form {
            Section {
                Toggle("Re-attach persistent sessions on launch", isOn: $store.settings.restoreSessionsOnLaunch)
                Toggle("Check for a new version at launch", isOn: $store.settings.checkForUpdates)
                Toggle("Keep running in the menu bar when the window is closed", isOn: $store.settings.keepRunningInMenuBar)
            } header: {
                Text("Startup")
            } footer: {
                Text("In the menu bar, closing the window hides Tether from the Dock while every session keeps running; click the menu bar icon to open it again with its tabs. ⌘Q quits (persistent sessions re-attach next time). The update check is one request to GitHub at launch; nothing is downloaded or sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tabs & Windows") {
                Toggle("Open new sessions in a separate window", isOn: $store.settings.openNewSessionsInWindow)
                Toggle("Ask before closing an online session", isOn: $store.settings.confirmCloseOnlineSessions)
                Toggle("Show archive in sidebar", isOn: $store.settings.showSidebarArchive)
                Picker("Sort sessions under a host", selection: $store.settings.sessionSortOrder) {
                    ForEach(SessionSortOrder.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Button("Restore All Settings to Defaults…", role: .destructive) { store.resetToDefaults() }
            }
            Section {
                HStack {
                    Text("Tether \(AppInfo.bundleVersion)")
                    Spacer()
                    Link("GitHub", destination: AppInfo.repository)
                    Link("Report an Issue", destination: AppInfo.issues)
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TerminalSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var store = model.settingsStore
        Form {
            Section("Appearance") {
                Picker("Colors", selection: $store.settings.theme) {
                    ForEach(TerminalThemeChoice.allCases) { Text($0.title).tag($0) }
                }
                if store.settings.theme == .system {
                    Picker("Terminal.app profile", selection: $store.settings.terminalProfile) {
                        Text("Default (\(TerminalAppProfile.defaultName ?? "Basic"))").tag("")
                        ForEach(TerminalAppProfile.availableNames(), id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Use the profile's font", isOn: $store.settings.fontFromProfile)
                    Text("Colors, font and background translucency are read from this Mac's Terminal settings, so Tether looks like your Terminal. Programs on the server (ls, vim…) choose which of these colors to use.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !(store.settings.theme == .system && store.settings.fontFromProfile) {
                    HStack {
                        TextField("Font", text: $store.settings.fontName, prompt: Text("System monospaced (SF Mono)"))
                        Button("Choose…") { FontPicker.show(current: store.settings.terminalFontName) { store.settings.fontName = $0 } }
                    }
                    Stepper("Size: \(Int(store.settings.fontSize)) pt", value: $store.settings.fontSize, in: 8...40)
                }
                Picker("Cursor", selection: $store.settings.cursorShape) {
                    ForEach(CursorShape.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Blinking cursor", isOn: $store.settings.cursorBlink)
            }
            Section("Behavior") {
                Stepper("Lines kept in memory: \(store.settings.scrollbackLines.formatted())",
                        value: $store.settings.scrollbackLines, in: 1_000...200_000, step: 5_000)
                Text("Older output stays in the session recording on disk: it is still searchable and can be opened with “Open Full History” when you scroll to the top. Fewer lines in memory keep long sessions light.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Bell", selection: $store.settings.bell) {
                    ForEach(BellMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Allow programs to use the mouse (vim, htop, tmux…)", isOn: $store.settings.allowMouseReporting)
                Text("Hold ⌥ while selecting to select text even when a program captures the mouse.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Copy text on selection", isOn: $store.settings.copyOnSelect)
            }
        }
        .formStyle(.grouped)
    }
}

private extension AppSettings {
    var terminalFontName: String { fontName }
}

/// Opens the system font panel restricted to fixed-pitch fonts.
@MainActor
enum FontPicker {
    private final class Receiver: NSObject {
        var onChange: ((String) -> Void)?
        @objc func changeFont(_ sender: NSFontManager?) {
            guard let sender else { return }
            let f = sender.convert(NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
            onChange?(f.fontName)
        }
    }
    private static let receiver = Receiver()

    static func show(current: String, onChange: @escaping (String) -> Void) {
        receiver.onChange = onChange
        let manager = NSFontManager.shared
        manager.target = receiver
        manager.action = #selector(Receiver.changeFont(_:))
        if let f = NSFont(name: current, size: 12) { manager.setSelectedFont(f, isMultiple: false) }
        manager.orderFrontFontPanel(nil)
    }
}

private struct KeyboardSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var store = model.settingsStore
        Form {
            Section {
                Toggle("Use Option as Meta key", isOn: $store.settings.optionAsMeta)
                Text("Required for Alt shortcuts in emacs, readline (⌥B / ⌥F) and many TUI apps. Turn off to type special characters with ⌥.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach($store.settings.keyMappings) { $m in
                    HStack {
                        Toggle("", isOn: $m.enabled).labelsHidden()
                        Text(m.shortcutDescription).font(.body.monospaced()).frame(width: 70, alignment: .leading)
                        if let clash = Shortcut.all.first(where: { $0.key != nil && $0.display == m.shortcutDescription }) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("In terminals this replaces \u{201C}\(clash.title)\u{201D}")
                        }
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Sends", text: $m.send).font(.body.monospaced())
                        Button {
                            store.settings.keyMappings.removeAll { $0.id == m.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button("Add Mapping…") { addMapping() }
                    Spacer()
                    Button("Restore macOS Defaults") { store.settings.keyMappings = KeyMapping.macDefaults }
                }
            } header: {
                Text("Key Mappings")
            } footer: {
                Text("Escapes: \\e (Esc), \\x01 (Ctrl-A), \\r, \\n, \\t, \\u2603. Unmapped keys — including all Ctrl keys — go straight to the remote program.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ShortcutsView(compact: true)
                    .frame(height: 320)
                HStack {
                    Text("Menu shortcuts can be changed in System Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Keyboard Settings…") { ShortcutsView.openSystemShortcuts() }
                }
            } header: {
                Text("App Shortcuts")
            }
        }
        .formStyle(.grouped)
    }

    private func addMapping() {
        KeyCaptureWindow.capture { mapping in
            model.settingsStore.settings.keyMappings.append(mapping)
        }
    }
}

/// Small panel that records the next key combination.
@MainActor
enum KeyCaptureWindow {
    private static var monitor: Any?

    static func capture(_ done: @escaping (KeyMapping) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Press a key combination"
        alert.informativeText = "The next key you press will be mapped. Edit what it sends in the list afterwards."
        alert.addButton(withTitle: "Cancel")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let names: [UInt16: String] = [123: "left", 124: "right", 125: "down", 126: "up", 51: "delete",
                                           117: "forwarddelete", 115: "home", 119: "end", 116: "pageup",
                                           121: "pagedown", 36: "return", 48: "tab", 53: "escape", 49: "space"]
            let key = names[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "").lowercased()
            let f = event.modifierFlags
            done(KeyMapping(key: key, command: f.contains(.command), option: f.contains(.option),
                            control: f.contains(.control), shift: f.contains(.shift), send: ""))
            NSApp.stopModal()
            alert.window.orderOut(nil)
            return nil
        }
        alert.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct TransferSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var store = model.settingsStore
        Form {
            Section {
                Picker("Pack many files into one stream", selection: $store.settings.transferArchiveMode) {
                    ForEach(TransferArchiveMode.allCases) { Text($0.title).tag($0) }
                }
                if store.settings.transferArchiveMode == .auto {
                    Stepper("Pack when a transfer has \(store.settings.transferArchiveThreshold) or more files",
                            value: $store.settings.transferArchiveThreshold, in: 2...10_000, step: 5)
                }
                Toggle("Compress packed transfers", isOn: $store.settings.transferCompress)
            } header: {
                Text("Many Files")
            } footer: {
                Text("Packed transfers are made with tar on one side and unpacked on the other in a single stream — no temporary archive is written, and nothing at the destination is overwritten. This is much faster than copying many small files one by one. Compression helps on slow connections; turn it off on fast local networks. The server needs tar (it almost always has it). You can also choose per upload.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Stepper("Transfer \(store.settings.transferParallel) item\(store.settings.transferParallel == 1 ? "" : "s") at the same time",
                        value: $store.settings.transferParallel, in: 1...8)
            } header: {
                Text("Parallel Transfers")
            } footer: {
                Text("Items that are not packed are copied with scp, several at once, in the order they were added. All of them share one authenticated connection to the host.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SessionSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var store = model.settingsStore
        Form {
            Section {
                Picker("Default persistence", selection: $store.settings.defaultPersistence) {
                    ForEach(PersistenceMode.allCases) { Text($0.title).tag($0) }
                }
                Text("Automatic uses tmux (control mode) if the server has it, then GNU screen, then a plain shell. Nothing is installed on the server.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("History restored on re-attach: \(store.settings.historyLinesOnReattach.formatted()) lines",
                        value: $store.settings.historyLinesOnReattach, in: 0...50_000, step: 1_000)
            } header: { Text("Persistence") }

            Section("Reconnecting") {
                Toggle("Reconnect automatically", isOn: $store.settings.autoReconnect)
                Stepper(store.settings.maxReconnectAttempts == 0 ? "Attempts: unlimited"
                        : "Attempts: \(store.settings.maxReconnectAttempts)",
                        value: $store.settings.maxReconnectAttempts, in: 0...100)
                Stepper("First retry after \(Int(store.settings.reconnectBaseDelay)) s",
                        value: $store.settings.reconnectBaseDelay, in: 1...30)
                Stepper("Longest wait between retries: \(Int(store.settings.reconnectMaxDelay)) s",
                        value: $store.settings.reconnectMaxDelay, in: 5...300, step: 5)
            }
            Section {
                Stepper("Keep-alive every \(store.settings.serverAliveInterval) s",
                        value: $store.settings.serverAliveInterval, in: 5...120, step: 5)
                Stepper("Drop after \(store.settings.serverAliveCountMax) missed keep-alives",
                        value: $store.settings.serverAliveCountMax, in: 1...10)
                Stepper("Treat as disconnected after \(Int(store.settings.stallTimeout)) s without an answer",
                        value: $store.settings.stallTimeout, in: 3...60)
            } header: {
                Text("Connection Health")
            } footer: {
                Text("tmux sessions are checked every 2 s, so a dead connection shows up within about \(Int(store.settings.stallTimeout)) s. Other sessions rely on keep-alives (about \(store.settings.serverAliveInterval * store.settings.serverAliveCountMax) s). Losing the network is detected immediately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RecordingSettings: View {
    @Environment(AppModel.self) private var model
    @State private var recordings: [RecordingInfo] = []

    var body: some View {
        @Bindable var store = model.settingsStore
        let total = recordings.reduce(0) { $0 + $1.size }
        let quota = Int64(store.settings.recordingQuotaMB) * 1024 * 1024
        Form {
            Section {
                Toggle("Record terminal output", isOn: $store.settings.recordingEnabled)
                Picker("Storage limit", selection: $store.settings.recordingQuotaMB) {
                    ForEach([128, 256, 512, 1024, 2048, 4096], id: \.self) { mb in
                        Text(Int64(mb * 1024 * 1024).byteString).tag(mb)
                    }
                }
                Picker("Compress recordings older than", selection: $store.settings.compressRecordingsAfterDays) {
                    Text("Never").tag(0)
                    ForEach([1, 3, 7, 14, 30], id: \.self) { Text("\($0) day\($0 == 1 ? "" : "s")").tag($0) }
                }
                Picker("Keep recordings", selection: $store.settings.recordingRetentionDays) {
                    Text("Until the limit is reached").tag(0)
                    ForEach([7, 30, 90, 365], id: \.self) { Text("\($0) days").tag($0) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(total), total: Double(max(quota, 1)))
                        .animation(.smooth, value: total)
                    Text("\(total.byteString) of \(quota.byteString) used · old recordings are compressed (about 5–10× smaller), then the oldest are removed")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Session Backups")
            } footer: {
                Text("Every session's output is saved so you can read the history even after the session is gone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Open Folder") { NSWorkspace.shared.open(AppPaths.recordingsDirectory) }
                    Spacer()
                    Button("Delete All Inactive…", role: .destructive) {
                        RecordingStore.deleteAll()
                        recordings = RecordingStore.all()
                    }
                }
                ForEach(recordings.prefix(50)) { r in
                    HStack {
                        Image(systemName: r.isActive ? "record.circle.fill" : r.isCompressed ? "doc.zipper" : "doc.text")
                            .foregroundStyle(r.isActive ? .red : .secondary)
                        VStack(alignment: .leading) {
                            Text(r.targetKey)
                            Text(r.modified.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(r.size.byteString).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { recordings = RecordingStore.all() }
    }
}

private struct MonitoringSettings: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var store = model.settingsStore
        Form {
            Section("Status Bar") {
                Toggle("Show host status above each terminal", isOn: $store.settings.showStatusStrip)
                Text("CPU, memory, disk, load, GPU and latency, streamed over the existing connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Host Panel") {
                Stepper("Refresh every \(Int(store.settings.monitorRefreshInterval)) s",
                        value: $store.settings.monitorRefreshInterval, in: 1...60)
                Toggle("Load system information automatically", isOn: $store.settings.monitorAutoLoad)
                Toggle("Confirm before sending signals to processes", isOn: $store.settings.confirmKill)
                Stepper("Log lines: \(store.settings.logLines)", value: $store.settings.logLines, in: 50...5_000, step: 50)
            }
            Section {
                Text("Monitoring runs small read-only shell commands over the existing SSH connection (/proc, ps, df, journalctl). Nothing is installed on the server.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SSHSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.settingsStore
        Form {
            Section("Configuration") {
                TextField("Config file", text: $store.settings.sshConfigPath, prompt: Text("~/.ssh/config"))
                TextField("ssh binary", text: $store.settings.sshBinary)
                TextField("scp binary", text: $store.settings.scpBinary)
                Picker("Unknown host keys", selection: $store.settings.hostKeyPolicy) {
                    ForEach(HostKeyPolicy.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Toggle("Share one connection per host (ControlMaster)", isOn: $store.settings.useControlMaster)
                Stepper("Keep shared connection for \(store.settings.controlPersistSeconds / 60) min after last use",
                        value: $store.settings.controlPersistSeconds, in: 60...3600, step: 60)
            } header: {
                Text("Multiplexing")
            } footer: {
                Text("Terminals, file transfers and monitoring reuse one authenticated connection, so you log in (and pass jump hosts) only once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PasswordSettings: View {
    @Environment(AppModel.self) private var model
    @State private var accounts: [String] = []
    @State private var locked = false

    var body: some View {
        @Bindable var store = model.settingsStore
        Form {
            Section {
                Toggle("Ask for \(SecretGate.shared.methodName) before using a saved password", isOn: $store.settings.requireAuthForSavedPasswords)
                if store.settings.requireAuthForSavedPasswords {
                    Picker("Ask again after", selection: $store.settings.authGraceSeconds) {
                        Text("Every time").tag(0)
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                        Text("1 hour").tag(3600)
                    }
                    HStack {
                        Text("Locking the screen or sleeping always asks again.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(locked ? "Locked" : "Lock Now") { SecretGate.shared.lock(); locked = true }
                            .disabled(locked)
                    }
                }
            } header: {
                Text("Touch ID")
            } footer: {
                Text("Saving is always optional: tick “Remember in Keychain” when signing in, or save a password from the bar that appears when a terminal asks for one. Passwords stay in your login keychain, encrypted by macOS, and are sent only to the host they belong to.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Offer to fill passwords in terminals", isOn: $store.settings.detectPasswordPrompts)
                Toggle("Fill saved passwords automatically", isOn: $store.settings.autoFillPasswordPrompts)
                    .disabled(!store.settings.detectPasswordPrompts)
            } header: {
                Text("sudo, su and other prompts")
            } footer: {
                Text("When a terminal shows a prompt such as “[sudo] password for alice:”, “Password:” (su) or “alice@host's password:”, a saved password is filled right away (after Touch ID, if required) — or, with automatic filling off, a bar offers it (⌥⌘P). Without a saved password, ⌥⌘P opens a secure field to type one and save it. Another host's login prompt (“alice@host's password:”) is never filled on its own, a wrong password is not retried, and prompts for a new password are ignored. Applies to sessions connected after the change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Saved in Keychain") {
                if accounts.isEmpty {
                    Text("No passwords saved").foregroundStyle(.secondary)
                }
                ForEach(accounts, id: \.self) { a in
                    let d = CredentialKey.describe(a)
                    HStack {
                        Image(systemName: d.symbol).foregroundStyle(.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.title)
                            Text(d.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            PasswordVault.deletePassword(for: a)
                            accounts = PasswordVault.allAccounts()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { accounts = PasswordVault.allAccounts(); locked = false }
    }
}
