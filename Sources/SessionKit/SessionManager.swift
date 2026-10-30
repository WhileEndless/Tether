import Foundation
import Observation
import TetherCore
import SSHTransport
import RecordingKit
import CryptoKit

/// Owns every open terminal session, the archive of dead ones, and restoring tabs on launch.
@MainActor
@Observable
public final class SessionManager {
    public private(set) var sessions: [TerminalSession] = []
    public private(set) var archive: [ArchivedSession] = []
    /// The session in the frontmost window (for sidebar highlighting and menu commands).
    public var selectedID: UUID?
    /// Sessions kept running without a tab ("moved to background").
    public private(set) var background: Set<UUID> = []

    /// Called for every new session before it starts so the UI can attach a terminal view.
    @ObservationIgnored public var prepare: (TerminalSession) -> Void = { _ in }
    /// Called when a session is removed for good (to release its view).
    @ObservationIgnored public var didRemove: (UUID) -> Void = { _ in }
    /// A session ended (its shell exited, its server session was gone, …).
    @ObservationIgnored public var onSessionEnded: ((TerminalSession) -> Void)?
    /// A session was closed by the user; `killedRemote` when its tmux/screen session was ended too.
    @ObservationIgnored public var onSessionClosed: ((TerminalSession, Bool) -> Void)?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let archiveStore = JSONStore<[ArchivedSession]>(filename: "archive.json")
    @ObservationIgnored private let openStore = JSONStore<[SavedSession]>(filename: "open-sessions.json")
    @ObservationIgnored private let connectivity = ConnectivityMonitor()
    private struct SavedSession: Codable {
        var descriptor: SessionDescriptor
        var persistence: ActivePersistence
        var background: Bool?
        var suspended: Bool?
        /// The user asked to end it on the server, which could not be reached then: done once it is.
        var endWhenConnected: Bool?
        /// Its recording, relative to the recordings folder: continued after a relaunch.
        var recording: String?
    }

    public init(settings: SettingsStore) {
        self.settings = settings
        archive = archiveStore.load() ?? []
        connectivity.onEvent = { [weak self] event in self?.connectivityChanged(event) }
    }

    // MARK: Network and sleep

