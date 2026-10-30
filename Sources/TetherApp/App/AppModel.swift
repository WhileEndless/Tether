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
    let created = Date()
    let continuation: CheckedContinuation<String?, Never>
    /// The saved password was just sent and not accepted (it probably changed on the server).
    var savedWasRejected = false
    /// The same host-key question from other ssh processes of this host, answered together.
    var followers: [CheckedContinuation<String?, Never>] = []

    /// What makes two host-key questions the same: the connection and ssh's own text, which
    /// names the host and the key's fingerprint.
    var confirmationKey: String? { request.isConfirmation ? request.targetKey + "\n" + request.prompt : nil }
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
        didSet { refreshPromptPanel() }
    }
    @ObservationIgnored private var promptExpiryTimer: Timer?

    /// The prompt to show now: one that belongs to no tab (a file transfer, a host-key question, a
    /// key passphrase for something the user started), or to a tab in front in a window — or to the
    /// host such a tab connects to (answering it signs that tab in too). Prompts of tabs in the
    /// background wait, marked on their tabs, until the user shows them.
    var promptInFront: PendingPrompt? {
        let front = workspaces.frontSessions
        let frontIDs = Set(front.map(\.id)), frontHosts = Set(front.map(\.descriptor.target.key))
        return prompts.first { isInFront($0, frontIDs: frontIDs, frontHosts: frontHosts) }
    }

    /// A prompt that may be shown now (see `promptInFront`). A sign-in belongs to its host, not to
    /// the tab that started it: when that tab was closed, the host's other tabs still wait for it,
    /// so it is shown while one of them is in front.
    private func isInFront(_ p: PendingPrompt, frontIDs: Set<UUID>, frontHosts: Set<String>) -> Bool {
        guard let id = p.request.sessionID, !p.request.isConfirmation else { return true }
        if frontIDs.contains(id) || frontHosts.contains(p.request.targetKey) { return true }
        // Everyone waiting for this sign-in counts: another tab of the host, a tab of a host behind
        // this jump host, a file window or a transfer (those are always in view).
        if let waiting = SignInInterest.waiting(for: p.request.token) {
            if waiting.unowned || !waiting.sessions.isDisjoint(with: frontIDs) { return true }
            let hosts = Set(waiting.sessions.compactMap { sessions.session($0)?.descriptor.target.key })
            if !hosts.isDisjoint(with: frontHosts) { return true }
        }
        return false
    }

    /// Whether a password typed for this prompt may be remembered for the host's other logins:
    /// only ssh's own password question or a local key's passphrase, never a one-time code — and
    /// only from an ssh that marks a server's questions (see `isUnverifiedPasswordPrompt`).
    private func isRememberable(_ request: AskPassRequest) -> Bool {
        (request.isPlainPasswordPrompt && request.askerNamesItsQuestions) || request.isPassphrasePrompt
    }

    /// A tab whose login waits for the user (a held-back prompt, or one that gave up waiting).
    func waitsForSignIn(_ session: TerminalSession) -> Bool {
        session.waitsForUser || prompts.contains { $0.request.sessionID == session.id }
    }

    /// Shows the prompt for what is in front (after prompts, the shown tab or the lock changed).
    func refreshPromptPanel() {
        AskPassPanel.shared.update(promptInFront)
        schedulePromptExpiry()
        // A tab in front that waits for a sign-in (its window came back, was un-minimized, the app
        // was unhidden) starts it now — it is in front, so its question can be shown.
        for session in workspaces.frontSessions where session.waitsForUser { session.shownToUser() }
    }

    /// A tab's login whose question waits in the background past the server's patience (sshd's
    /// LoginGraceTime is 2 minutes; ssh does not notice while it waits): the login is ended and the
    /// tab waits to be shown, so the password the user types later goes to a fresh login.
    func expireHeldPrompts() {
        let frontSessions = workspaces.frontSessions
        let front = Set(frontSessions.map(\.id)), frontHosts = Set(frontSessions.map(\.descriptor.target.key))
        for p in prompts where !isInFront(p, frontIDs: front, frontHosts: frontHosts) && Date().timeIntervalSince(p.created) > 90 {
            guard p.request.sessionID != nil else { continue }
            ConnectionLog.shared.notice("A sign-in question waited in the background too long; ended", .signIn, host: p.request.targetKey)
            // The host's tabs in the background wait, instead of each taking its turn at a login
            // nobody answers (20 tabs would mean 20 attempts at the server).
            let host = p.request.sessionID.flatMap { sessions.session($0)?.descriptor.target.key } ?? p.request.targetKey
            for other in sessions.sessions(for: host) where !front.contains(other.id) {
                other.waitForUser()
            }
            AskPassBridge.shared.terminateProcesses(of: p.request.token)
        }
    }

    private func schedulePromptExpiry() {
        guard promptExpiryTimer == nil, prompts.contains(where: { $0.request.sessionID != nil }) else { return }
        promptExpiryTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                model.expireHeldPrompts()
                if !model.prompts.contains(where: { $0.request.sessionID != nil }) {
                    model.promptExpiryTimer?.invalidate()
                    model.promptExpiryTimer = nil
                }
            }
        }
    }

    /// A tab came to the front: its held-back prompt appears, or a login that waited for it starts.
    func sessionShown(_ session: TerminalSession) {
        session.shownToUser()
        refreshPromptPanel()
    }

    /// ssh behind a prompt is gone (gave up, timed out, was stopped): the prompt goes away. A tab in
    /// the background then waits to be shown before it tries again (see `TerminalSession.waitsForUser`).
    func withdrawPrompts(token: String) {
        guard let i = prompts.firstIndex(where: { $0.request.token == token }), prompts[i].followers.isEmpty else { return }
        let prompt = prompts.remove(at: i)
        ConnectionLog.shared.info("A sign-in question went away (its ssh ended)", .signIn, host: prompt.request.targetKey)
        // A sign-in that went unanswered in the background: the host's tabs there wait to be shown
        // (one question when the user comes back, not one per tab in turn).
        if let id = prompt.request.sessionID {
            let front = Set(workspaces.frontSessions.map(\.id))
            let host = sessions.session(id)?.descriptor.target.key ?? prompt.request.targetKey
            if !front.contains(id) || sessions.session(id) == nil {
                for other in sessions.sessions(for: host) where !front.contains(other.id) { other.waitForUser() }
            }
        }
        prompt.continuation.resume(returning: nil)
    }
    /// Set while the app quits so closing windows does not end sessions.
    var isTerminating = false
    let workspaces = WorkspaceStore()
    let fileTabs = FileTabStore()
    /// Opens the search window (installed by a window that has `openWindow`).
    @ObservationIgnored var openSearch: (() -> Void)?

    @ObservationIgnored private let libraryStore = JSONStore<HostLibrary>(filename: "hosts.json")
    @ObservationIgnored var monitors: [String: RemoteMonitor] = [:]
    @ObservationIgnored var agentWatch: Task<Void, Never>?
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
                           archiveThreshold: store.settings.transferArchiveThreshold, compression: store.settings.transferCompression)
        })
        forwards = ForwardManager { SSHOptions(settings: store.settings) }
        config = SSHConfigLibrary(mainURL: store.settings.resolvedSSHConfigURL)
        library = libraryStore.load() ?? HostLibrary()

        sessions.prepare = { session in
            _ = TerminalRegistry.shared.view(for: session)
            session.onPasswordPrompt = { s, prompt in AppModel.shared.passwordPromptAppeared(prompt, in: s) }
            session.onAttention = { s, attention in Notifier.shared.attention(attention, in: s) }
            session.onStateChange = { s in AppModel.shared.commandStateChanged(s) }
            AppModel.shared.applyAgentSettings(to: session)
            session.onOnline = { s in
                let model = AppModel.shared

                // Tabs to the same host that waited for a sign-in can use this tab's connection now.
                // (Also one whose sign-in was refused or cancelled: this one just signed in, so the
                // shared connection is there and no password is sent again.) Tabs waiting for the
                // server's next round try now too: it answers again.
                for other in model.sessions.sessions(for: s.descriptor.target.key)
                where other.id != s.id && { if case .waiting = other.phase { true } else { false } }() {
                    other.reconnectNow()
                }
                model.monitors[s.descriptor.target.key]?.serverAnswered()
                // Asked to be ended on the server while it could not be reached: now it can.
                if s.endWhenConnected {
                    DispatchQueue.main.async { model.sessions.close(s.id, killRemote: true) }
                    return
                }
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

        // A window coming back (unhidden, un-minimized, the app brought forward) can put a waiting
        // tab in front: show its question, or start its sign-in.
        for name in [NSApplication.didUnhideNotification, NSApplication.didBecomeActiveNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AppModel.shared.refreshPromptPanel() }
            }
        }
        // Before any sign-in: it learns which connection each sign-in is for. SecretGate watches
        // for the screen locking from now on (Touch ID again, "forget when locking").
        _ = passwordCache
        _ = SecretGate.shared
        AskPassBridge.shared.start { request in
            await AppModel.shared.answer(request)
        } cancel: { token in
            Task { @MainActor in AppModel.shared.withdrawPrompts(token: token) }
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
        // Network devices and limited shells found earlier, and the user's choices per host.
        PlatformCache.shared.seed(devices: Set(library.metadata.filter { $0.value.detectedDevice == true }.keys),
                                  access: library.metadata.compactMapValues(\.shellAccess))
        PlatformCache.shared.onDeviceDetected = { key in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                model.updateMetadata(for: key) { $0.detectedDevice = true }
                model.hostFeaturesChanged(model.target(forKey: key))
            }
        }
    }

    func launch() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        ConnectionLog.shared.info("Tether \(AppInfo.version) started on macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", .app,
                                  detail: AppLock.shared.mode == .off ? nil : "App Lock is on: tabs come back once unlocked")
        applyAppearance()
        watchWindowVisibility()
        // With App Lock, sessions (and their history) come back only after unlocking.
        AppLock.shared.start { [weak self] in
            guard let self else { return }
            self.sessions.restoreOpenSessions()
            // Archived recordings not masked yet (Tether quit or was locked before it was done).
            self.sessions.redactArchive()
            IdleMaintenance.shared.start()
            self.startAgentWatch()
            self.applyCommandSettings()
            let restored = Set(self.sessions.sessions.map(\.id))
            Task {
                await self.commandHistory.loadInBackground()
                // Commands of terminals that did not come back cannot be followed any more.
                self.commandHistory.stopTracking(exceptSessions: restored)
            }
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
        configChanged()
    }

    /// Hosts may point elsewhere now (HostName, Port, User, ProxyJump): which connection each one
    /// uses is worked out again, so no tab reaches the old server through a connection still open.
    func configChanged() {
        Task { await SharedConnections.shared.forgetResolutions() }
    }

    var configBackupDirectory: URL {
        AppPaths.ensure(AppPaths.supportDirectory.appendingPathComponent("ConfigBackups", isDirectory: true))
    }

    /// Applies a change to the ssh config and reloads it.
    func editConfig(alias: String?, _ change: (inout SSHConfigDocument) throws -> Void) throws {
        try config.edit(alias: alias, backupDirectory: configBackupDirectory, change)
        config.reload()
        configChanged()
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
            self.configChanged()
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
    /// Between `willSleep` and `didWake`.
    @ObservationIgnored private(set) var isAsleep = false

    func watchWindowVisibility() {
        guard visibilityObserver == nil else { return }
        let refresh: @Sendable () -> Void = {
            MainActor.assumeIsolated {
                let model = AppModel.shared
                let visible = !model.isAsleep && NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) && !($0 is NSPanel) }
                for m in model.monitors.values where m.paused == visible { m.paused = !visible }
                for h in model.commandHubs.values { h.backgrounded = !visible }
            }
        }
        // Going to sleep: nothing streams from the servers, so none of them sends data the sleeping
        // Mac cannot acknowledge (a server gives up on such a connection after some minutes, and
        // every tab would have to sign in again). The shared connections stay, silent.
        let workspace = NSWorkspace.shared.notificationCenter
        _ = workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let model = AppModel.shared
                model.isAsleep = true
                // Whatever waits to be written goes now (the Mac may not wake).
                DeferredWrites.shared.flush()
                for m in model.monitors.values { m.paused = true }
                for h in model.commandHubs.values { h.stop() }
            }
        }
        _ = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                AppModel.shared.isAsleep = false
                refresh()
                for h in AppModel.shared.commandHubs.values { h.resume() }
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
        for s in sessions.sessions where s.phase.isOnline && isEnabled(.serverSessions, for: s.descriptor.target) {
            targets[s.descriptor.target.key] = s.descriptor.target
        }
        let wanted = targets.values.map { monitor(for: $0) }
        await withTaskGroup(of: Void.self) { group in
            for m in wanted { group.addTask { @MainActor in await m.refreshRemoteSessions() } }
        }
    }

    func monitor(for target: ConnectionTarget) -> RemoteMonitor {
        if let m = monitors[target.key] { return m }
        let m = RemoteMonitor(executor: executor(for: target))
        m.allows = { [weak self] f in self?.isEnabled(f, for: target) ?? false }
        m.paused = isAsleep || (!NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) && !($0 is NSPanel) }
            && !NSApp.windows.isEmpty)
        monitors[target.key] = m
        m.onRemoteSessions = { [weak self] entries in self?.nameTabsAfterAgents(target: target, entries) }
        return m
    }

    /// Tabs on tmux whose active pane runs a coding agent take its session name (unless renamed by
    /// hand, or turned off in Settings ▸ General); they go back to the usual title when it ends.
    func nameTabsAfterAgents(target: ConnectionTarget, _ entries: [RemoteSessionEntry]) {
        let followStatus = isEnabled(.agentStatus, for: target)
        for s in sessions.sessions(for: target.key) where s.persistence == .tmux {
            let pane = entries.first { $0.kind == .tmux && $0.name == s.descriptor.remoteSessionName }?.activePane
            let title = settings.tabTitleFromAgent ? pane?.agent?.label(fallbackTitle: pane?.title ?? "") : nil
            if s.agentTitle != title { s.agentTitle = title }
            // The agent's own status file says when it waits (plan approval, a question, a permission).
            if let agent = pane?.agent {
                if followStatus {
                    s.agentReported(kind: agent.agentKind, activity: agent.activity, at: agent.statusUpdatedAt ?? Date())
                }
            } else if s.agent != nil, s.persistence == .tmux, pane != nil {
                s.agentEnded()
            }
        }
    }

    @ObservationIgnored private var keyChecks: Set<String> = []

    /// Once per launch and host: checks whether the host accepts key login without a password, so
    /// the key setup offer is only shown where it is useful.
    func checkKeyLogin(_ target: ConnectionTarget) {
        guard case .alias(let alias) = target, !keyChecks.contains(alias), isEnabled(.keyLoginCheck, for: target) else { return }
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
        // Installing a key runs a script on the host: not on a network device (its own way applies).
        metadata(for: alias).keyLoginWorks != true && !usesKeyWithPassphrase(alias) && !isDevice(.alias(alias))
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

    /// A password typed into Quick Connect without saving it: handed to that connection's first
    /// password question only, then dropped (also if no question comes within a minute). Like any
    /// typed password, it is then remembered sealed when Signing In Again is on.
    @ObservationIgnored var quickConnectPasswords: [String: (password: String, at: TimeInterval)] = [:]

    /// Quick Connect hands a typed (not saved) password to the connection it starts; gone after a
    /// minute whether or not it was asked for (or when the screen locks).
    func offerQuickConnectPassword(_ password: String, for key: String) {
        let at = ProcessInfo.processInfo.systemUptime
        quickConnectPasswords[key] = (password, at)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            if self?.quickConnectPasswords[key]?.at == at { self?.quickConnectPasswords[key] = nil }
        }
    }

    /// Only for the question ssh asks for the Quick Connect target itself (not a jump host).
    func takeQuickConnectPassword(for request: AskPassRequest) -> String? {
        guard let login = request.sshNamedLogin, isTargetItself(login.host, targetKey: request.targetKey),
              let entry = quickConnectPasswords.removeValue(forKey: request.targetKey) else { return nil }
        return ProcessInfo.processInfo.systemUptime - entry.at < 60 ? entry.password : nil
    }

    /// Whether ssh's question names the target itself rather than a jump host on its way.
    private func isTargetItself(_ host: String, targetKey: String) -> Bool {
        switch target(forKey: targetKey) {
        case .adhoc(_, let h, _, _, _): return host == h
        case .alias(let a): return host == a || config.entry(for: a)?.hostName == host
        case .local: return false
        }
    }

    /// Which saved host a password prompt is for (the name a typed password is saved under, and
    /// shown in the prompt). With jump hosts, ssh asks for each hop, so the prompt — not the tab —
    /// decides; only the host name ssh itself writes is used (see `AskPassRequest.sshNamedHost`).
    func passwordKey(for request: AskPassRequest) -> String {
        if request.isPassphrasePrompt { return CredentialKey.passphraseItem(keyPath: request.keyPath ?? request.prompt) }
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
        // A local key file. `isPassphrasePrompt` holds only for an ssh that marks a server's own
        // questions — the ssh asking, checked by its program file: with an older one (also a jump
        // host's ssh from PATH) a server could word its question as this key's prompt.
        if request.isPassphrasePrompt { return passwordKey(for: request) }
        let path = connectionPath(of: request.targetKey)
        guard let login = request.sshNamedLogin else { return path.hasJumps ? nil : request.targetKey }
        let key = key(forHostName: login.host, user: login.user, target: request.targetKey)
        return path.names.contains(login.host) || path.names.contains(key) ? key : nil
    }

    /// What marks a saved or remembered answer as given to one asker: its token — and for a key's
    /// passphrase its ssh process too. The ssh that ProxyJump starts for a jump host has the same
    /// token and opens the same key on its own; its question is not a sign of a wrong passphrase.
    nonisolated static func triedKey(_ request: AskPassRequest, _ key: String) -> String {
        request.isPassphrasePrompt ? request.token + "\u{0}\(request.askerPID)\u{0}" + key : request.token + key
    }

    nonisolated func answer(_ request: AskPassRequest) async -> String? {
        // Nothing is filled in by itself for a question an older ssh asks: a jump host behind it
        // could have worded it as the target's (the user still sees it, and Fill).
        if (request.isPasswordPrompt && request.askerNamesItsQuestions) || request.isPassphrasePrompt {
            let (key, remembered, tried, fromCache) = await MainActor.run {
                let key = self.savedPasswordKey(for: request)
                // Background work never gets a password (it refuses every prompt anyway).
                let usable = !SSHOptions.isQuietPurpose(request.purpose)
                let tried = key.map { self.triedPasswords.contains(Self.triedKey(request, $0)) } ?? true
                // The same ssh asking again: the password it got was refused. It is never sent again.
                if tried, let key { self.passwordCache.reject(token: request.token, login: key) }
                var remembered: (password: String, source: SealedPasswordCache.Source)?
                var fromCache = false
                // A key's passphrase too: typed once, it opens that key for every server it signs in to.
                if usable, !tried, request.isPlainPasswordPrompt || request.isPassphrasePrompt, let key {
                    if let quick = self.takeQuickConnectPassword(for: request) { remembered = (quick, .typed) }
                    else { remembered = self.passwordCache.password(token: request.token, login: key); fromCache = remembered != nil }
                }
                return (key, remembered, tried, fromCache)
            }
            // A saved password remembered from the keychain still needs Touch ID when that is asked
            // for (after the time chosen, after locking or sleeping), like reading it again would.
            var allowed = false
            if let key, let remembered {
                let touchID = await MainActor.run { self.settings.requireAuthForSavedPasswords }
                if remembered.source == .typed || !touchID {
                    allowed = true
                } else {
                    allowed = await SecretGate.shared.authorize(Self.reason(for: request, key: key))
                }
            }
            if allowed, let key, let remembered {
                // A key is named by its file name only (the log can be copied; no home folder in it).
                ConnectionLog.shared.info(request.isPassphrasePrompt ? "Opened the key with the remembered passphrase" : "Answered ssh's sign-in question with the remembered password",
                                          .signIn, host: request.isPassphrasePrompt ? Self.keyLabel(request) : key)
                await MainActor.run {
                    _ = self.triedPasswords.insert(Self.triedKey(request, key))
                    // One taken from the cache is not given to it again: its entry keeps the time
                    // it was typed (Forget them after …), and one forgotten meanwhile (App Lock,
                    // Forget, the screen locked) stays forgotten.
                    if !fromCache {
                        self.passwordCache.offer(remembered.password, login: key, token: request.token, source: remembered.source)
                    }
                }
                return remembered.password
            }
            // Offer a saved password once per hop; a second prompt for the same hop means it was wrong.
            // Touch ID (if enabled) comes before the password is even read from the keychain.
            // Touch ID was just declined for the remembered copy: not asked a second time.
            let declined = remembered != nil && !allowed
            if let key, !tried, !declined, PasswordVault.hasPassword(for: key) {
                if await SecretGate.shared.authorize(Self.reason(for: request, key: key)), let saved = await PasswordVault.passwordOffThread(for: key) {
                    await MainActor.run {
                        _ = self.triedPasswords.insert(Self.triedKey(request, key))
                        // Remembered for this connection's further sign-ins this run (still behind
                        // Touch ID when that is required, see above).
                        if request.isPlainPasswordPrompt || request.isPassphrasePrompt { self.passwordCache.offer(saved, login: key, token: request.token, source: .keychain) }
                    }
                    return saved
                }
            }
        }
        // Asked again after the saved password was sent: it was not accepted.
        let rejected = await MainActor.run {
            guard let key = self.savedPasswordKey(for: request) else { return false }
            return self.triedPasswords.contains(Self.triedKey(request, key)) && PasswordVault.hasPassword(for: key)
        }
        return await withCheckedContinuation { cont in
            Task { @MainActor in
                let prompt = PendingPrompt(request: request, continuation: cont, savedWasRejected: rejected)
                // Several ssh processes logging in to a new host at once (a tab, monitoring, files)
                // each ask about the same key: the question is shown once and answers them all, and
                // one asked again right after it was answered gets the same answer.
                // Its ssh ended while this was on the way (Touch ID, the lock screen): nothing to ask.
                guard AskPassBridge.shared.isLive(request.token) else { cont.resume(returning: nil); return }
                if let key = prompt.confirmationKey {
                    if let recent = self.recentConfirmations[key], Date().timeIntervalSince(recent.date) < 120 {
                        cont.resume(returning: recent.answer)
                        return
                    }
                    if let i = self.prompts.firstIndex(where: { $0.confirmationKey == key }) {
                        self.prompts[i].followers.append(cont)
                        return
                    }
                }
                self.prompts.append(prompt)
            }
        }
    }

    /// Host-key questions answered in the last minutes (see `answer`).
    @ObservationIgnored private var recentConfirmations: [String: (answer: String?, date: Date)] = [:]

    /// "key id_example" for a passphrase question (never the folder it is in).
    nonisolated static func keyLabel(_ request: AskPassRequest) -> String {
        "key " + (request.keyPath.map { ($0 as NSString).lastPathComponent } ?? "")
    }

    nonisolated static func reason(for request: AskPassRequest, key: String) -> String {
        if request.isPassphrasePrompt { return "unlock your SSH key \((request.keyPath.map { ($0 as NSString).lastPathComponent }) ?? "")" }
        return "sign in to \(key)"
    }

    @ObservationIgnored private var triedPasswords: Set<String> = []
    /// The ssh program whose version `passwordCache.sshNamesItsQuestions` was worked out for.
    @ObservationIgnored private var checkedSSHBinary: String?
    /// Counts version checks: only the newest may set the answer (a slow check for the program set
    /// before must not overwrite the one for the program set now).
    @ObservationIgnored private var sshCheckGeneration = 0

    private func startSSHCheck(_ cache: SealedPasswordCache, binary: String) {
        sshCheckGeneration += 1
        let generation = sshCheckGeneration
        Task { @MainActor [weak self] in
            let names = await SSHVersion.namesItsQuestions(binary: binary)
            guard let self, generation == self.sshCheckGeneration else { return }
            cache.sshNamesItsQuestions = names
        }
    }
    @ObservationIgnored private var lastSharing: Bool?

    /// Sign-in passwords of this run, sealed by a Secure Enclave key that exists only while Tether
    /// runs (see `SealedPasswordCache`, docs/connections-and-passwords.md). Never written anywhere.
    @ObservationIgnored lazy var passwordCache: SealedPasswordCache = {
        let cache = SealedPasswordCache(sealer: SecureEnclaveSealer())
        cache.isEnabled = settings.rememberSignInPasswords
        cache.maxAge = settings.forgetSignInPasswordsAfterHours > 0 ? Double(settings.forgetSignInPasswordsAfterHours) * 3600 : nil
        // Off until the ssh program is known to mark servers' own questions (checked off the main
        // thread; a program that does not answer `-V` keeps it off).
        checkedSSHBinary = settings.sshBinary
        startSSHCheck(cache, binary: settings.sshBinary)
        SharedConnections.onSignInStarted = { [cache] token, connection in cache.bind(token: token, connection: connection) }
        SharedConnections.onSignInResult = { [cache] token, ok, refused in
            // Failed for whatever reason (`refused` or not): see `SealedPasswordCache.discard`.
            if ok { cache.commit(token: token) } else { cache.discard(token: token) }
        }
        return cache
    }()

    /// When a saved password was last typed into each session (automatically or with a click): the
    /// same prompt coming back right after means it was not accepted.
    @ObservationIgnored var lastFilled: [UUID: Date] = [:]
    /// The keychain item each session's current prompt belongs to, worked out when it appeared.
    var resolvedCredentials: [UUID: (prompt: PasswordPrompt, key: String)] = [:]
    /// Last automatic fill per session (to stop after a wrong password).
    @ObservationIgnored var autoFilled: [UUID: (key: String, date: Date)] = [:]

    /// The host whose tabs a cancelled sign-in stands for: the asking tab's, or the one the ssh
    /// connects to.
    private func cancelledHost(_ request: AskPassRequest) -> String? {
        if let id = request.sessionID, let session = sessions.session(id) { return session.descriptor.target.key }
        return request.targetKey.isEmpty ? nil : request.targetKey
    }

    func resolvePrompt(_ prompt: PendingPrompt, answer: String?, save: Bool) {
        // Answered once only: Return in the field and the default button can both arrive, and a
        // prompt withdrawn a moment ago (its ssh ended) has already been resumed. Resuming twice
        // would end the app.
        guard let i = prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
        let current = prompts.remove(at: i)
        // Cancelled: the ssh behind it is ended first. Told "no answer", ssh would send an empty
        // password (a failed login on the server) and ask again, up to three times.
        if answer == nil, !prompt.request.isConfirmation {
            AskPassBridge.shared.terminateProcesses(of: prompt.request.token)
        }
        // Cancelled by the user: no tab to this host tries (and asks) again until the user presses
        // Reconnect or a tab signs in — in front or not, in this window or another.
        if answer == nil, !prompt.request.isConfirmation { ConnectionLog.shared.info("Sign-in question cancelled", .signIn, host: prompt.request.targetKey) }
        if answer == nil, !prompt.request.isConfirmation {
            // Every tab this sign-in stood for — of the host itself, or of hosts behind it when it
            // is a jump host's — stops asking until the user presses Reconnect.
            var stopped: [UUID: TerminalSession] = [:]
            for s in cancelledHost(prompt.request).map({ sessions.sessions(for: $0) }) ?? [] { stopped[s.id] = s }
            for id in SignInInterest.waiting(for: prompt.request.token)?.sessions ?? [] {
                if let s = sessions.session(id) { stopped[id] = s }
            }
            for other in stopped.values where !other.phase.isOnline {
                other.pauseRetries("Sign-in cancelled. Press Reconnect when you want to sign in.")
            }
        }
        // Answered after the server's login time ran out (sshd closes an unfinished login after about
        // two minutes; ssh does not notice while it waits): sending it would fail. Nothing is kept:
        // the tab signs in afresh and asks once more, saying why.
        if let answer, !answer.isEmpty, isRememberable(prompt.request), prompt.request.sessionID != nil,
           Date().timeIntervalSince(current.created) > 110 {
            if save { PasswordVault.setPassword(answer, for: passwordKey(for: prompt.request)) }
            AskPassBridge.shared.terminateProcesses(of: prompt.request.token)
            current.continuation.resume(returning: nil)
            for follower in current.followers { follower.resume(returning: nil) }
            return
        }
        if save, let answer, prompt.request.isPasswordPrompt || prompt.request.isPassphrasePrompt {
            PasswordVault.setPassword(answer, for: passwordKey(for: prompt.request))
            // The same ssh asking again means it was wrong: then the user is asked, not the keychain.
            if let key = savedPasswordKey(for: prompt.request) { triedPasswords.insert(Self.triedKey(prompt.request, key)) }
        }
        // Remembered (sealed) for this server's further sign-ins only once this one has worked.
        if let answer, !answer.isEmpty, isRememberable(prompt.request),
           !SSHOptions.isQuietPurpose(prompt.request.purpose),
           let key = savedPasswordKey(for: prompt.request) {
            passwordCache.offer(answer, login: key, token: prompt.request.token, source: .typed)
        }
        // Skipped key: an earlier answer to this question (a typo ssh asked again for) is not kept.
        if answer == "", prompt.request.isPassphrasePrompt, let key = savedPasswordKey(for: prompt.request) {
            passwordCache.withdraw(token: prompt.request.token, login: key)
        }
        if let key = prompt.confirmationKey { recentConfirmations[key] = (answer, Date()) }
        current.continuation.resume(returning: answer)
        for follower in current.followers { follower.resume(returning: answer) }
        // Other logins waiting for the same user and host at this moment (another shared connection
        // to the same server, hosts behind the same jump host) take this password too, once each,
        // instead of asking. It goes only to them: nothing keeps it afterwards.
        // Only a sign-in for the same connection (host, port, user and jump host): the same
        // user@host on another port, or behind another jump host, is another server.
        let connection = passwordCache.connection(token: prompt.request.token)
        func sameConnection(_ other: AskPassRequest) -> Bool {
            // A key's passphrase belongs to the key file on this Mac: every sign-in waiting to open
            // that key takes it, whatever server it is for (the same key, see `savedPasswordKey`).
            if prompt.request.isPassphrasePrompt { return other.isPassphrasePrompt }
            if let connection { return passwordCache.connection(token: other.token) == connection }
            return passwordCache.connection(token: other.token) == nil && other.targetKey == prompt.request.targetKey
        }
        if let answer, !answer.isEmpty, isRememberable(prompt.request), let key = savedPasswordKey(for: prompt.request) {
            for other in prompts where isRememberable(other.request) && savedPasswordKey(for: other.request) == key
                && sameConnection(other.request) && !triedPasswords.contains(Self.triedKey(other.request, key)) {
                triedPasswords.insert(Self.triedKey(other.request, key))
                prompts.removeAll { $0.id == other.id }
                if other.request.isPlainPasswordPrompt || other.request.isPassphrasePrompt {
                    passwordCache.offer(answer, login: key, token: other.request.token, source: .typed)
                }
                other.continuation.resume(returning: answer)
                // The same question asked by further ssh processes waits on this one: answered too.
                for follower in other.followers { follower.resume(returning: answer) }
            }
        }
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
        applyAppearance()
        // Sharing switched off: the shared connections close (their tabs reconnect without them).
        if lastSharing == true && !settings.useControlMaster {
            ConnectionLog.shared.notice("Connection sharing was turned off; closing the shared connections", .app)
            SharedConnections.closeAllNow(ssh: settings.sshBinary)
        }
        lastSharing = settings.useControlMaster
        RetryPace.longest = settings.reconnectMaxDelay
        if checkedSSHBinary != settings.sshBinary {
            checkedSSHBinary = settings.sshBinary
            let cache = passwordCache, binary = settings.sshBinary
            cache.sshNamesItsQuestions = false
            cache.sshChecked = false
            cache.removeAll()
            startSSHCheck(cache, binary: binary)
        }
        passwordCache.maxAge = settings.forgetSignInPasswordsAfterHours > 0 ? Double(settings.forgetSignInPasswordsAfterHours) * 3600 : nil
        if passwordCache.isEnabled != settings.rememberSignInPasswords {
            passwordCache.isEnabled = settings.rememberSignInPasswords
            if !settings.rememberSignInPasswords { passwordCache.removeAll() }
        }
        TerminalRegistry.shared.applySettings(settings)
        RecordingStore.configure(quotaMB: settings.recordingQuotaMB, retentionDays: settings.recordingRetentionDays,
                                 compressAfterDays: settings.compressRecordingsAfterDays,
                                 partMB: settings.recordingPartMB, shortenLargestFirst: settings.recordingShortenLargestFirst)
        if config.mainURL != settings.resolvedSSHConfigURL { reloadConfig() }
        applyCommandSettings()
        for s in sessions.sessions { applyAgentSettings(to: s) }
        for (key, m) in monitors {
            // Probes started from now on use the new ssh settings (binary, shared connection, …).
            let options = SSHOptions(settings: settings)
            if m.executor.options != options { m.executor = RemoteExecutor(target: m.executor.target, options: options) }
            nameTabsAfterAgents(target: target(forKey: key), m.remoteSessions)
        }
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
