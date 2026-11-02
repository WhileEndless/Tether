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
    /// Tabs closed here whose sessions went on running on their servers (see `LeftSession`).
    @ObservationIgnored let leftOnServer = LeftOnServer()
    private struct SavedSession: Codable {
        var descriptor: SessionDescriptor
        var persistence: ActivePersistence
        var background: Bool?
        var suspended: Bool?
        /// Earlier versions: "end it on the server once it can be reached". Read only, and taken as
        /// `closedWhileOffline` — nothing is ended without the user any more.
        var endWhenConnected: Bool?
        /// Closed by the user while its server could not be reached (see `closeWhileOffline`).
        var closedWhileOffline: Bool?
        /// Its recording, relative to the recordings folder: continued after a relaunch.
        var recording: String?
    }

    public init(settings: SettingsStore) {
        self.settings = settings
        // Set now, at launch (a static is set when first read: that could be hours later).
        _ = TerminalSession.launchedAt
        archive = archiveStore.load() ?? []
        connectivity.onEvent = { [weak self] event in self?.connectivityChanged(event) }
        // Network events are not guaranteed (one can be missed after a sleep or a quick change):
        // the network is looked at now and then too, so no tab waits for an event that never comes.
        networkLook = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookAtTheNetwork() }
        }
    }

    @ObservationIgnored nonisolated(unsafe) private var networkLook: Timer?
    deinit { networkLook?.invalidate() }

    /// Reports what a missed network event would have, and lets go of tabs still held for a network
    /// that is there.
    private func lookAtTheNetwork() {
        // Tabs closed while offline whose server came back without any event here (another tab's
        // sign-in, the network) are looked for now and then too.
        if connectivity.isOnline, !connectivity.isAsleep { lookForEndedSessions(host: nil, atMostEvery: 300) }
        guard sessions.contains(where: { !$0.phase.isOnline && !$0.phase.isDead && !$0.descriptor.target.isLocal }) else { return }
        connectivity.recheck()
        guard connectivity.isOnline, !connectivity.isAsleep, returnTask == nil,
              sessions.contains(where: \.connectivityHeld) else { return }
        ConnectionLog.shared.notice("The network is there but tabs still waited for it; they go on now", .network)
        lossGrace?.cancel()
        lossGrace = nil
        HostLinks.shared.networkUp = true
        hold(false)
        HostRetryClock.shared.reset()
        retryWaiting()
        HostLinks.shared.post(.networkBack)
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
        var title = names[event] ?? "Network event"
        if event == .didWake, let sleep = connectivity.lastSleep {
            title += " after " + SharedConnections.seconds(sleep.duration) + " asleep" + (sleep.otherNetwork ? ", on another network" : "")
        }
        ConnectionLog.shared.info(title, .network,
                                  detail: event == .willSleep ? nil : "Network interfaces: \(ways)" + (connectivity.isOnline ? "" : " (not online yet: waiting for it)"))
        // What ssh_config says can depend on the network (`Match exec`, `Match localnetwork`): worked
        // out afresh from now on.
        if event != .willSleep && event != .lost { Task { await SharedConnections.shared.forgetResolutions() } }
        HostLinks.shared.networkUp = connectivity.isOnline && !connectivity.isAsleep
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
            // Connections made before now are checked before they are used again (at once: a tab
            // reconnecting in the next two seconds must not trust one over the old way out).
            Task { await SharedConnections.shared.noteNetworkChanged() }
            changeCheck?.cancel()
            changeCheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.connectivity.isOnline else { return }
                await SharedConnections.shared.restartStalledSignIns(startedBefore: SharedConnections.uptime - 2)
                // The old way out is most likely gone, and every connection over it: decided quickly.
                await self.closeDeadMasters(deadAfter: min(self.settings.settings.deadAfterSeconds, 10), why: "the way out to the network changed")
                // A new way out (a VPN up, another network) may reach servers that did not answer:
                // their waiting tabs try now instead of at their next round.
                guard !Task.isCancelled, self.connectivity.isOnline else { return }
                HostRetryClock.shared.reset()
                self.retryWaiting()
                HostLinks.shared.post(.networkBack)
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
            Task {
                // After a sleep or a time offline, connections are checked before they are used again.
                await SharedConnections.shared.noteNetworkChanged()
                await SharedConnections.shared.restartStalledSignIns(startedBefore: moment)
            }
            hold(false)
            HostRetryClock.shared.reset()
            retryWaiting()
            // After a long sleep, or on another network, connections over the old way are most likely
            // gone: decided quickly (a live one answers the check at once).
            let sleep = event == .didWake ? connectivity.lastSleep : nil
            let quick = sleep.map { $0.otherNetwork || $0.duration > 300 } ?? false
            returnTask = Task { [weak self] in
                guard let self else { return }
                defer { if self.returnAttempt == attempt { self.returnTask = nil } }
                await self.closeDeadMasters(deadAfter: quick ? min(self.settings.settings.deadAfterSeconds, 10) : nil,
                                            why: event == .didWake ? "the Mac woke up" : "the network came back")
                // Tabs that tried a connection found dead meanwhile go again at once, not after a
                // back-off.
                guard !Task.isCancelled, self.connectivity.isOnline else { return }
                self.retryWaiting()
                HostLinks.shared.post(.networkBack)
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

    // MARK: Sessions left on servers

    /// The note on a server session that a tab closed here left running, if it is one.
    public func leftSession(on targetKey: String, named name: String) -> LeftSession? {
        leftOnServer.find(targetKey, name)
    }

    /// The session was ended on the server (or found gone).
    public func forgetLeftSession(on targetKey: String, named name: String) {
        leftOnServer.forget(targetKey, name)
    }

    public func forgetLeftSessions(on targetKey: String) {
        leftOnServer.forgetAll(on: targetKey)
    }

    /// A tab closing without ending its server session: noted when that session may go on there.
    private func noteLeftOnServer(_ s: TerminalSession, killRemote: Bool) {
        let d = s.descriptor
        guard !d.target.isLocal, !d.remoteSessionName.isEmpty else { return }
        // Ended with the tab, or known to be gone: no note. (Only then: closing a background tab
        // archives it, which closes it again from inside — the note just made must survive that.)
        if killRemote || d.isPrivate || s.remoteSessionGone {
            leftOnServer.forget(d.target.key, d.remoteSessionName)
            return
        }
        guard !s.phase.isDead, s.mayHoldServerWork, s.persistence == .tmux || s.persistence == .screen else { return }
        leftOnServer.remember(LeftSession(targetKey: d.target.key, name: d.remoteSessionName,
                                          persistence: s.persistence == .screen ? .screen : .tmux,
                                          title: d.customTitle ? d.title : nil, color: d.color, closedAt: Date()))
    }

    // MARK: Opening

    @discardableResult
    public func open(_ target: ConnectionTarget, title: String? = nil, color: TagColor = .none,
                     persistence: PersistenceMode? = nil, remoteSessionName: String? = nil,
                     directory: String? = nil, isPrivate: Bool = false) -> TerminalSession {
        // Opening again a session a tab closed here left running: under that tab's name and color.
        let left = remoteSessionName.flatMap { leftOnServer.find(target.key, $0) }
        var descriptor = SessionDescriptor(target: target, title: title ?? left?.title,
                                           color: color == .none ? left?.color ?? .none : color,
                                           persistence: persistence ?? left?.persistence ?? settings.settings.defaultPersistence)
        descriptor.initialDirectory = directory
        descriptor.isPrivate = isPrivate
        if let remoteSessionName { descriptor.remoteSessionName = remoteSessionName }
        let session = makeSession(descriptor)
        session.controlSlot = nextControlSlot(for: target, plain: descriptor.persistence == .off)
        sessions.append(session)
        if let remoteSessionName {
            leftOnServer.forget(target.key, remoteSessionName)
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
    /// Suspended tabs hold no channel and are not counted (nor those coming back paused).
    ///
    /// `plain`: a tab set to a plain shell on a host whose other tabs use tmux or screen. It gets a
    /// connection of its own (`plainSlots`): a plain shell printing while the Mac sleeps keeps the
    /// server sending, which can end the connection it is on — not the one the re-attaching tabs use.
    private func nextControlSlot(for target: ConnectionTarget, plain: Bool = false) -> Int {
        var load: [Int: Int] = [:]
        // Per server, not per name: two aliases of one server (or an alias and Quick Connect) share
        // its connections (they are named after the server), so their tabs count together.
        func server(_ t: ConnectionTarget) -> String { ResolvedNames.serverID(for: t.key) ?? t.key }
        let wanted = server(target)
        for s in sessions where server(s.descriptor.target) == wanted && !s.phase.isDead && !s.phase.isSuspended
            && !restoringPaused.contains(s.id) {
            load[s.controlSlot, default: 0] += 1
        }
        // Only beside tabs on the usual connections: alone, a plain tab takes the first one (with
        // the forwards ssh_config asks for, which further connections leave out).
        let beside = load.keys.contains { $0 < Self.plainSlots }
        // A server that asks a second step (a code) at sign-in: one connection for all its tabs, as
        // long as it allows (a session it refuses moves that tab on by itself) — never another code.
        if HostLinks.shared.asksSecondStep(target.key) { return 0 }
        var slot = plain && beside ? Self.plainSlots : 0
        while load[slot, default: 0] >= Self.terminalsPerConnection(slot: slot) { slot += 1 }
        return slot
    }

    /// Where the connections for plain-shell tabs start (see `nextControlSlot`).
    public static let plainSlots = 100
    /// Tabs coming back paused from the last run, until they are (they hold no channel).
    @ObservationIgnored private var restoringPaused: Set<UUID> = []

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
        // A private tab keeps nothing on the server either: its own session ends with it.
        noteLeftOnServer(session, killRemote: killRemote)
        if !session.phase.isDead { session.close(killRemote: killRemote || session.descriptor.isPrivate) }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        onSessionClosed?(session, killRemote)
        offlineChecks[id] = nil
        sessions.remove(at: index)
        background.remove(id)
        if selectedID == id { selectedID = nil }
        didRemove(id)
        saveOpenSessions()
    }

    /// Ends a session and its tmux/screen session on the server. Not connected: the server is reached
    /// first (signing in once for it if needed) and the session is ended there before the tab goes;
    /// returns false when the server cannot be reached, and the tab stays (see `closeWhileOffline`).
    public func endOnServer(_ id: UUID) async -> Bool {
        guard let s = session(id) else { return true }
        guard !s.phase.isOnline, !s.descriptor.target.isLocal, s.persistence == .tmux || s.persistence == .screen else {
            close(id, killRemote: true)
            return true
        }
        guard await s.endRemoteSession() else { return false }
        close(id, killRemote: false)
        leftOnServer.forget(s.descriptor.target.key, s.descriptor.remoteSessionName)
        return true
    }

    /// The user closed a tab whose server cannot be reached. Its tmux/screen session may still run
    /// there, and is never ended by itself: the tab waits in the background, paused (not attached),
    /// and once the server can be reached its session is looked for quietly — still there, the user
    /// is told and decides; gone, the tab goes (see `lookForEndedSessions`).
    public func closeWhileOffline(_ id: UUID) {
        guard let s = session(id) else { return }
        s.closedWhileOffline = true
        background.insert(id)
        s.pauseClosedWhileOffline()
        saveOpenSessions()
    }

    /// Keeps such a tab's session (in the background, paused): no more reminders about it.
    public func keepRunning(_ id: UUID) {
        guard let s = session(id), s.closedWhileOffline else { return }
        s.closedWhileOffline = false
        saveOpenSessions()
    }

    /// The tab's server just answered (a sign-in, a connection checked, the network back): its paused
    /// tabs — suspended, waiting for the user, or closed while offline (`awaitsServerSession`) —
    /// have their sessions looked for, quietly (no sign-in that asks, no attaching).
    /// - Gone (found so twice, a few seconds apart): the tab ends and closes; the archive keeps it.
    /// - Still there: a tab closed while offline is told about (`onStillRunning`, once); the others
    ///   stay as they are, and attach as they would have.
    /// - Not known (no answer, a password needed): nothing changes, and it is asked again next time.
    /// `atMostEvery`: seconds between two looks for the same tab (events come in bursts).
    public func lookForEndedSessions(host: String?, atMostEvery gap: TimeInterval = 20) {
        let now = Date()
        for s in sessions where (s.closedWhileOffline ? s.offlineCheck != .stillRunning : s.awaitsServerSession)
            && (host.map { HostLinks.sameServer(s.descriptor.target.key, $0) } ?? true) {
            if let last = offlineChecks[s.id], now.timeIntervalSince(last) < gap { continue }
            offlineChecks[s.id] = now
            Task { [weak self, weak s] in
                guard let s else { return }
                var there = await s.remoteSessionStillThere()
                if there == false {
                    // Once more before anything is closed: a server busy restarting tmux, a moment
                    // between two sessions of the same server.
                    try? await Task.sleep(for: .seconds(Self.goneConfirmDelay))
                    guard s.closedWhileOffline || s.awaitsServerSession else { return }
                    there = await s.remoteSessionStillThere()
                }
                guard let self, self.session(s.id) != nil else { return }
                // Attached (or on its way) meanwhile: what it found there counts, not this look.
                guard s.closedWhileOffline || s.awaitsServerSession else { self.offlineChecks[s.id] = nil; return }
                switch there {
                case true?:
                    guard s.closedWhileOffline else { return }
                    ConnectionLog.shared.notice("A tab closed while its server was unreachable still runs there; asking you", .tab,
                                                host: s.descriptor.target.key)
                    s.offlineCheck = .stillRunning
                    self.onStillRunning?(s)
                case false?:
                    ConnectionLog.shared.info(s.closedWhileOffline ? "A tab closed while its server was unreachable has ended there; removed"
                                                                   : "A tab not attached has ended on the server; closed", .tab,
                                              host: s.descriptor.target.key)
                    self.offlineChecks[s.id] = nil
                    s.remoteSessionEndedWhileAway()
                    self.leftOnServer.forget(s.descriptor.target.key, s.descriptor.remoteSessionName)
                    self.close(s.id, killRemote: false)
                case nil:
                    // Asking needs a sign-in Tether cannot do by itself (a password): said so. No
                    // answer at all: it still waits for the server, and is asked again next time.
                    if s.closedWhileOffline, BackgroundSignIn.shared.reason(s.descriptor.target.key) != nil { s.offlineCheck = .needsSignIn }
                    self.offlineChecks[s.id] = nil
                }
            }
        }
    }
    /// Seconds between the two looks that find a session gone (tests use less).
    nonisolated(unsafe) static var goneConfirmDelay: Double = 3
    @ObservationIgnored private var offlineChecks: [UUID: Date] = [:]
    /// A tab closed while offline turned out to still run on its server (tell the user).
    @ObservationIgnored public var onStillRunning: ((TerminalSession) -> Void)?

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
            await SharedConnections.control(.exit, socket: path, ssh: options.sshBinary)
        }
    }

    /// Closes the shared connections that no longer reach their server and keeps the others.
    /// One that does not answer gets until `deadAfterSeconds` (awake, with the network there) —
    /// a VPN reconnecting, Wi-Fi joining — before it counts as dead. The verdict itself is
    /// `SharedConnections.verifyLink`'s (one check per connection, shared by everyone asking).
    /// `deadAfter`: seconds of silence after which a connection counts as dead (the setting by
    /// default; shorter after the way out to the network changed, when the old one is most likely dead).
    /// `why`: what asked for the check, for the Connection Log.
    public func closeDeadMasters(only sockets: [String]? = nil, deadAfter limit: Double? = nil, why: String? = nil) async {
        let options = SSHOptions(settings: settings.settings)
        guard options.useControlMaster else { return }
        configureLinkHealth()
        let dir = AppPaths.controlSocketDirectory
        let all = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0 != AppPaths.askPassSocket.lastPathComponent }
            .map { dir.appendingPathComponent($0).path }
            .filter(Self.isSocket)
        let targets = sockets.map { wanted in all.filter { wanted.contains($0) } } ?? all
        let deadAfter = max(limit ?? settings.settings.deadAfterSeconds, 5)
        await withTaskGroup(of: Void.self) { group in
            for path in targets {
                group.addTask { @MainActor [weak self] in
                    await self?.noteChecking(path, true)
                    await SharedConnections.shared.verifyLink(path, ssh: options.sshBinary, deadAfter: deadAfter, why: why)
                    await self?.noteChecking(path, false)
                }
            }
        }
    }

    /// Tells the shared connections what counts as a sign of life on one while it is checked (a tab
    /// or a transfer received something) and when a verdict may be reached (online and awake).
    private func configureLinkHealth() {
        guard !linkHealthConfigured else { return }
        linkHealthConfigured = true
        let signsOfLife: @Sendable (String, Date) async -> Bool = { [weak self] socket, moment in
            guard let self else { return false }
            return await self.received(on: socket, since: moment)
        }
        let canJudge: @Sendable () async -> Bool = { [weak self] in
            guard let self else { return false }
            return await self.canJudgeLinks()
        }
        Task { await SharedConnections.shared.configureLinkHealth(signsOfLife: signsOfLife, canJudge: canJudge) }
    }
    @ObservationIgnored private var linkHealthConfigured = false
    private func canJudgeLinks() -> Bool { connectivity.isOnline && !connectivity.isAsleep }

    /// Other signs of life on a connection (a transfer that moved data), by host: told by the app.
    @ObservationIgnored public var otherActivity: (@MainActor (_ host: String, _ since: Date) -> Bool)?

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

    /// Retry (or Reconnect Now) while an attempt hangs: the tab starts again at once. Its shared
    /// connection is checked the usual way (a live one answers at once): only one found dead is
    /// closed — never one that is merely slow, which other tabs may be using.
    public func retryNow(_ session: TerminalSession) {
        if session.phase.isDead { session.retryAfterFailure(); return }
        let options = { var o = SSHOptions(settings: settings.settings); o.controlSlot = session.controlSlot; return o }()
        guard options.useControlMaster, !session.descriptor.target.isLocal else { session.restartAttempt(); return }
        session.noteConnectionCheck(true)
        Task { [weak self] in
            if let socket = await SharedConnections.shared.socket(for: session.descriptor.target, options: options), Self.isSocket(socket),
               await Self.probeMaster(socket, ssh: options.sshBinary, timeout: 4) != true {
                // Not answered at once: the normal check decides, while the tab already starts again.
                Task { await self?.closeDeadMasters(only: [socket], why: "you pressed Retry") }
            }
            session.noteConnectionCheck(false)
            session.restartAttempt()
        }
    }

    /// Whether a tab on this connection received anything from its server since `moment`.
    private func received(on socket: String, since moment: Date) async -> Bool {
        if let otherActivity, let host = await SharedConnections.shared.hostKey(of: socket), otherActivity(host, moment) { return true }
        let options = SSHOptions(settings: settings.settings)
        for s in sessions where s.phase.isOnline && !s.descriptor.target.isLocal && s.lastReceivedAt > moment {
            var o = options
            o.controlSlot = s.controlSlot
            if await SharedConnections.shared.socket(for: s.descriptor.target, options: o) == socket { return true }
        }
        return false
    }

    /// A tab stopped hearing from its server: its shared connection is checked (and closed if it is
    /// dead, so the re-attach signs in once instead of hanging on it).
    func checkConnection(of session: TerminalSession) {
        let options = { var o = SSHOptions(settings: settings.settings); o.controlSlot = session.controlSlot; return o }()
        let target = session.descriptor.target
        Task { [weak self] in
            guard let socket = await SharedConnections.shared.socket(for: target, options: options) else { return }
            // Not used again by a tab before it was checked (a reconnect a moment from now would
            // otherwise ride the same silent connection).
            await SharedConnections.shared.suspect(socket)
            await self?.closeDeadMasters(only: [socket])
        }
    }

    /// Whether a shared connection still reaches its server: true (alive), false (clearly dead),
    /// nil (no answer in time). See `SharedConnections.probe`.
    nonisolated static func probeMaster(_ path: String, ssh: String, timeout: TimeInterval) async -> Bool? {
        await SharedConnections.probe(path, ssh: ssh, timeout: timeout)
    }

    nonisolated static func isSocket(_ path: String) -> Bool { SharedConnections.isSocket(path) }

    public func retryWaiting() {
        // Tabs waiting for the user to sign in start when they are shown (`shownToUser`).
        // A tab whose sign-in was cancelled or refused waits for Reconnect: the network coming back
        // does not change the password.
        for s in sessions where !s.waitsForUser && s.retryPausedReason == nil { s.reconnectNow("the Mac woke, or the network came back or changed") }
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
                                endWhenConnected: nil, closedWhileOffline: s.closedWhileOffline ? true : nil,
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
            session.controlSlot = nextControlSlot(for: item.descriptor.target, plain: item.descriptor.persistence == .off)
            if item.suspended == true { restoringPaused.insert(session.id) }
            restoringPersistence[session.id] = item.persistence
            sessions.append(session)
            if item.background == true { background.insert(session.id) }
            session.closedWhileOffline = item.closedWhileOffline == true || item.endWhenConnected == true
            let start = { [weak session] in
                guard let session else { return }
                if item.suspended == true {
                    session.restoreSuspended(previous: item.persistence)
                    self.restoringPaused.remove(session.id)
                } else { session.restore(previous: item.persistence) }
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
        // Commands still running (listings, checks) and sign-ins under way have nobody to answer
        // any more; nothing new starts.
        ProcessRunner.terminateAll()
        SharedConnections.stopSigningIn()
        let live = sessions.filter { !$0.phase.isDead }
        for s in live where s.persistence == .plain || s.persistence == .unknown {
            if s.wasOnline { archiveSession(s) }
        }
        // Every private tab's "end" goes out first, then one short moment for all of them to leave
        // this Mac — not a moment per tab while the app cannot quit.
        let sent = live.map { $0.beginAbandon() }.contains(true)
        if sent { usleep(250_000) }
        live.forEach { $0.finishAbandon() }
        // Quitting ends the shared connections (the sessions on the servers keep running); the next
        // launch signs in once per server.
        // With "keep connections after quitting", they end by themselves after ControlPersist
        // (their silent channels end with Tether) and a relaunch within that time uses them.
        let options = SSHOptions(settings: settings.settings)
        if !settings.settings.keepConnectionsAfterQuit || !options.useControlMaster { SharedConnections.closeAllNow(ssh: options.sshBinary) }
    }
}
