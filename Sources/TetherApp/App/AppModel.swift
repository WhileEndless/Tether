import AppKit
import Observation
import SwiftUI
import TetherCore
import SSHConfigKit
import SSHTransport
import SessionKit
import TerminalUI
import FileTransferKit
import MonitorKit
import RecordingKit
import KeySetupKit

/// A password or confirmation request waiting for the user.
struct PendingPrompt: Identifiable {
    let id = UUID()
    let request: AskPassRequest
    let continuation: CheckedContinuation<String?, Never>
    /// The saved password was just sent and not accepted (it probably changed on the server).
    var savedWasRejected = false
}

/// Items in the sidebar.
enum SidebarItem: Hashable {
    case host(String)          // target key
    case session(UUID)
    case files(UUID)
    case archived(UUID)
}

/// Root state shared by every window.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settingsStore = SettingsStore.shared
    let sessions: SessionManager
    let transfers: TransferManager
    let forwards: ForwardManager

    private(set) var config: SSHConfigLibrary
    private(set) var library: HostLibrary
    private(set) var configError: String?

    var prompts: [PendingPrompt] = [] {
        didSet { AskPassPanel.shared.update(prompts.first) }
    }
    /// Set while the app quits so closing windows does not end sessions.
    var isTerminating = false
    let workspaces = WorkspaceStore()
    let fileTabs = FileTabStore()
    /// Opens the search window (installed by a window that has `openWindow`).
    @ObservationIgnored var openSearch: (() -> Void)?

    @ObservationIgnored private let libraryStore = JSONStore<HostLibrary>(filename: "hosts.json")
    @ObservationIgnored private var monitors: [String: RemoteMonitor] = [:]
    /// Commands run in Tether's terminals, with their duration and usage (this Mac only).
    let commandHistory = CommandHistoryStore(directory: AppPaths.commandHistoryDirectory, codec: .recordingKey)
    /// One per host: the watcher and batched looks for all its terminals.
    @ObservationIgnored var commandHubs: [String: CommandHub] = [:]
    /// What runs in each terminal (see `AppModel+Commands`).
    var commandSamplers: [UUID: CommandSampler] = [:]
    @ObservationIgnored private var configWatcher: DispatchSourceFileSystemObject?

    var settings: AppSettings {
        get { settingsStore.settings }
        set { settingsStore.settings = newValue }
    }

    private init() {
        #if DEBUG
        DemoMode.prepareIfRequested()
        #endif
        // Another Tether already uses this data folder: show that one instead of running twice.
        if !InstanceLock.acquire() { Self.handOverToRunningCopy() }
        let store = SettingsStore.shared
        sessions = SessionManager(settings: store)
        transfers = TransferManager(options: { SSHOptions(settings: store.settings) }, policy: {
            TransferPolicy(parallel: store.settings.transferParallel, archiveMode: store.settings.transferArchiveMode,
                           archiveThreshold: store.settings.transferArchiveThreshold, compress: store.settings.transferCompress)
        })
        forwards = ForwardManager { SSHOptions(settings: store.settings) }
        config = SSHConfigLibrary(mainURL: store.settings.resolvedSSHConfigURL)
        library = libraryStore.load() ?? HostLibrary()

        sessions.prepare = { session in
            _ = TerminalRegistry.shared.view(for: session)
            session.onPasswordPrompt = { s, prompt in AppModel.shared.passwordPromptAppeared(prompt, in: s) }
            session.onAttention = { s, attention in Notifier.shared.attention(attention, in: s) }
            session.onStateChange = { s in AppModel.shared.commandStateChanged(s) }
            session.onOnline = { s in
                let model = AppModel.shared
                model.forwards.sessionConnected(to: s.descriptor.target,
                                                saved: model.metadata(for: s.descriptor.target.key).forwards ?? [])
            }
        }
        // Keep the sidebar's list of sessions on the server current: a session ended or closed here
        // is updated right away instead of lingering as "detached".
        sessions.onSessionEnded = { s in
            if s.remoteSessionGone { AppModel.shared.serverSessionChanged(s, ended: true) }
        }
        sessions.onSessionClosed = { s, killed in
            AppModel.shared.serverSessionChanged(s, ended: killed || s.persistence == .plain)
        }
        sessions.didRemove = { id in
            TerminalRegistry.shared.remove(id)
            AppModel.shared.workspaces.sessionRemoved(id)
            AppModel.shared.commandSessionRemoved(id)
        }

        AskPassBridge.shared.start { request in
            await AppModel.shared.answer(request)
        }
        RecordingStore.configure(quotaMB: store.settings.recordingQuotaMB,
                                 retentionDays: store.settings.recordingRetentionDays,
                                 compressAfterDays: store.settings.compressRecordingsAfterDays,
                                 partMB: store.settings.recordingPartMB,
                                 shortenLargestFirst: store.settings.recordingShortenLargestFirst)
        // Compress old recordings now and then once a day.
        Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in RecordingStore.requestQuotaEnforcement() }
        DispatchQueue.global(qos: .utility).async { AppPaths.removeLeftovers() }
        watchConfigFile()
        // Platforms detected earlier (Windows or Unix-like) are known before the first connection;
        // newly detected ones are remembered per host.
        PlatformCache.shared.seed(library.metadata.compactMapValues(\.platform))
        PlatformCache.shared.onDetected = { key, platform in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                if model.metadata(for: key).platform != platform {
                    model.updateMetadata(for: key) { $0.platform = platform }
                }
            }
        }
    }

    func launch() {
        watchWindowVisibility()
        // With App Lock, sessions (and their history) come back only after unlocking.
        AppLock.shared.start { [weak self] in
            guard let self else { return }
            self.sessions.restoreOpenSessions()
            // Archived recordings not masked yet (Tether quit or was locked before it was done).
            self.sessions.redactArchive()
            self.commandHistory.load()
            self.applyCommandSettings()
            // Commands of terminals that did not come back cannot be followed any more.
            self.commandHistory.stopTracking(exceptSessions: Set(self.sessions.sessions.map(\.id)))
            self.sessionsRestored = true
            self.afterRestore.forEach { $0() }
            self.afterRestore = []
        }
    }

    @ObservationIgnored private var sessionsRestored = false
    @ObservationIgnored private var afterRestore: [() -> Void] = []

    @ObservationIgnored private var orphansAdopted = false

    /// After launch: restored sessions that are not in a restored window and were not running in
    /// the background (e.g. after a crash) are opened as tabs of the first window.
    func adoptOrphanSessions(into state: WindowState) {
        guard !orphansAdopted else { return }
        // Locked at launch: tidy the restored tabs only once the sessions are back.
        guard sessionsRestored else {
            afterRestore.append { [weak self, weak state] in if let state { self?.adoptOrphanSessions(into: state) } }
            return
        }
        orphansAdopted = true
        // Give the other windows of the last run time to reopen first (they keep their own tabs).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            WindowLayout.finishReopening()
            self.workspaces.removeMissing(existing: Set(self.sessions.sessions.map(\.id)).union(self.fileTabs.tabs.keys))
            // Tabs of windows that did not come back reopen here, in their old order.
            for id in self.workspaces.pruneWithoutWindows() {
                self.workspaces.add(id, to: state.workspaceID, select: false)
            }
            for s in self.sessions.sessions where self.workspaces.workspace(containing: s.id) == nil && !s.phase.isSuspended {
                if self.sessions.background.contains(s.id) { continue }
                self.workspaces.add(s.id, to: state.workspaceID, select: false)
            }
            self.workspaces.closeRedundantEmptyWindows(keeping: state.workspaceID)
        }
    }

    // MARK: Hosts

    var hosts: [SSHHostEntry] { config.hosts }

    var aliases: Set<String> { Set(config.aliases) }

    func metadata(for key: String) -> HostMetadata {
        library.metadata[key] ?? HostMetadata()
    }

    func updateMetadata(for key: String, _ change: (inout HostMetadata) -> Void) {
        var m = metadata(for: key)
        change(&m)
        library.metadata[key] = m
        libraryStore.saveSoon(library)
    }

    /// Hosts of a group (nil = ungrouped) in the user's sidebar order.
    func hosts(in group: UUID?) -> [SSHHostEntry] {
        let list = hosts.filter { h in
            guard let a = h.alias else { return false }
            let g = metadata(for: a).groupID
            if let group { return g == group }
            return g == nil || !library.groups.contains { $0.id == g }
        }
        return ordered(list)
    }

    func ordered(_ list: [SSHHostEntry]) -> [SSHHostEntry] {
        let rank = Dictionary(library.hostOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return list.enumerated().sorted { a, b in
            let ra = a.element.alias.flatMap { rank[$0] }, rb = b.element.alias.flatMap { rank[$0] }
            switch (ra, rb) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// Reorders hosts inside one sidebar section (List.onMove).
    func moveHosts(in group: UUID?, from source: IndexSet, to destination: Int) {
        var aliases = hosts(in: group).compactMap(\.alias)
        aliases.move(fromOffsets: source, toOffset: destination)
        // Rebuild the global order: this section's new order replaces its old positions.
        let others = ordered(hosts).compactMap(\.alias).filter { !aliases.contains($0) }
        library.hostOrder = aliases + others
        libraryStore.saveSoon(library)
    }

    /// Moves a host into a group (dropped on the group header), placing it last.
    func moveHost(_ alias: String, toGroup group: UUID?) {
        updateMetadata(for: alias) { $0.groupID = group }
        library.hostOrder.removeAll { $0 == alias }
        library.hostOrder.append(alias)
        libraryStore.saveSoon(library)
    }

    func moveGroup(_ id: UUID, by offset: Int) {
        guard let i = library.groups.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(i + offset, 0), library.groups.count - 1)
        guard i != j else { return }
        library.groups.swapAt(i, j)
        libraryStore.saveSoon(library)
    }

    var groups: [HostGroup] { library.groups }

    func addGroup(named name: String) {
        library.groups.append(HostGroup(name: name))
        libraryStore.saveSoon(library)
    }

    func updateGroup(_ id: UUID, _ change: (inout HostGroup) -> Void) {
        guard let i = library.groups.firstIndex(where: { $0.id == id }) else { return }
        change(&library.groups[i])
        libraryStore.saveSoon(library)
    }

    func deleteGroup(_ id: UUID) {
        library.groups.removeAll { $0.id == id }
        for (k, var m) in library.metadata where m.groupID == id {
            m.groupID = nil
            library.metadata[k] = m
        }
        libraryStore.saveSoon(library)
    }

    func reloadConfig() {
        config = SSHConfigLibrary(mainURL: settings.resolvedSSHConfigURL)
        watchConfigFile()
    }

    var configBackupDirectory: URL {
        AppPaths.ensure(AppPaths.supportDirectory.appendingPathComponent("ConfigBackups", isDirectory: true))
    }

    /// Applies a change to the ssh config and reloads it.
    func editConfig(alias: String?, _ change: (inout SSHConfigDocument) throws -> Void) throws {
        try config.edit(alias: alias, backupDirectory: configBackupDirectory, change)
        config.reload()
    }

    func removeHost(_ alias: String) throws {
        try editConfig(alias: alias) { try $0.removeHost(alias) }
        library.metadata[alias] = nil
        libraryStore.saveSoon(library)
        PasswordVault.deletePassword(for: alias)
    }

    private func watchConfigFile() {
        configWatcher?.cancel()
        let url = settings.resolvedSSHConfigURL
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.config.reload()
            // Atomic saves replace the file; re-arm the watcher on the new inode.
            if source.data.contains(.rename) || source.data.contains(.delete) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.watchConfigFile() }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configWatcher = source
    }

    // MARK: Sessions

    func target(forKey key: String) -> ConnectionTarget {
        if key == "local" { return .local }
        if aliases.contains(key) { return .alias(key) }
        if let s = sessions.sessions.first(where: { $0.descriptor.target.key == key }) { return s.descriptor.target }
        return ConnectionTarget.parse(key, knownAliases: aliases) ?? .alias(key)
    }

    // MARK: Monitoring

    /// Whether any Tether window can be seen. When none can (covered, minimized, on another Space,
    /// or closed to the menu bar), host monitoring pauses so Tether uses no CPU in the background.
    @ObservationIgnored private var visibilityObserver: Any?

    func watchWindowVisibility() {
        guard visibilityObserver == nil else { return }
        let refresh: @Sendable () -> Void = {
            MainActor.assumeIsolated {
                let visible = NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) && !($0 is NSPanel) }
                for m in AppModel.shared.monitors.values where m.paused == visible { m.paused = !visible }
            }
        }
        let center = NotificationCenter.default
        visibilityObserver = center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil,
                                                queue: .main) { _ in refresh() }
        // Back in Tether: the tabs on screen have been seen.
        _ = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                for s in AppModel.shared.sessions.sessions where s.isOnScreen && s.attention != nil { Notifier.shared.seen(s) }
            }
        }
        _ = center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { refresh() }
        }
    }

    /// A session to `target` closed or ended: update the server session list now and confirm shortly.
    func serverSessionChanged(_ session: TerminalSession, ended: Bool) {
        let target = session.descriptor.target
        guard !target.isLocal, let m = monitors[target.key] else { return }
        if ended { m.forgetRemoteSession(named: session.descriptor.remoteSessionName) }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            await m.refreshRemoteSessions()
        }
    }

    /// The sidebar's refresh button: reads the ssh config again and asks every server with an online
    /// session for its tmux/screen sessions and what runs in them. Hosts that are only listed are
    /// never contacted (that could ask for passwords or wait on unreachable hosts).
    func refreshSidebar() async {
        reloadConfig()
        var targets: [String: ConnectionTarget] = [:]
        for s in sessions.sessions where s.phase.isOnline { targets[s.descriptor.target.key] = s.descriptor.target }
        let wanted = targets.values.map { monitor(for: $0) }
        await withTaskGroup(of: Void.self) { group in
            for m in wanted { group.addTask { @MainActor in await m.refreshRemoteSessions() } }
        }
    }

    func monitor(for target: ConnectionTarget) -> RemoteMonitor {
        if let m = monitors[target.key] { return m }
        let m = RemoteMonitor(executor: executor(for: target))
        m.paused = !NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) && !($0 is NSPanel) }
            && !NSApp.windows.isEmpty
        monitors[target.key] = m
        m.onRemoteSessions = { [weak self] entries in self?.nameTabsAfterAgents(target: target, entries) }
        return m
    }

    /// Tabs on tmux whose active pane runs a coding agent take its session name (unless renamed by
    /// hand, or turned off in Settings ▸ General); they go back to the usual title when it ends.
    func nameTabsAfterAgents(target: ConnectionTarget, _ entries: [RemoteSessionEntry]) {
        for s in sessions.sessions(for: target.key) where s.persistence == .tmux {
            let pane = entries.first { $0.kind == .tmux && $0.name == s.descriptor.remoteSessionName }?.activePane
            let title = settings.tabTitleFromAgent ? pane?.agent?.label(fallbackTitle: pane?.title ?? "") : nil
            if s.agentTitle != title { s.agentTitle = title }
        }
    }

    @ObservationIgnored private var keyChecks: Set<String> = []

    /// Once per launch and host: checks whether the host accepts key login without a password, so
    /// the key setup offer is only shown where it is useful.
    func checkKeyLogin(_ target: ConnectionTarget) {
        guard case .alias(let alias) = target, !keyChecks.contains(alias) else { return }
        keyChecks.insert(alias)
        // A key with a passphrase cannot be tried without asking for it (BatchMode never asks): a
        // host set up with one is a key host already, and the check would only say it is not.
        guard !usesKeyWithPassphrase(alias) else { return }
        var options = SSHOptions(settings: settings)
        options.useControlMaster = false
        let args = options.commonOptions(multiplex: false)
            + ["-o", "BatchMode=yes", "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
               "-o", "ConnectTimeout=10"] + SSHOptions.destinationArguments(for: target) + ["exit"]
        Task {
            let r = await ProcessRunner.run(options.sshBinary, arguments: args, timeout: 20)
            updateMetadata(for: alias) { $0.keyLoginWorks = r.status == 0 }
        }
    }

    /// The host's config names a key file that is protected with a passphrase.
    func usesKeyWithPassphrase(_ alias: String) -> Bool {
        guard let entry = hosts.first(where: { $0.alias == alias }) else { return false }
        return entry.identityFiles.contains { path in
            KeySetup.isEncrypted(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) == true
        }
    }

    /// Whether to offer setting up a key for a host: not when key login works, nor when it already
    /// uses a key with a passphrase (whose login cannot be checked without asking for it).
    func offersKeySetup(_ alias: String) -> Bool {
        metadata(for: alias).keyLoginWorks != true && !usesKeyWithPassphrase(alias)
    }

    /// Best latency measurement available for a host: from an online tmux session, if any.
    func latency(for target: ConnectionTarget) -> LatencyStats? {
        sessions.sessions(for: target.key)
            .filter { $0.phase.isOnline && !$0.latency.samples.isEmpty }
            .map(\.latency)
            .min { ($0.median ?? 9) < ($1.median ?? 9) }
    }

    /// Searches running inside terminals (from the search window), per session.
    var terminalFind: [UUID: TerminalFind] = [:]
    /// Bumped by Find Next / Previous so the terminal's find bar steps (UUID makes each press distinct).
    var terminalFindStep: [UUID: FindStep] = [:]
    struct FindStep: Equatable { let id = UUID(); let forward: Bool }

    /// Uploads started by dropping files on a terminal, per session.
    var uploadBatches: [UUID: UploadBatch] = [:]

    /// Pre-set filters for the search window (from "Search on This Host…" etc.).
    var searchPreset: SearchPreset?

    /// Forwards a server port to this Mac (same port if free, else the next free one), saves it for
    /// the host and starts it. Returns the local port.
    @discardableResult
    func quickForward(_ target: ConnectionTarget, port: Int, address: String) -> Int {
        let local = LocalPorts.isFree(port) ? port : (LocalPorts.nextFree(from: port + 1) ?? port)
        let loopbackOrAny = ["", "*", "0.0.0.0", "::", "[::]", "::1", "[::1]"].contains(address) || address.hasPrefix("127.")
        let f = PortForward(kind: .local, listenPort: local, destinationHost: loopbackOrAny ? "localhost" : address,
                            destinationPort: port)
        updateMetadata(for: target.key) { m in
            if !(m.forwards ?? []).contains(where: { $0.kind == .local && $0.destinationPort == port }) {
                m.forwards = (m.forwards ?? []) + [f]
            }
        }
        Task { await forwards.start(f, on: target) }
        return local
    }

    /// Path the file browser of a host should navigate to (set by "Browse Files Here").
    var fileBrowserRequests: [String: String] = [:]

    func executor(for target: ConnectionTarget) -> RemoteExecutor {
        RemoteExecutor(target: target, options: SSHOptions(settings: settings))
    }

    // MARK: Askpass

    /// Passwords typed for direct connections without saving them (kept in memory only).
    @ObservationIgnored var transientPasswords: [String: String] = [:]

    /// Which saved host a password prompt is for (the name a typed password is saved under, and
    /// shown in the prompt). With jump hosts, ssh asks for each hop, so the prompt — not the tab —
    /// decides; only the host name ssh itself writes is used (see `AskPassRequest.sshNamedHost`).
    func passwordKey(for request: AskPassRequest) -> String {
        if request.isPassphrasePrompt { return CredentialKey.passphrase(keyPath: request.keyPath ?? request.prompt) }
        guard let login = request.sshNamedLogin else { return request.targetKey }
        return key(forHostName: login.host, user: login.user, target: request.targetKey)
    }

    /// The saved-host name for a host name or alias seen in a prompt. With several saved hosts for
    /// the same server (different users), only the one for this user matches; otherwise the plain
    /// `user@host`, which has no saved password unless one was saved for exactly that.
    private func key(forHostName host: String, user: String? = nil, target: String) -> String {
        func userMatches(_ alias: String) -> Bool {
            guard let user, let configured = config.entry(for: alias)?.user else { return true }
            return configured == user
        }
        if host == target || aliases.contains(host) { return userMatches(host) ? host : "\(user ?? "")@\(host)" }
        if case .alias(let a) = self.target(forKey: target), config.entry(for: a)?.hostName == host, userMatches(a) { return a }
        let candidates = hosts.filter { $0.hostName == host }.compactMap(\.alias).filter(userMatches)
        if candidates.count == 1 { return candidates[0] }
        return user.map { "\($0)@\(host)" } ?? host
    }

    /// Every name the connection to `targetKey` goes through: the target and its jump hosts (as
    /// aliases and host names). `hasJumps` tells whether anything other than the target is involved.
    func connectionPath(of targetKey: String) -> (names: Set<String>, hasJumps: Bool) {
        var names: Set<String> = [targetKey]
        var jumps: [String] = []
        switch target(forKey: targetKey) {
        case .alias(let a):
            if let e = config.entry(for: a) {
                if let h = e.hostName { names.insert(h) }
                if let j = e.proxyJump { jumps += j.split(separator: ",").map(String.init) }
            }
        case .adhoc(_, let host, _, let jump, _):
            names.insert(host)
            if let jump { jumps += jump.split(separator: ",").map(String.init) }
        case .local:
            break
        }
        var seen = 0
        while let raw = jumps.first, seen < 8 {
            jumps.removeFirst(); seen += 1
            // user@host:port → host
            var name = raw.trimmingCharacters(in: .whitespaces)
            if let at = name.lastIndex(of: "@") { name = String(name[name.index(after: at)...]) }
            if name.hasPrefix("["), let close = name.firstIndex(of: "]") { name = String(name[name.index(after: name.startIndex)..<close]) }
            else if let colon = name.firstIndex(of: ":") { name = String(name[..<colon]) }
            guard !name.isEmpty else { continue }
            names.insert(name)
            if let e = config.entry(for: name) {
                if let h = e.hostName { names.insert(h) }
                if let j = e.proxyJump { jumps += j.split(separator: ",").map(String.init) }
            }
        }
        return (names, seen > 0)
    }

    /// Whether a "host key changed" report can be acted on: it names a host on this connection's own
    /// path and a known_hosts file in ~/.ssh. (Text printed by a server before the session starts
    /// could imitate ssh's warning to get another host's trusted key removed.)
    func canRemoveHostKey(_ change: HostKeyChange, for target: ConnectionTarget) -> Bool {
        var host = change.host
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") { host = String(host[host.index(after: host.startIndex)..<close]) }
        guard connectionPath(of: target.key).names.contains(host), let file = change.knownHostsFile else { return false }
        let path = URL(fileURLWithPath: (file as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
        let ssh = AppPaths.userSSHDirectory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return path.hasPrefix(ssh)
    }

    /// The saved password that may answer this prompt without asking, or nil. Only for a host on this
    /// connection's own path, so neither a server's prompt text nor a jump host can obtain the
    /// password of another host. A prompt that names no host is answered only when there is no
    /// jump host that could have sent it.
    func savedPasswordKey(for request: AskPassRequest) -> String? {
        if request.isPassphrasePrompt { return passwordKey(for: request) }   // local key file
        let path = connectionPath(of: request.targetKey)
        guard let login = request.sshNamedLogin else { return path.hasJumps ? nil : request.targetKey }
        let key = key(forHostName: login.host, user: login.user, target: request.targetKey)
        return path.names.contains(login.host) || path.names.contains(key) ? key : nil
    }

    nonisolated func answer(_ request: AskPassRequest) async -> String? {
        if request.isPasswordPrompt || request.isPassphrasePrompt {
            let (key, transient, tried) = await MainActor.run {
                let key = self.savedPasswordKey(for: request)
                return (key, key.flatMap { self.transientPasswords[$0] }, key.map { self.triedPasswords.contains(request.token + $0) } ?? true)
            }
            // Offer a saved password once per hop; a second prompt for the same hop means it was wrong.
            // Touch ID (if enabled) comes before the password is even read from the keychain.
            if let key, !tried, transient != nil || PasswordVault.hasPassword(for: key) {
                let allowed = transient != nil ? true : await SecretGate.shared.authorize(Self.reason(for: request, key: key))
                if allowed, let saved = transient ?? PasswordVault.password(for: key) {
                    await MainActor.run { _ = self.triedPasswords.insert(request.token + key) }
                    return saved
                }
            }
        }
        // Asked again after the saved password was sent: it was not accepted.
        let rejected = await MainActor.run {
            guard let key = self.savedPasswordKey(for: request) else { return false }
            return self.triedPasswords.contains(request.token + key) && PasswordVault.hasPassword(for: key)
        }
        return await withCheckedContinuation { cont in
            Task { @MainActor in
                self.prompts.append(PendingPrompt(request: request, continuation: cont, savedWasRejected: rejected))
            }
        }
    }

    nonisolated static func reason(for request: AskPassRequest, key: String) -> String {
        if request.isPassphrasePrompt { return "unlock your SSH key \((request.keyPath.map { ($0 as NSString).lastPathComponent }) ?? "")" }
        return "sign in to \(key)"
    }

    @ObservationIgnored private var triedPasswords: Set<String> = []
    /// When a saved password was last typed into each session (automatically or with a click): the
    /// same prompt coming back right after means it was not accepted.
    @ObservationIgnored var lastFilled: [UUID: Date] = [:]
    /// The keychain item each session's current prompt belongs to, worked out when it appeared.
    var resolvedCredentials: [UUID: (prompt: PasswordPrompt, key: String)] = [:]
    /// Last automatic fill per session (to stop after a wrong password).
    @ObservationIgnored var autoFilled: [UUID: (key: String, date: Date)] = [:]

    func resolvePrompt(_ prompt: PendingPrompt, answer: String?, save: Bool) {
        prompts.removeAll { $0.id == prompt.id }
        if save, let answer, prompt.request.isPasswordPrompt || prompt.request.isPassphrasePrompt {
            PasswordVault.setPassword(answer, for: passwordKey(for: prompt.request))
        }
        prompt.continuation.resume(returning: answer)
    }

    // MARK: One copy

    /// Brings the Tether that holds the data folder to the front and quits this one, before it
    /// touched anything.
    private static func handOverToRunningCopy() -> Never {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        others.first?.activate()
        FileHandle.standardError.write(Data("Tether is already running with this data folder; showing it instead.\n".utf8))
        exit(0)
    }

    // MARK: Settings side effects

    func settingsChanged() {
        TerminalRegistry.shared.applySettings(settings)
        RecordingStore.configure(quotaMB: settings.recordingQuotaMB, retentionDays: settings.recordingRetentionDays,
                                 compressAfterDays: settings.compressRecordingsAfterDays,
                                 partMB: settings.recordingPartMB, shortenLargestFirst: settings.recordingShortenLargestFirst)
        if config.mainURL != settings.resolvedSSHConfigURL { reloadConfig() }
        applyCommandSettings()
        for (key, m) in monitors { nameTabsAfterAgents(target: target(forKey: key), m.remoteSessions) }
    }
}

struct HostEditorRequest: Identifiable {
    let id = UUID()
    /// nil = new host.
    var alias: String?
    /// Prefill for a new host (e.g. from quick connect).
    var prefill: ConnectionTarget?
}

struct KeySetupRequest: Identifiable {
    let id = UUID()
    var alias: String
}
