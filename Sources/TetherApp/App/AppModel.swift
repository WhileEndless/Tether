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

/// A question ssh asked, waiting for the user (decided by `SignInBroker`).
typealias PendingPrompt = SignInQuestion

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

    /// The open sign-in questions (kept by `signInBroker`, shown in the panel).
    private(set) var prompts: [PendingPrompt] = [] {
        didSet { refreshPromptPanel() }
    }
    func setPrompts(_ questions: [PendingPrompt]) { prompts = questions }
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

    /// A tab whose login waits for the user (a held-back prompt, or one that gave up waiting).
    func waitsForSignIn(_ session: TerminalSession) -> Bool {
        session.waitsForUser || prompts.contains { $0.request.sessionID == session.id }
    }

    /// Shows the prompt for what is in front (after prompts, the shown tab or the lock changed).
    /// Never at once: showing the panel makes a window key, which posts the very notifications that
    /// call this again (a tab shown, a window becoming key) — done right away, each would show the
    /// panel again inside the last one until the stack ran out. Every request in one turn of the
    /// run loop is answered by one refresh after it.
    func refreshPromptPanel() {
        guard !promptRefreshPending else { return }
        promptRefreshPending = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let model = AppModel.shared
                model.promptRefreshPending = false
                model.applyPromptPanel()
            }
        }
    }
    @ObservationIgnored private var promptRefreshPending = false

    private func applyPromptPanel() {
        let front = promptInFront
        AskPassPanel.shared.update(front)
        // The questions queued behind the one shown are in front of the user too (they come next):
        // what waits for them may wait, as for the one shown (see `AskPassBridge.waitsOnUser`).
        if front != nil, !AppLock.shared.isLocked, AskPassPanel.shared.isShowing {
            let frontSessions = workspaces.frontSessions
            let ids = Set(frontSessions.map(\.id)), hosts = Set(frontSessions.map(\.descriptor.target.key))
            for p in prompts where isInFront(p, frontIDs: ids, frontHosts: hosts) {
                // Also every other ssh asking the same host-key question (answered together).
                for token in signInBroker.tokens(of: p.id) { AskPassBridge.shared.notePresented(token: token) }
            }
        }
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
            ConnectionLog.shared.notice("A sign-in question waited in the background too long; ended", .signIn, host: p.request.targetKey,
                                        detail: "the tabs it was for wait until one of them is shown, then ask once")
            // Every tab waiting for it — of the host, another name for it, hosts behind it — waits in
            // the background, instead of each taking its turn at a login nobody answers (20 tabs
            // would mean 20 attempts at the server).
            waitForUser(token: p.request.token, sessionID: p.request.sessionID, host: p.request.targetKey)
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

    /// Returns once Tether is not locked (at once when it is not).
    static func waitUntilUnlocked() async { await AppLock.shared.waitUntilUnlocked() }

    /// A tab came to the front: its held-back prompt appears, or a login that waited for it starts.
    func sessionShown(_ session: TerminalSession) {
        session.shownToUser()
        refreshPromptPanel()
    }

    /// ssh behind a prompt is gone (gave up, timed out, was stopped): the prompt goes away. A tab in
    /// the background then waits to be shown before it tries again (see `TerminalSession.waitsForUser`).
    func withdrawPrompts(token: String) {
        guard let prompt = signInBroker.withdraw(token: token) else { return }
        // A sign-in that went unanswered in the background: the host's tabs there wait to be shown
        // (one question when the user comes back, not one per tab in turn).
        if let id = prompt.request.sessionID {
            let front = Set(workspaces.frontSessions.map(\.id))
            let host = sessions.session(id)?.descriptor.target.key ?? prompt.request.targetKey
            if !front.contains(id) || sessions.session(id) == nil {
                for other in sessions.sessions(for: host) where !front.contains(other.id) { other.waitForUser() }
            }
        }
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
                // Its own sign-in too (no shared connection): the host is reachable.
                HostLinks.shared.post(.signedIn(s.descriptor.target.key))

                // Tabs to the same host that waited for a sign-in can use this tab's connection now.
                // (Also one whose sign-in was refused or cancelled: this one just signed in, so the
                // shared connection is there and no password is sent again.) Tabs waiting for the
                // server's next round try now too: it answers again.
                for other in model.sessions.sessions(for: s.descriptor.target.key)
                where other.id != s.id && { if case .waiting = other.phase { true } else { false } }() {
                    other.reconnectNow("another tab to this server connected")
                }
                model.monitors[s.descriptor.target.key]?.serverAnswered()
                model.forwards.sessionConnected(to: s.descriptor.target,
                                                saved: model.metadata(for: s.descriptor.target.key).forwards ?? [])
            }
        }
        // A tab closed while its server could not be reached still runs there: the user is told,
        // and decides (nothing is ended by itself).
        sessions.onStillRunning = { s in Notifier.shared.stillRunning(s) }
        // A transfer moving data keeps its connection from being judged dead while it is checked.
        sessions.otherActivity = { host, moment in AppModel.shared.transfers.movedData(host: host, since: moment) }
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
                     NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification, SignInInterest.changed] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                // The prompt panel itself becoming key is the answer to a refresh, not a reason for one.
                if note.object is NSPanel { return }
                MainActor.assumeIsolated { AppModel.shared.refreshPromptPanel() }
            }
        }
        // Before any sign-in: it learns which connection each sign-in is for. SecretGate watches
        // for the screen locking from now on (Touch ID again, "forget when locking").
        _ = passwordCache
        _ = SecretGate.shared
        // While Tether is locked no sign-in that may ask starts; it does once unlocked.
        SignInEvents.shared.gatekeeper = signInGatekeeper
        // A server reachable again (signed in, the network back, Tether unlocked): what waited for it
        // goes on — tabs, file views whose listing failed, port forwards to restore, monitors.
        HostLinks.shared.observe { event in AppModel.shared.hostReachable(event) }
        signInBroker.host = self
        let broker = signInBroker
        AskPassBridge.shared.start { request in
            await broker.answer(request)
        } cancel: { token in
            Task { @MainActor in AppModel.shared.withdrawPrompts(token: token) }
        }
        RecordingStore.configure(quotaMB: store.settings.recordingQuotaMB,
                                 retentionDays: store.settings.recordingRetentionDays,
                                 compressAfterDays: store.settings.compressRecordingsAfterDays,
                                 partMB: store.settings.recordingPartMB,
                                 shortenLargestFirst: store.settings.recordingShortenLargestFirst,
                                 minFreeGB: store.settings.recordingProtectFreeSpace ? store.settings.recordingMinFreeGB : 0)
        // Compress old recordings now and then once a day.
        // Once a day too: copies made for previews, drags and the clipboard older than a day go.
        Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in
            RecordingStore.requestQuotaEnforcement()
            DispatchQueue.global(qos: .utility).async { AppPaths.removeLeftovers(); PasteboardFiles.removeOldFiles() }
        }
        DispatchQueue.global(qos: .utility).async { AppPaths.removeLeftovers(); PasteboardFiles.removeOldFiles() }
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
                                  detail: Self.settingsSnapshot(settings)
                                      + (AppLock.shared.mode == .off ? "" : "\nApp Lock is on: tabs come back once unlocked"))
        lastLoggedSettings = Self.settingsSnapshot(settings)
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
            self.restoreOpenForwards()
        }
    }

    private func hostReachable(_ event: HostLinks.Event) {
        switch event {
        case .signedIn(let host):
            sessions.lookForEndedSessions(host: host)
            FileBrowserModel.reloadFailed(host: host)
            forwards.retryPending(host: host)
            for (key, monitor) in monitors where HostLinks.sameServer(key, host) { monitor.serverAnswered() }
        case .networkBack:
            // Tabs closed while their server could not be reached are looked for again (quietly:
            // a server that needs a password is not asked — it is told when you sign in to it).
            sessions.lookForEndedSessions(host: nil, atMostEvery: 60)
            FileBrowserModel.reloadFailed()
            forwards.retryPending()
            monitors.values.forEach { $0.serverAnswered() }
        case .unlocked:
            sessions.retryWaiting()
            FileBrowserModel.reloadFailed()
            forwards.retryPending()
        case .linkAlive(let host):
            sessions.lookForEndedSessions(host: host)
            // Checked and still reaching its server: what failed for it (a listing over a network
            // that came back by itself) tries again.
            FileBrowserModel.reloadFailed(host: host)
            for (key, monitor) in monitors where HostLinks.sameServer(key, host) { monitor.serverAnswered() }
        case .connectionEnded(let host):
            forwards.connectionEnded(host)
        }
    }

    /// Port forwards that were running when Tether last quit: those listening only on this Mac come
    /// back by themselves; the others (open to the network, or on the server) only when asked.
    private func restoreOpenForwards() {
        let wanted = Set(settings.openForwards)
        forwards.onWantedChanged = { ids in
            let list = ids.sorted { $0.uuidString < $1.uuidString }
            if AppModel.shared.settings.openForwards != list { AppModel.shared.settings.openForwards = list }
        }
        guard !wanted.isEmpty else { return }
        var local: [(ConnectionTarget, PortForward)] = [], open: [(ConnectionTarget, PortForward)] = []
        for (key, m) in library.metadata {
            for f in m.forwards ?? [] where wanted.contains(f.id) && !f.autoStart {
                if f.listensOnlyOnThisMac { local.append((target(forKey: key), f)) } else { open.append((target(forKey: key), f)) }
            }
        }
        for (target, f) in local { Task { await forwards.start(f, on: target, restoring: true) } }
        if !local.isEmpty {
            ConnectionLog.shared.info("Reopening \(local.count) port forward\(local.count == 1 ? "" : "s") that were running when Tether quit", .forward)
        }
        guard !open.isEmpty else { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Reopen port forwards?"
            alert.informativeText = "These were running when Tether quit. They listen beyond this Mac:\n\n"
                + open.map { "• \($0.1.summary) (\($0.0.displayName))" }.joined(separator: "\n")
            alert.addButton(withTitle: "Reopen")
            alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn {
                for (target, f) in open { Task { await AppModel.shared.forwards.start(f, on: target, restoring: true) } }
            } else {
                AppModel.shared.settings.openForwards.removeAll { id in open.contains { $0.1.id == id } }
            }
        }
    }

    /// The settings that decide sign-ins and connections, in words for the Connection Log (no host,
    /// path or secret): written at launch, and again when one of them changes.
    static func settingsSnapshot(_ s: AppSettings) -> String {
        [
            "connection sharing " + (s.useControlMaster ? "on" : "off")
                + (s.keepConnectionsAfterQuit ? ", kept after quitting" : ""),
            s.serverAliveInterval > 0 ? "keep-alive every \(s.serverAliveInterval) s" : "keep-alive off",
            "remember sign-in passwords " + (s.rememberSignInPasswords
                ? "on (forget after " + (s.forgetSignInPasswordsAfterHours > 0 ? "\(s.forgetSignInPasswordsAfterHours) h" : "quitting") + ")"
                : "off")
                + (s.forgetSignInPasswordsOnLock ? ", forgotten when the screen locks" : ""),
            "Touch ID for saved passwords " + (s.requireAuthForSavedPasswords ? "on" : "off"),
            "App Lock " + (s.appLockMode == .off ? "off" : "on" + (s.lockOnSleep ? ", locks with the screen" : "")),
            "reconnect " + (s.autoReconnect ? "automatically" : "when asked"),
        ].joined(separator: "; ")
    }
    @ObservationIgnored private var lastLoggedSettings: String?

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
        Credentials.remove(alias)
    }

    /// What quitting now would end for good (nil: nothing): plain shells online (on servers and on
    /// this Mac), transfers, port forwards.
    struct WorkEnding {
        var shells = 0, transfers = 0, forwards = 0
        var description: String {
            var parts: [String] = []
            if shells > 0 { parts.append("\(shells) tab\(shells == 1 ? "" : "s") without tmux or screen will end") }
            if transfers > 0 { parts.append("\(transfers) transfer\(transfers == 1 ? "" : "s") will stop") }
            if forwards > 0 { parts.append("\(forwards) port forward\(forwards == 1 ? "" : "s") will close") }
            return parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst()
        }
    }

    func workEndingOnQuit() -> WorkEnding? {
        var w = WorkEnding()
        w.shells = sessions.sessions.filter { $0.phase.isOnline && ($0.persistence == .plain || $0.persistence == .unknown) }.count
        w.transfers = transfers.activeCount
        // Only those that do not come back: kept open with the connections, started by themselves,
        // or reopened at the next launch (listening only on this Mac) they are not lost.
        w.forwards = settings.keepConnectionsAfterQuit ? 0
            : forwards.activeForwards.filter { !$0.autoStart && !$0.listensOnlyOnThisMac }.count
        return w.shells + w.transfers + w.forwards > 0 ? w : nil
    }

    /// The user saved, replaced or removed a saved password: a copy remembered from the old one is
    /// not used any more, and a new one may be sent again.
    func savedPasswordChanged(_ key: String) {
        signIns.clearRefusal(key)
        passwordCache.forget(login: key, reason: "its saved password was changed or removed")
    }

    private func watchConfigFile() {
        configWatcher?.cancel()
        configWatcher = nil
        let url = settings.resolvedSSHConfigURL
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            // No ssh_config yet (a first launch): looked for again, so one made later is read.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.configWatcher == nil else { return }
                if FileManager.default.fileExists(atPath: url.path) {
                    self.config.reload()
                    self.configChanged()
                    self.watchConfigFile()
                } else {
                    self.watchConfigFile()
                }
            }
            return
        }
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
                // Once the network is back and the shared connections were checked (a stream started
                // on a dead one only fails) — or after 20 s, whatever comes first.
                Task { @MainActor in
                    _ = await HostLinks.shared.whenReachable("", within: 20)
                    guard !AppModel.shared.isAsleep else { return }
                    refresh()
                    for h in AppModel.shared.commandHubs.values { h.resume() }
                }
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

    /// Once per host: checks whether the host accepts key login without a password, so the key setup
    /// offer is only shown where it is useful. The answer is kept (setting up a key updates it): each
    /// check is a login attempt the server logs, and tools such as fail2ban count those. Not for a
    /// host behind jump hosts — the check would sign in to the jump host on its own.
    func checkKeyLogin(_ target: ConnectionTarget) {
        guard case .alias(let alias) = target, !keyChecks.contains(alias), isEnabled(.keyLoginCheck, for: target) else { return }
        keyChecks.insert(alias)
        guard metadata(for: alias).keyLoginWorks == nil, !connectionPath(of: alias).hasJumps else { return }
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
            // Only a clear answer is kept: a server that could not be reached is asked next launch.
            if r.status == 0 { updateMetadata(for: alias) { $0.keyLoginWorks = true } }
            else if r.errorOutput.contains("Permission denied") { updateMetadata(for: alias) { $0.keyLoginWorks = false } }
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
    /// Sealed with this run's Secure Enclave key where there is one (see `SealedPasswordCache`).
    @ObservationIgnored var quickConnectPasswords: [String: (sealed: Data, at: TimeInterval)] = [:]

    /// Quick Connect hands the password typed there (saved or not) to the connection it starts —
    /// no Touch ID for a password just typed. Kept until that connection's own question takes it:
    /// a jump host's sign-in may come first. Gone after five minutes either way (or when the screen
    /// locks).
    func offerQuickConnectPassword(_ password: String, for key: String) {
        let at = ProcessInfo.processInfo.systemUptime
        quickConnectPasswords[key] = (passwordCache.seal(password), at)
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            if self?.quickConnectPasswords[key]?.at == at { self?.quickConnectPasswords[key] = nil }
        }
    }

    /// Only for the question ssh asks for the Quick Connect target itself (not a jump host).
    func takeQuickConnectPassword(for request: AskPassRequest) -> String? {
        guard let login = request.sshNamedLogin, isTargetItself(login.host, targetKey: request.targetKey),
              let entry = quickConnectPasswords.removeValue(forKey: request.targetKey) else { return nil }
        return ProcessInfo.processInfo.systemUptime - entry.at < 300 ? passwordCache.open(entry.sealed) : nil
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
        // What ssh itself works out (HostName from `%h`, wildcard or Match blocks, a HostKeyAlias,
        // every jump host): the config text alone does not show those.
        var resolvedJumps = false
        if let resolved = ResolvedNames.names(for: targetKey) {
            names.formUnion(resolved.names)
            resolvedJumps = resolved.hasJumps
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
        return (names, seen > 0 || resolvedJumps)
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

    /// The tabs a sign-in stands for wait to be shown (it was ended while nobody could answer).
    func waitForUser(token: String, sessionID: UUID?, host: String) {
        let front = Set(workspaces.frontSessions.map(\.id))
        var waiting: [UUID: TerminalSession] = [:]
        for id in SignInInterest.waiting(for: token)?.sessions ?? [] { if let s = sessions.session(id) { waiting[id] = s } }
        if let id = sessionID, let s = sessions.session(id) { waiting[id] = s }
        let hostKey = sessionID.flatMap { sessions.session($0)?.descriptor.target.key } ?? host
        for s in sessions.sessions(for: hostKey) { waiting[s.id] = s }
        for s in waiting.values where !front.contains(s.id) && !s.phase.isOnline { s.waitForUser() }
    }

    /// Decides how each askpass question is answered (`SignInBroker`); what was done for each
    /// sign-in's questions is in its ledger.
    @ObservationIgnored lazy var signInBroker = SignInBroker(cache: passwordCache)
    var signIns: SignInLedger { signInBroker.ledger }
    /// The ssh program whose version `passwordCache.sshNamesItsQuestions` was worked out for.
    @ObservationIgnored private var checkedSSHBinary: String?
    /// Counts version checks: only the newest may set the answer (a slow check for the program set
    /// before must not overwrite the one for the program set now).
    @ObservationIgnored private var sshCheckGeneration = 0
    @ObservationIgnored private var sshCheck: Task<Void, Never>?

    /// Works out whether the ssh program marks servers' questions. A program that does not answer in
    /// time (a busy Mac at launch) is asked again, never taken as a no. `forgetIfNot`: the program was
    /// changed in Settings — remembered passwords stay only if the new one marks them too.
    private func startSSHCheck(_ cache: SealedPasswordCache, binary: String, forgetIfNot: Bool = false) {
        sshCheckGeneration += 1
        let generation = sshCheckGeneration
        sshCheck = Task { @MainActor [weak self] in
            var names: Bool?
            for attempt in 0..<4 {
                names = await SSHVersion.namesItsQuestions(binary: binary)
                guard let self, generation == self.sshCheckGeneration else { return }
                if names != nil { break }
                ConnectionLog.shared.notice("The ssh program did not tell its version in time; asking again", .app)
                try? await Task.sleep(for: .seconds(2 * (attempt + 1)))
            }
            guard let self, generation == self.sshCheckGeneration else { return }
            let marks = names ?? false
            ConnectionLog.shared.info("ssh program checked", .app,
                                      detail: names == nil ? "it did not answer; nothing is filled in by itself"
                                          : marks ? "it marks servers' own questions (OpenSSH 8.4 or later)" : "it does not mark servers' own questions (older than OpenSSH 8.4)")
            if forgetIfNot, !marks { cache.removeAll(reason: "the ssh program was changed in Settings") }
            cache.sshNamesItsQuestions = marks
        }
    }

    /// Waits (at most 5 s) for the ssh program's check, so the first questions after launch are
    /// decided with its answer.
    nonisolated func sshCheckSettled() async {
        guard let check = await MainActor.run(body: { self.passwordCache.sshChecked ? nil : self.sshCheck }) else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await check.value }
            group.addTask { try? await Task.sleep(for: .seconds(5)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// A sign-in ended: a password typed for it is saved in the keychain only if it worked.
    func signInEnded(token: String, end: SignInEnd) {
        guard let save = signIns.ended(token: token, end: end) else { return }
        Credentials.save(save.password, for: save.item, replacesRemembered: false)
        ConnectionLog.shared.info("Saved the password in the keychain (the sign-in worked)", .signIn, host: save.item)
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
        signInRecorder = SignInRecorder(cache: cache)
        SignInEvents.shared.add(signInRecorder!)
        return cache
    }()
    /// Keeps what sign-ins were answered with, by how they ended (held here: `SignInEvents` holds
    /// its observers weakly).
    @ObservationIgnored private var signInRecorder: SignInRecorder?
    @ObservationIgnored private let signInGatekeeper = LockGatekeeper()

    /// When a saved password was last typed into each session (automatically or with a click): the
    /// same prompt coming back right after means it was not accepted.
    @ObservationIgnored var lastFilled: [UUID: Date] = [:]
    /// The keychain item each session's current prompt belongs to, worked out when it appeared.
    var resolvedCredentials: [UUID: (prompt: PasswordPrompt, key: String)] = [:]
    /// Last automatic fill per session (to stop after a wrong password).
    @ObservationIgnored var autoFilled: [UUID: (key: String, date: Date)] = [:]

    /// The user answered a sign-in question (nil: cancelled; "": a key skipped; "yes"/"no").
    func resolvePrompt(_ prompt: PendingPrompt, answer: String?, save: Bool) {
        let reply: SignInBroker.UserAnswer
        switch answer {
        case nil: reply = .cancel
        case "": reply = .skipKey
        case "yes" where prompt.request.isConfirmation || prompt.request.isPermissionQuestion: reply = .yes
        case "no" where prompt.request.isConfirmation || prompt.request.isPermissionQuestion: reply = .no
        case let text?: reply = .text(text, save: save)
        }
        signInBroker.resolve(prompt.id, with: reply)
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
        // A setting that decides sign-ins or connections changed: noted (an event after it reads
        // in its light).
        let snapshot = Self.settingsSnapshot(settings)
        if let last = lastLoggedSettings, last != snapshot {
            ConnectionLog.shared.info("Settings for connections and sign-ins changed", .app, detail: snapshot)
        }
        lastLoggedSettings = snapshot
        // Sharing switched off: the shared connections close (their tabs reconnect without them).
        if lastSharing == true && !settings.useControlMaster {
            ConnectionLog.shared.notice("Connection sharing was turned off; the shared connections take nothing new and end once what runs on them has ended", .app)
            SharedConnections.closeAllNow(ssh: settings.sshBinary, gently: true)
            // Their silent channels too (each holds a session, and so its connection, open).
            Task { await SharedConnections.shared.reset() }
        }
        lastSharing = settings.useControlMaster
        RetryPace.longest = settings.reconnectMaxDelay
        if checkedSSHBinary != settings.sshBinary {
            checkedSSHBinary = settings.sshBinary
            // Remembered passwords stay if the new program marks servers' questions as well.
            let cache = passwordCache, binary = settings.sshBinary
            cache.sshChecked = false
            startSSHCheck(cache, binary: binary, forgetIfNot: true)
        }
        passwordCache.maxAge = settings.forgetSignInPasswordsAfterHours > 0 ? Double(settings.forgetSignInPasswordsAfterHours) * 3600 : nil
        if passwordCache.isEnabled != settings.rememberSignInPasswords {
            passwordCache.isEnabled = settings.rememberSignInPasswords
            if !settings.rememberSignInPasswords { passwordCache.removeAll(reason: "remembering was turned off in Settings") }
        }
        TerminalRegistry.shared.applySettings(settings)
        RecordingStore.configure(quotaMB: settings.recordingQuotaMB, retentionDays: settings.recordingRetentionDays,
                                 compressAfterDays: settings.compressRecordingsAfterDays,
                                 partMB: settings.recordingPartMB, shortenLargestFirst: settings.recordingShortenLargestFirst,
                                 minFreeGB: settings.recordingProtectFreeSpace ? settings.recordingMinFreeGB : 0)
        if config.mainURL != settings.resolvedSSHConfigURL { reloadConfig() }
        applyCommandSettings()
        for s in sessions.sessions { applyAgentSettings(to: s) }
        // Open file tabs and command watchers use the new ssh settings from now on too.
        fileTabs.settingsChanged()
        for hub in commandHubs.values where hub.executor.options != SSHOptions(settings: settings) {
            hub.executor = executor(for: hub.executor.target)
        }
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
