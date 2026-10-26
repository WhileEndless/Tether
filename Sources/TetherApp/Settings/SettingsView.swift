import SwiftUI
import MonitorKit
import TetherCore
import RecordingKit
import TerminalUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            TerminalSettings().tabItem { Label("Terminal", systemImage: "terminal") }
            KeyboardSettings().tabItem { Label("Keyboard", systemImage: "keyboard") }
            SessionSettings().tabItem { Label("Sessions", systemImage: "arrow.triangle.2.circlepath") }
            RecordingSettings().tabItem { Label("Recordings", systemImage: "record.circle") }
            TransferSettings().tabItem { Label("Transfers", systemImage: "arrow.up.arrow.down.circle") }
            MonitoringSettings().tabItem { Label("Monitoring", systemImage: "gauge.with.dots.needle.33percent") }
            SecuritySettingsPane().tabItem { Label("Security", systemImage: "lock") }
            PasswordSettings().tabItem { Label("Passwords", systemImage: "key") }
            SSHSettings().tabItem { Label("SSH", systemImage: "lock.shield") }
        }
        .frame(width: 620, height: 520)
        .onChange(of: model.settings) { _, _ in model.settingsChanged() }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

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
                Picker("New tabs open", selection: $store.settings.newTabPosition) {
                    ForEach(NewTabPosition.allCases) { Text($0.title).tag($0) }
                }
                Picker("New tabs to the same host start in", selection: $store.settings.newTabDirectory) {
                    ForEach(NewTabDirectory.allCases) { Text($0.title).tag($0) }
                }
                .help("⌘T and New Session to Same Host: the folder the current tab's shell is in, or the home folder")
                Toggle("Ask before closing an online session", isOn: $store.settings.confirmCloseOnlineSessions)
                Toggle("Show archive in sidebar", isOn: $store.settings.showSidebarArchive)
                Toggle("Name tabs after coding agent sessions", isOn: $store.settings.tabTitleFromAgent)
                    .help("A tab running Claude Code, Codex or opencode (in tmux) takes the name of its session, unless you renamed the tab yourself")
                Toggle("Browse folders of this Mac in Finder", isOn: $store.settings.browseLocalInFinder)
                    .help("Browse (⌘E) in a terminal of this Mac opens its folder in Finder; off, in Tether's file manager. Hosts always use the file manager.")
                Picker("Sort sessions under a host", selection: $store.settings.sessionSortOrder) {
                    ForEach(SessionSortOrder.allCases) { Text($0.title).tag($0) }
                }
            }
            Section {
                Button("Restore All Settings to Defaults…", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Restore all settings to their defaults?", isPresented: $confirmReset) {
                        Button("Restore Defaults", role: .destructive) { store.resetToDefaults() }
                    } message: {
                        Text("Security settings (App Lock, encryption, saved-password checks, the ssh program and config) are kept; change those in their own sections.")
                    }
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
                Toggle("Programs may clear the scrollback", isOn: $store.settings.programsMayClearScrollback)
                Text("Off: `clear`, and programs that redraw everything (Claude Code), clear the screen but never erase the history above it. On: they erase it as in other terminals. Either way the recording keeps everything, for search, export and the transcript, where repeated redraws appear once.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Bell", selection: $store.settings.bell) {
                    ForEach(BellMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show notifications from programs (Claude Code, builds…)", isOn: $store.settings.notifyFromPrograms)
                Toggle("Notify when the bell rings in a tab you are not looking at", isOn: $store.settings.notifyOnBell)
                Text("Programs can ask for attention — `printf '\\e]9;Done\\a'` after a long job. Tether understands the common sequences (OSC 9, OSC 777, OSC 99, the bell, also passed through tmux), marks the tab with a bell and, when you are not looking at it, shows a macOS notification.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Notify when a coding agent waits for you", isOn: $store.settings.notifyAgentWaiting)
                Toggle("Notify when a coding agent is done", isOn: $store.settings.notifyAgentDone)
                Picker("Look at coding agents every", selection: $store.settings.agentPollInterval) {
                    Text("2 s").tag(2.0)
                    Text("4 s").tag(4.0)
                    Text("10 s").tag(10.0)
                }
                Text("Claude Code waiting for plan approval, a question or a permission marks its tab with a raised hand. Nothing needs to be set up in Claude Code: Tether reads the status Claude Code keeps for each session on the host (only on hosts where an agent runs in a tab), and understands the Program Status Protocol (OSC 7501) that Claude Code speaks outside tmux. Setting Claude Code's notifications to the terminal bell (`/config` ▸ Notifications) works too.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Allow programs to use the mouse (vim, htop, tmux…)", isOn: $store.settings.allowMouseReporting)
                Text("Hold ⌥ while selecting to select text even when a program captures the mouse.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Copy text on selection", isOn: $store.settings.copyOnSelect)
            }
            Section("Tabs") {
                Toggle("Show coding agents' symbols (Claude Code, Codex, …)", isOn: $store.settings.showAgentIcons)
                Toggle("Mark programs that are open but idle (vim, less)", isOn: $store.settings.markIdlePrograms)
                Picker("A quiet command is working above", selection: $store.settings.workingCPUThreshold) {
                    Text("2 % CPU").tag(2.0)
                    Text("5 % CPU").tag(5.0)
                    Text("15 % CPU").tag(15.0)
                    Text("40 % CPU").tag(40.0)
                }
                Picker("Back to quiet after no output for", selection: $store.settings.workingQuietDelay) {
                    Text("2 s").tag(2.0)
                    Text("3 s").tag(3.0)
                    Text("5 s").tag(5.0)
                    Text("10 s").tag(10.0)
                }
                Text("A tab's mark moves while its command works: printing output, using CPU, or moving data over the network or disk. A program that is only open — an editor, a pager, a quiet `tail -f` — gets no mark (or a faint dot), and a shell at its prompt shows the connection's state. Coding agents get their own symbol, which moves while they work and turns into a raised hand when they wait for you. Switch the mark off for every host in Settings ▸ Monitoring, or per host.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Find in Terminal") {
                Toggle("Highlight the line of the current match", isOn: $store.settings.findHighlight.highlightLine)
                if store.settings.findHighlight.highlightLine {
                    Picker("Line color", selection: $store.settings.findHighlight.lineColor) {
                        ForEach(FindHighlightColor.allCases) { Text($0.title).tag($0) }
                    }
                }
                Picker("Match color", selection: $store.settings.findHighlight.matchColor) {
                    ForEach(FindHighlightColor.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Tint the other matches", isOn: $store.settings.findHighlight.showOtherMatches)
                Toggle("Mark matches beside the scroller", isOn: $store.settings.findHighlight.showScrollerMarks)
                Picker("Search after typing pauses for", selection: $store.settings.findHighlight.searchDelay) {
                    ForEach([0, 150, 300, 500, 800, 1200], id: \.self) { Text($0 == 0 ? "No delay" : "\($0) ms").tag($0) }
                }
                Picker("When a match is reached", selection: $store.settings.findHighlight.jumpEffect) {
                    ForEach(FindJumpEffect.allCases) { Text($0.title).tag($0) }
                }
                Text("⌘F finds in the terminal, ↩ / ⌘G goes to the next match, ⇧↩ / ⇧⌘G to the previous one. The bar shows which match you are on and how many there are; the marks beside the scroller show where they are in the whole history. With Reduce Motion on, matches do not bounce or blink.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Floating Bars") {
                Picker("Close the find bar when unused for", selection: $store.settings.floatingBars.findBarHideAfter) {
                    ForEach([0, 5, 10, 20, 30, 60, 120], id: \.self) { Text($0 == 0 ? "Never" : "\($0) seconds").tag($0) }
                }
                Stepper("Show a finished upload for \(store.settings.floatingBars.uploadDoneHideAfter) s",
                        value: $store.settings.floatingBars.uploadDoneHideAfter, in: 1...30)
                Stepper("Show a failed upload for \(store.settings.floatingBars.uploadFailedHideAfter) s",
                        value: $store.settings.floatingBars.uploadFailedHideAfter, in: 2...60)
                Text("The find bar stays while you type, step through matches or keep the pointer over it; when it closes, the highlights go too.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Text("Off: ⌥ types the characters of your keyboard layout (⌥Q → @ on Turkish keyboards, [ ] { } | \\ ~ on many others), like Terminal.app. On: ⌥ sends Meta for Alt shortcuts in emacs, readline (⌥B / ⌥F) and many TUI apps — those characters can then not be typed with ⌥.")
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
                Stepper("History kept on the server: \(store.settings.serverHistoryLines.formatted()) lines",
                        value: $store.settings.serverHistoryLines, in: 10_000...1_000_000, step: 10_000)
                Text("For new tmux and screen sessions Tether starts (only those). Output printed while you are not connected stays on the server up to this limit, and Tether adds what you missed to the terminal and its recording when it reconnects.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Picker("Compress long sessions while they run", selection: $store.settings.recordingPartMB) {
                    Text("Never").tag(0)
                    ForEach([8, 16, 32, 64], id: \.self) { mb in Text("Every \(Int64(mb * 1024 * 1024).byteString)").tag(mb) }
                }
                .help("A session's earlier output is compressed in pieces of this size while it runs; the latest output stays as it is, so scrolling back stays fast")
                Toggle("When space runs out, shorten the largest session first", isOn: $store.settings.recordingShortenLargestFirst)
                    .help("A session holding more than half of the storage limit loses its oldest output before any other recording is removed (sessions compressed while they run, in pieces; not with Never above)")
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
                        Task {
                            recordings = await RecordingStore.perform {
                                RecordingStore.deleteAll()
                                return RecordingStore.all()
                            }
                        }
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
    @State private var confirmClear = false
    @State private var showRemoteCommands = false
    var body: some View {
        @Bindable var store = model.settingsStore
        Form {
            Section {
                FeatureToggle(feature: .monitoring, settings: $store.settings)
            } header: {
                Text("Hosts")
            } footer: {
                Text("Off: Tether runs nothing on hosts to watch them — no status bar, no panels that read the system, no command tracking. Browsing files and your port forwards still work. Each host can be set on its own in its editor, from the sidebar menu or the host panel's menu; that choice comes first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Host Panel Tabs") {
                ForEach(HostFeature.panels) { FeatureToggle(feature: $0, settings: $store.settings) }
                Toggle("Hide tabs for tools a host does not have", isOn: $store.settings.hideAbsentToolPanels)
                    .help("Containers without Docker or Podman, Kubernetes without kubectl, k3s, microk8s or oc. A host can still show them when it turns the tab on itself.")
            }
            .disabled(!store.settings.monitorAutoLoad)
            Section("In the Background") {
                ForEach([HostFeature.serverSessions, .keyLoginCheck, .processTraffic, .agentStatus, .tabActivity]) {
                    FeatureToggle(feature: $0, settings: $store.settings)
                }
            }
            .disabled(!store.settings.monitorAutoLoad)
            Section("Status Bar") {
                Toggle("Show host status above each terminal", isOn: $store.settings.showStatusStrip)
                Text("CPU, memory, disk, load, GPU and latency, streamed over the existing connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Running Commands") {
                Toggle("Show the running command below each terminal", isOn: $store.settings.showCommandStats)
                Text("Name, running time, PID, CPU, memory and network of what runs in the terminal (⌥⌘U for details).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Notice commands the moment they start", isOn: $store.settings.commandWatchEnabled)
                    .help("One small watcher per host for all its terminals: it only reads the shells' state, writes nothing and ends by itself when Tether stops reading")
                Picker("Check every", selection: $store.settings.commandWatchInterval) {
                    Text("0.5 s").tag(0.5)
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                }
                .disabled(!store.settings.commandWatchEnabled)
                .padding(.leading, 18)
                Picker("Measure running commands every", selection: $store.settings.commandLookInterval) {
                    Text("2 s").tag(2.0)
                    Text("3 s").tag(3.0)
                    Text("5 s").tag(5.0)
                    Text("10 s").tag(10.0)
                }
                Picker("Sample traffic by process every", selection: $store.settings.trafficInterval) {
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                    Text("5 s").tag(5.0)
                }
                Text("All terminals of a host share one watcher and one measurement. Commands shorter than the check interval are not seen; commands that end before they are measured are kept with their command line and duration only.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Keep a history of commands", isOn: $store.settings.keepCommandHistory)
                Toggle("With the processes each command ran", isOn: $store.settings.keepCommandProcesses)
                    .disabled(!store.settings.keepCommandHistory)
                    .padding(.leading, 18)
                Toggle("With the connections each command had", isOn: $store.settings.keepCommandConnections)
                    .disabled(!store.settings.keepCommandHistory)
                    .padding(.leading, 18)
                    .help("Remote addresses and bytes moved, up to \(CommandRecord.maxDetails) per command")
                Picker("Keep for", selection: $store.settings.commandHistoryDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                    Text("Until 500 per host").tag(0)
                }
                .disabled(!store.settings.keepCommandHistory)
                Picker("Disk space", selection: $store.settings.commandHistoryMaxMB) {
                    Text("10 MB").tag(10)
                    Text("50 MB").tag(50)
                    Text("200 MB").tag(200)
                    Text("1 GB").tag(1024)
                }
                .disabled(!store.settings.keepCommandHistory)
                LabeledContent("In use") {
                    Text("\(Int64(model.commandHistory.storageBytes).byteString) · \(model.commandHistory.records.count) commands")
                }
                .help("Compressed on disk; the oldest commands go first when the limit is reached")
                HStack {
                    Text("Duration and lowest, average and peak use of each command, kept on this Mac only (encrypted when recordings are). Secrets in command lines are masked.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Export…") {
                        let all = model.commandHistory.records()
                        ExportPanel.save(title: "Export Command History", baseName: "tether-command-history",
                                         formats: MonitorExport.Format.allCases) { MonitorExport.history(all, format: $0) }
                    }
                    Button("Clear History…", role: .destructive) { confirmClear = true }
                }
            }
            Section("Host Panel") {
                Stepper("Refresh every \(Int(store.settings.monitorRefreshInterval)) s",
                        value: $store.settings.monitorRefreshInterval, in: 1...60)
                Toggle("Confirm before sending signals to processes", isOn: $store.settings.confirmKill)
                Stepper("Log lines: \(store.settings.logLines)", value: $store.settings.logLines, in: 50...5_000, step: 50)
            }
            Section {
                Text("Monitoring runs small read-only shell commands over the existing SSH connection (/proc, ps, df, journalctl). Nothing is installed on the server.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("What Runs on Hosts…") { showRemoteCommands = true }
                    .help("Every script the host panel and the running-command features run on a host, when, and what it reads or changes")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showRemoteCommands) { RemoteCommandsView() }
        .confirmationDialog("Clear the whole command history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { model.commandHistory.clear() }
        } message: {
            Text("Commands still running are kept. This cannot be undone.")
        }
    }
}

private struct SSHSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.settingsStore
        Form {
            Section("Configuration") {
                GuardedPathRow(title: "Config file", keyPath: \.sshConfigPath, placeholder: "~/.ssh/config", defaultValue: "")
                GuardedPathRow(title: "ssh program", keyPath: \.sshBinary, placeholder: "/usr/bin/ssh", defaultValue: "/usr/bin/ssh")
                GuardedPathRow(title: "scp program", keyPath: \.scpBinary, placeholder: "/usr/bin/scp", defaultValue: "/usr/bin/scp")
                Picker("Unknown host keys", selection: model.guardedSetting(\.hostKeyPolicy, reason: "accept new host keys automatically") { _, new in new == .acceptNew }) {
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
            SSHKeysSection()
        }
        .formStyle(.grouped)
    }
}

private struct PasswordSettings: View {
    @Environment(AppModel.self) private var model
    @State private var accounts: [String] = []
    @State private var replacing: String?
    @State private var locked = false

    var body: some View {
        @Bindable var store = model.settingsStore
        Form {
            Section {
                Toggle("Ask for \(SecretGate.shared.methodName) before using a saved password",
                       isOn: model.guardedSetting(\.requireAuthForSavedPasswords, reason: "stop asking before saved passwords are used") { _, new in !new })
                if store.settings.requireAuthForSavedPasswords {
                    Picker("Ask again after", selection: model.guardedSetting(\.authGraceSeconds, reason: "ask less often before saved passwords are used") { old, new in new > old }) {
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
                Toggle("Fill saved passwords automatically",
                       isOn: model.guardedSetting(\.autoFillPasswordPrompts, reason: "fill saved passwords automatically") { _, new in new })
                    .disabled(!store.settings.detectPasswordPrompts)
            } header: {
                Text("sudo, su and other prompts")
            } footer: {
                Text("When a terminal asks for a password (“[sudo] password for alice:”, “Password:” for su, “alice@host's password:”), a bar offers the saved one (⌥⌘P), or a secure field to type one and save it. Only sudo is filled automatically, and only when sudo itself is waiting; a password is never typed into a shell. A saved password that is not accepted is not sent again: you are asked for the current one, which replaces it. Saved passwords can also be replaced or removed below.")
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
                        // A wrong or outdated password is corrected here (or when it is next rejected).
                        Button("Replace…") { replacing = a }
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
        .sheet(item: Binding(get: { replacing.map(ReplaceTarget.init) }, set: { replacing = $0?.account })) { target in
            ReplacePasswordSheet(account: target.account).appLockCover()
        }
    }
}

private struct ReplaceTarget: Identifiable {
    let account: String
    var id: String { account }
}

/// Replaces a saved password (typed twice). The old one is never shown.
private struct ReplacePasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let account: String
    @State private var password = ""
    @State private var repeated = ""
    @State private var failed = false

    var body: some View {
        let d = CredentialKey.describe(account)
        VStack(alignment: .leading, spacing: 12) {
            Text("Replace Saved Password").font(.headline)
            Text("\(d.title) — \(d.detail)").font(.callout).foregroundStyle(.secondary).lineLimit(2)
            SecureField("New password", text: $password).textFieldStyle(.roundedBorder)
            SecureField("Repeat it", text: $repeated).textFieldStyle(.roundedBorder)
            if !repeated.isEmpty && password != repeated {
                Text("The passwords do not match.").font(.caption).foregroundStyle(.red)
            }
            if failed { Text("It could not be saved in the keychain.").font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Replace") {
                    if PasswordVault.setPassword(password, for: account) { dismiss() } else { failed = true }
                }
                .keyboardShortcut(.defaultAction)
                .prominentGlassButtonStyle()
                .disabled(password.isEmpty || password != repeated)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

/// A host feature's system-wide switch, with what it runs on hosts.
private struct FeatureToggle: View {
    let feature: HostFeature
    @Binding var settings: AppSettings
    var body: some View {
        Toggle(isOn: Binding(get: { settings.isEnabled(feature) }, set: { settings.setEnabled(feature, $0) })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(feature.title)
                Text(feature.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
