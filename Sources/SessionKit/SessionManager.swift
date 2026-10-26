import Foundation
import Observation
import TetherCore
import SSHTransport
import RecordingKit

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
    @ObservationIgnored private var networkWasLost = false

    private struct SavedSession: Codable {
        var descriptor: SessionDescriptor
        var persistence: ActivePersistence
        var background: Bool?
        var suspended: Bool?
    }

    public init(settings: SettingsStore) {
        self.settings = settings
        archive = archiveStore.load() ?? []
        connectivity.onChange = { [weak self] online in
            guard let self else { return }
            if online {
                // After a real outage, shared connections opened on the previous network are dead (and an
                // address there may belong to a different machine here): close them before reconnecting.
                // A plain wake from sleep keeps them, so plain shells that survived are not cut off.
                let outage = self.networkWasLost
                self.networkWasLost = false
                Task {
                    if outage { await self.closeAllMasters() }
                    self.retryWaiting()
                }
            } else {
                self.networkWasLost = true
                self.sessions.forEach { $0.networkBecameUnavailable() }
            }
        }
    }

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

    /// Terminals per shared connection. sshd allows 10 sessions per connection by default; slot 0
    /// also carries monitoring, transfers and port forwards, so each slot gets at most 6 terminals.
    public static let terminalsPerConnection = 6

    /// The shared connection a new session to `target` should use: the least loaded slot with room.
    private func nextControlSlot(for target: ConnectionTarget) -> Int {
        var load: [Int: Int] = [:]
        for s in sessions where s.descriptor.target.key == target.key && !s.phase.isDead { load[s.controlSlot, default: 0] += 1 }
        var slot = 0
        while load[slot, default: 0] >= Self.terminalsPerConnection { slot += 1 }
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
        prepare(session)
        return session
    }

    // MARK: Tabs

    /// Closes a tab. Dead sessions are simply removed (they are already archived).
    public func close(_ id: UUID, killRemote: Bool) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]
        if !session.phase.isDead { session.close(killRemote: killRemote) }
        onSessionClosed?(session, killRemote)
        sessions.remove(at: index)
        background.remove(id)
        if selectedID == id { selectedID = nil }
        didRemove(id)
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
            _ = await ProcessRunner.run(options.sshBinary, arguments: ["-o", "ControlPath=\(path)", "-O", "exit", "tether-master"],
                                        timeout: 5)
        }
    }

    public func retryWaiting() {
        for s in sessions { s.reconnectNow() }
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
                guard self.redactAgain else { break }
                self.redactAgain = false
            }
            self?.redactionTask = nil
        }
    }

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
        let saved = sessions.compactMap { s -> SavedSession? in
            // Private sessions leave nothing on this Mac: they are not brought back after quitting.
            guard !s.phase.isDead, !s.descriptor.isPrivate, s.persistence == .tmux || s.persistence == .screen else { return nil }
            return SavedSession(descriptor: s.descriptor, persistence: s.persistence,
                                background: background.contains(s.id), suspended: s.phase.isSuspended)
        }
        openStore.saveSoon(saved)
    }

    /// Re-attaches to tmux/screen sessions that were open when the app quit.
    public func restoreOpenSessions() {
        guard settings.settings.restoreSessionsOnLaunch, let saved = openStore.load() else { return }
        for item in saved {
            let session = makeSession(item.descriptor)
            session.controlSlot = nextControlSlot(for: item.descriptor.target)
            sessions.append(session)
            if item.background == true { background.insert(session.id) }
            if item.suspended == true { session.restoreSuspended(previous: item.persistence) }
            else { session.restore(previous: item.persistence) }
        }
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
    }
}