    /// Like plain ssh, a connection is not given up because the network went away for a moment or
    /// the Mac slept: it often survives, and then nobody has to sign in again.
    ///
    /// - The network goes away: tabs stop judging stalls. Only after `networkLossGraceSeconds`
    ///   without it do tmux/screen tabs let go (they re-attach the moment it is back).
    /// - The Mac goes to sleep: tmux/screen tabs let go now, so the server has nothing to send while
    ///   the Mac cannot answer — a server whose data goes unacknowledged gives up on the connection
    ///   after some minutes. The shared connection itself stays, silent.
    /// - Back (or the way out changed): each shared connection is checked over its own link, given
    ///   up only when it is clearly dead or stays silent for `deadAfterSeconds` while the network is
    ///   there; then the tabs re-attach — through the surviving connection without any question.
    func connectivityChanged(_ event: ConnectivityMonitor.Event) {
        let names: [ConnectivityMonitor.Event: String] = [.willSleep: "The Mac is going to sleep", .didWake: "The Mac woke up",
                                                         .lost: "The network went away", .restored: "The network is back",
                                                         .changed: "The way out to the network changed"]
        let ways = connectivity.interfaces.isEmpty ? "none" : connectivity.interfaces.joined(separator: ", ")
        ConnectionLog.shared.info(names[event] ?? "Network event", .network,
                                  detail: event == .willSleep ? nil : "Network interfaces: \(ways)")
        switch event {
        case .willSleep:
            hold(true)
            lossGrace?.cancel()
            returnTask?.cancel()
            returnTask = nil
            sessions.forEach { $0.prepareForSleep() }
        case .lost:
            hold(true)
            lossGrace?.cancel()
            returnTask?.cancel()
            returnTask = nil
            let grace = max(settings.settings.networkLossGraceSeconds, 0)
            lossGrace = Task { [weak self] in
                try? await Task.sleep(for: .seconds(grace))
                guard !Task.isCancelled, let self, !self.connectivity.isOnline else { return }
                ConnectionLog.shared.notice("The network stayed away for \(Int(grace)) s; tmux and screen tabs detach", .network)
                self.sessions.forEach { $0.networkBecameUnavailable() }
            }
        case .changed:
            // Still online through another way out: the connections are checked (one bound to the
            // old address is dead); tabs are left alone. Interfaces come and go in bursts (a VPN
            // reconnecting), so this waits for them to settle. Also while the check after waking
            // still runs: that lasts as long as its slowest host, and a connection it found alive
            // before this change is asked again (one still being checked is not asked twice).
            guard connectivity.isOnline, !connectivity.isAsleep else { return }
            changeCheck?.cancel()
            changeCheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.connectivity.isOnline else { return }
                await SharedConnections.shared.restartStalledSignIns(startedBefore: SharedConnections.uptime - 2)
                // The old way out is most likely gone, and every connection over it: decided quickly.
                await self.closeDeadMasters(deadAfter: min(self.settings.settings.deadAfterSeconds, 10))
                // A new way out (a VPN up, another network) may reach servers that did not answer:
                // their waiting tabs try now instead of at their next round.
                guard !Task.isCancelled, self.connectivity.isOnline else { return }
                HostRetryClock.shared.reset()
                self.retryWaiting()
            }
        case .didWake, .restored:
            // Waking is reported before Wi-Fi is back: connections judged then would all look dead.
            guard connectivity.isOnline, !connectivity.isAsleep else { return }
            lossGrace?.cancel()
            lossGrace = nil
            returnTask?.cancel()
            let attempt = UUID()
            returnAttempt = attempt
            // Every host on its own: tabs re-attach at once (through connections that survived, without
            // a question), while each connection is checked separately. A host that does not answer
            // delays only its own tabs — its connection is closed when found dead, and they sign in
            // again then.
            let moment = SharedConnections.uptime
            Task { await SharedConnections.shared.restartStalledSignIns(startedBefore: moment) }
            hold(false)
            HostRetryClock.shared.reset()
            retryWaiting()
            returnTask = Task { [weak self] in
                guard let self else { return }
                defer { if self.returnAttempt == attempt { self.returnTask = nil } }
                await self.closeDeadMasters()
            }
        }
    }

    private func hold(_ held: Bool) {
        for s in sessions where s.connectivityHeld != held { s.connectivityHeld = held }
    }

    @ObservationIgnored private var lossGrace: Task<Void, Never>?
    @ObservationIgnored private var returnTask: Task<Void, Never>?
    @ObservationIgnored private var changeCheck: Task<Void, Never>?
    @ObservationIgnored private var returnAttempt: UUID?

    public var selected: TerminalSession? {
        sessions.first { $0.id == selectedID }
    }

    public func session(_ id: UUID) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    public func sessions(for targetKey: String) -> [TerminalSession] {
        sessions.filter { $0.descriptor.target.key == targetKey }
    }

    // MARK: Opening

    @discardableResult
    public func open(_ target: ConnectionTarget, title: String? = nil, color: TagColor = .none,
                     persistence: PersistenceMode? = nil, remoteSessionName: String? = nil,
                     directory: String? = nil, isPrivate: Bool = false) -> TerminalSession {
        var descriptor = SessionDescriptor(target: target, title: title, color: color,
                                           persistence: persistence ?? settings.settings.defaultPersistence)
        descriptor.initialDirectory = directory
        descriptor.isPrivate = isPrivate
        if let remoteSessionName { descriptor.remoteSessionName = remoteSessionName }
        let session = makeSession(descriptor)
        session.controlSlot = nextControlSlot(for: target)
        sessions.append(session)
        if remoteSessionName != nil {
            session.openedForAttach = true
            // Attaching to an existing remote session: never create a new one.
            session.restore(previous: descriptor.persistence == .screen ? .screen : .tmux)
        } else {
            session.start()
        }
        saveOpenSessions()
        return session
    }

    /// Terminals per shared connection. sshd allows 10 sessions per connection by default; each
    /// connection also has its silent channel (`SharedConnections`), and slot 0 carries monitoring,
    /// file listings and transfers too. Every further connection is a sign-in of its own, so they are
    /// filled as far as the server allows; a server that allows fewer refuses, and the tab moves on.
    public static func terminalsPerConnection(slot: Int) -> Int { slot == 0 ? 5 : 8 }

    /// The shared connection a new session to `target` should use: the first slot with room.
    /// Suspended tabs hold no channel and are not counted.
    private func nextControlSlot(for target: ConnectionTarget) -> Int {
        var load: [Int: Int] = [:]
        for s in sessions where s.descriptor.target.key == target.key && !s.phase.isDead && !s.phase.isSuspended {
            load[s.controlSlot, default: 0] += 1
        }
        var slot = 0
        while load[slot, default: 0] >= Self.terminalsPerConnection(slot: slot) { slot += 1 }
        return slot
    }

    /// Opens a fresh session to the same destination (used for dead tabs and "Duplicate").
    @discardableResult
    public func openNew(like session: TerminalSession) -> TerminalSession {
        open(session.descriptor.target, title: session.descriptor.customTitle ? session.descriptor.title : nil,
             color: session.descriptor.color, persistence: session.descriptor.persistence, isPrivate: session.descriptor.isPrivate)
    }

    private func makeSession(_ descriptor: SessionDescriptor) -> TerminalSession {
        let store = settings
        let session = TerminalSession(descriptor: descriptor) { SessionConfiguration(settings: store.settings) }
        session.onDeath = { [weak self] s in self?.archiveSession(s) }
        // An ended session without a tab has nowhere to be seen: remove it (the archive keeps it).
        session.onEnded = { [weak self] s in
            guard let self else { return }
            self.onSessionEnded?(s)
            // Attaching to a server session that had already ended: nothing to show, close the tab.
            let staleAttach = s.openedForAttach && s.remoteSessionGone && !s.wasOnline
            guard self.background.contains(s.id) || staleAttach else { return }
            DispatchQueue.main.async { self.close(s.id, killRemote: false) }
        }
        session.onPersistenceKnown = { [weak self] _ in self?.saveOpenSessions() }
        session.onStall = { [weak self] s in self?.checkConnection(of: s) }
        session.connectivityHeld = !connectivity.isOnline || connectivity.isAsleep
        prepare(session)
        return session
    }

    // MARK: Tabs

    /// Closes a tab. Dead sessions are simply removed (they are already archived).
    public func close(_ id: UUID, killRemote: Bool) {
        guard let session = session(id) else { return }
        // Ending it archives it, and archiving a background session closes it again (from inside
        // this call): look the session up afresh afterwards instead of trusting an old index.
        if !session.phase.isDead { session.close(killRemote: killRemote) }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        onSessionClosed?(session, killRemote)
        sessions.remove(at: index)
        background.remove(id)
        if selectedID == id { selectedID = nil }
        didRemove(id)
        saveOpenSessions()
    }

    /// Ends a session and its tmux/screen session on the server. Not connected: the server is reached
    /// first (signing in once for it if needed) and the session is ended there before the tab goes;
    /// returns false when the server cannot be reached, and the tab stays (see `endWhenConnected`).
    public func endOnServer(_ id: UUID) async -> Bool {
        guard let s = session(id) else { return true }
        guard !s.phase.isOnline, !s.descriptor.target.isLocal, s.persistence == .tmux || s.persistence == .screen else {
            close(id, killRemote: true)
            return true
        }
        guard await s.endRemoteSession() else { return false }
        close(id, killRemote: false)
        return true
    }

    /// The server could not be reached: the tab moves to the background and keeps trying; once it
    /// is connected again, its session is ended there and it goes.
    public func endWhenConnected(_ id: UUID) {
        guard let s = session(id) else { return }
        s.endWhenConnected = true
        background.insert(id)
        if s.phase.isSuspended { s.resume() } else { s.reconnectNow() }
        saveOpenSessions()
    }

    /// Takes back "End When Connected": the session stays (in the background) and is not ended.
    public func keepRunning(_ id: UUID) {
        guard let s = session(id), s.endWhenConnected else { return }
        s.endWhenConnected = false
        saveOpenSessions()
    }

    /// Disconnects a persistent session and keeps it (suspended) in the background.
    public func suspend(_ id: UUID) {
        guard let s = session(id) else { return }
        s.suspend()
        background.insert(id)
        saveOpenSessions()
    }

    /// Marks a session as running without a tab (or back in a tab).
    public func setBackground(_ id: UUID, _ value: Bool) {
        guard session(id) != nil, background.contains(id) != value else { return }
        if value { background.insert(id) } else { background.remove(id) }
        saveOpenSessions()
    }

    /// Puts the given sessions (all of one host) in this order. They keep the places they had in the
    /// overall list, so other hosts' sessions do not move. The order is saved with the open sessions.
    public func reorder(_ ids: [UUID]) {
        let wanted = ids.compactMap { id in sessions.first { $0.id == id } }
        let slots = sessions.indices.filter { i in ids.contains(sessions[i].id) }
        guard wanted.count == slots.count, !slots.isEmpty else { return }
        for (slot, session) in zip(slots, wanted) { sessions[slot] = session }
        saveOpenSessions()
    }

    public func rename(_ id: UUID, to title: String) {
        guard let s = session(id) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        s.descriptor.customTitle = !trimmed.isEmpty
        s.descriptor.title = trimmed.isEmpty ? s.descriptor.target.displayName : trimmed
        saveOpenSessions()
    }

    public func setColor(_ id: UUID, _ color: TagColor) {
        session(id)?.descriptor.color = color
        saveOpenSessions()
    }

    /// Asks every ControlMaster socket of this app to exit.
    public func closeAllMasters() async {
        let options = SSHOptions(settings: settings.settings)
        guard options.useControlMaster else { return }
        let dir = AppPaths.controlSocketDirectory
        let sockets = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in sockets where name != AppPaths.askPassSocket.lastPathComponent {
            let path = dir.appendingPathComponent(name).path
            _ = await ProcessRunner.run(options.sshBinary, arguments: ["-F", "/dev/null", "-o", "ControlPath=\(path)", "-O", "exit", "tether-master"],
                                        timeout: 5)
        }
    }

    /// Closes the shared connections that no longer reach their server and keeps the others.
    /// One that does not answer gets until `deadAfterSeconds` (awake, with the network there) —
    /// a VPN reconnecting, Wi-Fi joining — before it counts as dead.
    /// `deadAfter`: seconds of silence after which a connection counts as dead (the setting by
    /// default; shorter after the way out to the network changed, when the old one is most likely dead).
    public func closeDeadMasters(only sockets: [String]? = nil, deadAfter limit: Double? = nil) async {
        let options = SSHOptions(settings: settings.settings)
        guard options.useControlMaster else { return }
        let dir = AppPaths.controlSocketDirectory
        let all = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0 != AppPaths.askPassSocket.lastPathComponent }
            .map { dir.appendingPathComponent($0).path }
            .filter(Self.isSocket)
        let targets = sockets.map { wanted in all.filter { wanted.contains($0) } } ?? all
        let deadAfter = max(limit ?? settings.settings.deadAfterSeconds, 5)
        await withTaskGroup(of: Void.self) { group in
            for path in targets where probing.insert(path).inserted {
                group.addTask { @MainActor [weak self] in
                    defer { self?.probing.remove(path) }
                    // A network device runs nothing Tether sends (a probe's `exit 0` could fail on a
                    // live one): only whether its connection is still there is asked.
                    if await SharedConnections.shared.isDeviceConnection(path) {
                        if case .gone = await SharedConnections.check(path, ssh: options.sshBinary) {
                            await SharedConnections.shared.forget(socket: path)
                        }
                        return
                    }
                    let start = ProcessInfo.processInfo.systemUptime
                    await self?.noteChecking(path, true)
                    defer { Task { @MainActor [weak self] in await self?.noteChecking(path, false) } }
                    var verdict = await Self.probeMaster(path, ssh: options.sshBinary, timeout: min(8, deadAfter))
                    while verdict == nil, !Task.isCancelled {
                        guard let self else { return }
                        // Only time with the network counts; without it nothing is decided.
                        if !self.connectivity.isOnline || self.connectivity.isAsleep { return }
                        if ProcessInfo.processInfo.systemUptime - start >= deadAfter { verdict = false; break }
                        try? await Task.sleep(for: .seconds(min(5, deadAfter / 3)))
                        verdict = await Self.probeMaster(path, ssh: options.sshBinary, timeout: min(10, deadAfter))
                    }
                    let host = await SharedConnections.shared.hostKey(of: path)
                    let took = SharedConnections.seconds(ProcessInfo.processInfo.systemUptime - start)
                    guard verdict == false else {
                        if verdict == true { ConnectionLog.shared.info("Checked a connection: it still reaches its server (\(took))", host: host) }
                        return
                    }
                    ConnectionLog.shared.notice("Closed a connection that no longer reaches its server (no answer in \(took))", host: host)
                    _ = await ProcessRunner.run(options.sshBinary, arguments: [
                        "-F", "/dev/null", "-o", "ControlPath=\(path)", "-O", "exit", "tether-master",
                    ], timeout: 5)
                    await SharedConnections.shared.forget(socket: path)
                }
            }
        }
    }

    @ObservationIgnored private var probing: Set<String> = []

    /// The tabs waiting on a connection being checked say so (instead of only "connecting").
    private func noteChecking(_ socket: String, _ checking: Bool) async {
        let options = SSHOptions(settings: settings.settings)
        for s in sessions where !s.phase.isOnline && !s.phase.isDead && !s.descriptor.target.isLocal {
            var o = options
            o.controlSlot = s.controlSlot
            guard await SharedConnections.shared.socket(for: s.descriptor.target, options: o) == socket else { continue }
            s.noteConnectionCheck(checking)
        }
    }

    /// Retry (or Reconnect Now) while an attempt hangs: the tab's shared connection is asked for a
    /// moment; if it does not answer it is closed (it went dead: a new network, a sleeping router),
    /// and the tab starts again at once — signing in again with what it already knows.
    public func retryNow(_ session: TerminalSession) {
        if session.phase.isDead { session.retryAfterFailure(); return }
        let options = { var o = SSHOptions(settings: settings.settings); o.controlSlot = session.controlSlot; return o }()
        guard options.useControlMaster, !session.descriptor.target.isLocal else { session.restartAttempt(); return }
        session.noteConnectionCheck(true)
        Task { [weak self] in
            if let socket = await SharedConnections.shared.socket(for: session.descriptor.target, options: options), Self.isSocket(socket),
               await Self.probeMaster(socket, ssh: options.sshBinary, timeout: 4) != true {
                ConnectionLog.shared.notice("Retry: closed a connection that did not answer", host: session.descriptor.target.key)
                _ = await ProcessRunner.run(options.sshBinary, arguments: [
                    "-F", "/dev/null", "-o", "ControlPath=\(socket)", "-O", "exit", "tether-master",
                ], timeout: 5)
                await SharedConnections.shared.forget(socket: socket)
                // The host's other tabs waiting on it go again too.
                self?.sessions.filter { $0.descriptor.target.key == session.descriptor.target.key && $0 !== session && !$0.phase.isOnline }
                    .forEach { $0.restartAttempt() }
            }
            session.noteConnectionCheck(false)
            session.restartAttempt()
        }
    }

    /// A tab stopped hearing from its server: its shared connection is checked (and closed if it is
    /// dead, so the re-attach signs in once instead of hanging on it).
    func checkConnection(of session: TerminalSession) {
        let options = { var o = SSHOptions(settings: settings.settings); o.controlSlot = session.controlSlot; return o }()
        let target = session.descriptor.target
        Task { [weak self] in
            guard let socket = await SharedConnections.shared.socket(for: target, options: options) else { return }
            await self?.closeDeadMasters(only: [socket])
        }
    }

    /// Whether a shared connection still reaches its server: true (alive), false (clearly dead),
    /// nil (no answer in time). It is asked to run `exit 0` over its existing link — understood by
    /// sh, cmd and PowerShell; any exit status but ssh's own 255 means the server answered. No new
    /// login can happen: no config file, BatchMode, and a ProxyCommand that fails at once if the
    /// socket does not answer (instead of connecting to a host named "tether-master").
    nonisolated static func probeMaster(_ path: String, ssh: String, timeout: TimeInterval) async -> Bool? {
        let r = await ProcessRunner.run(ssh, arguments: [
            "-F", "/dev/null", "-o", "ControlPath=\(path)", "-o", "ControlMaster=no", "-o", "BatchMode=yes",
            "-o", "ProxyCommand=/usr/bin/false", "-o", "RequestTTY=no", "-T", "tether-master", "exit 0",
        ], timeout: timeout)
        if r.timedOut { return nil }
        if r.status != 255 { return true }
        // A full connection (sshd MaxSessions) refuses one more session but is alive.
        return TerminalSession.isSessionRefused(r.errorOutput) ? true : false
    }

    nonisolated static func isSocket(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK
    }

    public func retryWaiting() {
        // Tabs waiting for the user to sign in start when they are shown (`shownToUser`).
        // A tab whose sign-in was cancelled or refused waits for Reconnect: the network coming back
        // does not change the password.
        for s in sessions where !s.waitsForUser && s.retryPausedReason == nil { s.reconnectNow() }
    }

    // MARK: Archive

    private func archiveSession(_ s: TerminalSession) {
        // Private sessions are not remembered.
        guard !s.descriptor.isPrivate else {
            if background.contains(s.id) { close(s.id, killRemote: false) }
            saveOpenSessions()
            return
        }
        let entry = ArchivedSession(id: s.id, target: s.descriptor.target, title: s.displayTitle,
                                    startedAt: s.startedAt, endedAt: s.endedAt ?? Date(),
                                    reason: { if case .dead(let r) = s.phase { r } else { "" } }(),
                                    recordingPath: s.recordingURL?.path)
        archive.removeAll { $0.id == entry.id }
        archive.insert(entry, at: 0)
        if archive.count > 500 { archive.removeLast(archive.count - 500) }
        archiveStore.saveSoon(archive)
        redactArchive()
        // A background session has no tab to show its end, so drop it once archived.
        if background.contains(s.id) { close(s.id, killRemote: false) }
        saveOpenSessions()
    }

    /// Masks secrets (Settings ▸ Security ▸ Secrets in the Archive) in the recordings of archived
    /// sessions not done yet — or, with `again`, in all of them (after the rules changed). Runs
    /// when a session is archived and at launch; a recording that cannot be done now (encrypted
    /// while Tether is locked) is done on a later pass. Open sessions are never changed.
    public func redactArchive(again: Bool = false) {
        if again { for i in archive.indices { archive[i].secretsRedacted = nil } }
        guard redactionTask == nil else { redactAgain = true; return }
        let config = settings.settings.secretRedaction
        let redactor = SecretRedactor(rules: config.activeRules)
        guard config.enabled, !redactor.isEmpty else { return }
        redactionTask = Task { [weak self] in
            while let self {
                let todo = self.archive.filter { $0.secretsRedacted == nil && $0.recordingPath != nil }
                for entry in todo {
                    guard let path = entry.recordingPath else { continue }
                    let outcome = await redactor.redactRecording(at: path)
                    if case .done(let n) = outcome, let i = self.archive.firstIndex(where: { $0.id == entry.id }) {
                        self.archive[i].secretsRedacted = n
                    }
                }
                if !todo.isEmpty { self.archiveStore.saveSoon(self.archive) }
                await self.redactLeftRecordings(redactor, rules: config.activeRules)
                guard self.redactAgain else { break }
                self.redactAgain = false
            }
            self?.redactionTask = nil
        }
    }

    /// Recordings no archived session refers to (left by a crash, by quitting with restoring
    /// turned off, or too large to be continued): masked too, each once per set of rules.
    private func redactLeftRecordings(_ redactor: SecretRedactor, rules: [SecretRule]) async {
        // Nor the recordings of open tabs, or of restored ones about to continue theirs.
        let referenced = Set(archive.compactMap(\.recordingPath)).union(sessions.compactMap { $0.recordingURL?.path })
            .union(restoredRecordings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let mark = SHA256.hash(data: (try? encoder.encode(rules)) ?? Data()).prefix(12).map { String(format: "%02x", $0) }.joined()
        let left = await RecordingStore.perform {
            RecordingStore.all().filter { info in
                guard !info.isActive else { return false }
                let path = info.isCompressed ? info.url.deletingPathExtension().path : info.url.path
                return !referenced.contains(path) && RecordingStore.redactionMark(of: info.url) != mark
            }
        }
        for info in left {
            let path = info.isCompressed ? info.url.deletingPathExtension().path : info.url.path
            if case .done = await redactor.redactRecording(at: path), let url = RecordingStore.resolve(path) {
                RecordingStore.setRedactionMark(mark, on: url)
            }
        }
    }

    /// Recordings restored tabs continue (or tried to), from this launch.
    @ObservationIgnored private var restoredRecordings: Set<String> = []
    @ObservationIgnored private var redactionTask: Task<Void, Never>?
    @ObservationIgnored private var redactAgain = false

    public func deleteArchived(_ id: UUID, deleteRecording: Bool) {
        if deleteRecording, let path = archive.first(where: { $0.id == id })?.recordingPath {
            RecordingStore.delete(path: path)     // compressed or not, with its parts
        }
        archive.removeAll { $0.id == id }
        archiveStore.saveSoon(archive)
    }

    public func clearArchive() {
        archive.removeAll()
        archiveStore.saveSoon(archive)
    }

    // MARK: Persistence across launches

    public func saveOpenSessions() {
        // Before the last run's tabs were brought back (Tether still locked at launch), the list
        // on disk is theirs: nothing is written over it.
        guard restoreRan else { return }
        let saved = sessions.compactMap { s -> SavedSession? in
            // A tab brought back that has not said yet what keeps it (its recording is being
            // reopened): saved as it was.
            let persistence = s.persistence == .unknown ? restoringPersistence[s.id] ?? .unknown : s.persistence
            // Private sessions leave nothing on this Mac: they are not brought back after quitting.
            guard !s.phase.isDead, !s.descriptor.isPrivate, persistence == .tmux || persistence == .screen else { return nil }
            return SavedSession(descriptor: s.descriptor, persistence: persistence,
                                background: background.contains(s.id), suspended: s.phase.isSuspended,
                                endWhenConnected: s.endWhenConnected ? true : nil,
                                recording: s.recordingURL.flatMap(Self.recordingName))
        }
        // The sessions are on the servers (tmux, screen) and listed there too: this only brings
        // them back by themselves after a relaunch. A tab added or closed is written within a
        // second (a crash or a forced quit then still brings it back); other changes can wait.
        let ids = Set(saved.map(\.descriptor.id))
        let changed = ids != savedIDs
        savedIDs = ids
        openStore.saveSoon(saved, within: changed ? 1 : DeferredWrites.relaxedDelay)
    }

    /// Whether `restoreOpenSessions` ran (see `saveOpenSessions`).
    private var restoreRan = false
    /// The tabs in the list last written.
    private var savedIDs: Set<UUID> = []
    /// What kept the tabs brought back in the last run, until they say again.
    private var restoringPersistence: [UUID: ActivePersistence] = [:]

    /// Re-attaches to tmux/screen sessions that were open when the app quit.
    public func restoreOpenSessions() {
        restoreRan = true
        guard settings.settings.restoreSessionsOnLaunch, let saved = openStore.load() else { return }
        savedIDs = Set(saved.map(\.descriptor.id))
        if !saved.isEmpty {
            let suspended = saved.filter { $0.suspended == true }.count
            ConnectionLog.shared.info("Bringing back \(saved.count) tab\(saved.count == 1 ? "" : "s") from the last run"
                                      + (suspended > 0 ? " (\(suspended) paused)" : ""), .app)
        }
        for item in saved {
            let session = makeSession(item.descriptor)
            session.controlSlot = nextControlSlot(for: item.descriptor.target)
            restoringPersistence[session.id] = item.persistence
            sessions.append(session)
            if item.background == true { background.insert(session.id) }
            session.endWhenConnected = item.endWhenConnected == true
            let start = { [weak session] in
                guard let session else { return }
                if item.suspended == true { session.restoreSuspended(previous: item.persistence) }
                else { session.restore(previous: item.persistence) }
            }
            if let name = item.recording, let url = Self.recordingURL(name) {
                restoredRecordings.insert(url.path)
                session.continueRecording(url, done: start)
            } else {
                start()
            }
        }
    }

    /// A recording's path relative to the recordings folder (nil outside it).
    static func recordingName(_ url: URL) -> String? {
        let base = AppPaths.recordingsDirectory.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : nil
    }

    /// The recording a saved name stands for: inside the recordings folder only.
    static func recordingURL(_ name: String) -> URL? {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { return nil }
        return AppPaths.recordingsDirectory.appendingPathComponent(name)
    }

    /// Called when the app terminates. tmux/screen sessions keep running remotely; plain shells
    /// die with the connection, so they are archived now.
    public func prepareForTermination() {
        saveOpenSessions()
        for s in sessions where !s.phase.isDead {
            if s.persistence == .plain || s.persistence == .unknown, s.wasOnline {
                archiveSession(s)
            }
            s.abandon()
        }
        // Quitting ends the shared connections (the sessions on the servers keep running); the next
        // launch signs in once per server.
        // With "keep connections after quitting", they end by themselves after ControlPersist
        // (their silent channels end with Tether) and a relaunch within that time uses them.
        let options = SSHOptions(settings: settings.settings)
        if !settings.settings.keepConnectionsAfterQuit || !options.useControlMaster { SharedConnections.closeAllNow(ssh: options.sshBinary) }
    }
}
