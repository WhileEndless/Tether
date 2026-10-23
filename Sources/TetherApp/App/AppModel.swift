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

/// A password or confirmation request waiting for the user.
struct PendingPrompt: Identifiable {
    let id = UUID()
    let request: AskPassRequest
    let continuation: CheckedContinuation<String?, Never>
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
    @ObservationIgnored private var configWatcher: DispatchSourceFileSystemObject?

    var settings: AppSettings {
        get { settingsStore.settings }
        set { settingsStore.settings = newValue }
    }

    private init() {
        let store = SettingsStore.shared
        sessions = SessionManager(settings: store)
        transfers = TransferManager { SSHOptions(settings: store.settings) }
        forwards = ForwardManager { SSHOptions(settings: store.settings) }
        config = SSHConfigLibrary(mainURL: store.settings.resolvedSSHConfigURL)
        library = libraryStore.load() ?? HostLibrary()

        sessions.prepare = { session in
            _ = TerminalRegistry.shared.view(for: session)
            session.onOnline = { s in
                let model = AppModel.shared
                model.forwards.sessionConnected(to: s.descriptor.target,
                                                saved: model.metadata(for: s.descriptor.target.key).forwards ?? [])
            }
        }
        sessions.didRemove = { id in
            TerminalRegistry.shared.remove(id)
            AppModel.shared.workspaces.sessionRemoved(id)
        }

        AskPassBridge.shared.start { request in
            await AppModel.shared.answer(request)
        }
        RecordingStore.configure(quotaMB: store.settings.recordingQuotaMB,
                                 retentionDays: store.settings.recordingRetentionDays,
                                 compressAfterDays: store.settings.compressRecordingsAfterDays)
        // Compress old recordings now and then once a day.
        Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in RecordingStore.requestQuotaEnforcement() }
        watchConfigFile()
    }

    func launch() {
        sessions.restoreOpenSessions()
    }

    @ObservationIgnored private var orphansAdopted = false

    /// After launch: restored sessions that are not in a restored window and were not running in
    /// the background (e.g. after a crash) are opened as tabs of the first window.
    func adoptOrphanSessions(into state: WindowState) {
        guard !orphansAdopted else { return }
        orphansAdopted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
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
        libraryStore.save(library)
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
        libraryStore.save(library)
    }

    /// Moves a host into a group (dropped on the group header), placing it last.
    func moveHost(_ alias: String, toGroup group: UUID?) {
        updateMetadata(for: alias) { $0.groupID = group }
        library.hostOrder.removeAll { $0 == alias }
        library.hostOrder.append(alias)
        libraryStore.save(library)
    }

    func moveGroup(_ id: UUID, by offset: Int) {
        guard let i = library.groups.firstIndex(where: { $0.id == id }) else { return }
        let j = min(max(i + offset, 0), library.groups.count - 1)
        guard i != j else { return }
        library.groups.swapAt(i, j)
        libraryStore.save(library)
    }

    var groups: [HostGroup] { library.groups }

    func addGroup(named name: String) {
        library.groups.append(HostGroup(name: name))
        libraryStore.save(library)
    }

    func updateGroup(_ id: UUID, _ change: (inout HostGroup) -> Void) {
        guard let i = library.groups.firstIndex(where: { $0.id == id }) else { return }
        change(&library.groups[i])
        libraryStore.save(library)
    }

    func deleteGroup(_ id: UUID) {
        library.groups.removeAll { $0.id == id }
        for (k, var m) in library.metadata where m.groupID == id {
            m.groupID = nil
            library.metadata[k] = m
        }
        libraryStore.save(library)
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
        libraryStore.save(library)
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

    func monitor(for target: ConnectionTarget) -> RemoteMonitor {
        if let m = monitors[target.key] { return m }
        let m = RemoteMonitor(executor: executor(for: target))
        monitors[target.key] = m
        return m
    }

    @ObservationIgnored private var keyChecks: Set<String> = []

    /// Once per launch and host: checks whether the host accepts key login without a password, so
    /// the key setup offer is only shown where it is useful.
    func checkKeyLogin(_ target: ConnectionTarget) {
        guard case .alias(let alias) = target, !keyChecks.contains(alias) else { return }
        keyChecks.insert(alias)
        var options = SSHOptions(settings: settings)
        options.useControlMaster = false
        let args = options.commonOptions(multiplex: false)
            + ["-o", "BatchMode=yes", "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
               "-o", "ConnectTimeout=10"] + SSHOptions.destinationArguments(for: target) + ["true"]
        Task {
            let r = await ProcessRunner.run(options.sshBinary, arguments: args, timeout: 20)
            updateMetadata(for: alias) { $0.keyLoginWorks = r.status == 0 }
        }
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

    /// Which saved host a password prompt is for. With jump hosts, ssh asks for each hop
    /// (`user@jump.example.com's password:`), so the prompt — not the tab — decides whose password to use.
    func passwordKey(for request: AskPassRequest) -> String {
        guard let r = request.prompt.range(of: #"@([^'\s]+)'s password"#, options: .regularExpression) else {
            return request.targetKey
        }
        let host = String(request.prompt[r].dropFirst().prefix { $0 != "'" })
        if host == request.targetKey || aliases.contains(host) { return host }
        if let entry = hosts.first(where: { $0.hostName == host }), let alias = entry.alias { return alias }
        // The target itself, addressed by its real host name.
        if case .alias(let a) = target(forKey: request.targetKey), config.entry(for: a)?.hostName == host { return a }
        return host
    }

    nonisolated func answer(_ request: AskPassRequest) async -> String? {
        if request.isPasswordPrompt {
            let (key, transient, tried) = await MainActor.run {
                let key = self.passwordKey(for: request)
                return (key, self.transientPasswords[key], self.triedPasswords.contains(request.token + key))
            }
            // Offer a saved password once per hop; a second prompt for the same hop means it was wrong.
            if !tried, let saved = transient ?? PasswordVault.password(for: key) {
                await MainActor.run { _ = self.triedPasswords.insert(request.token + key) }
                return saved
            }
        }
        return await withCheckedContinuation { cont in
            Task { @MainActor in
                self.prompts.append(PendingPrompt(request: request, continuation: cont))
            }
        }
    }

    @ObservationIgnored private var triedPasswords: Set<String> = []

    func resolvePrompt(_ prompt: PendingPrompt, answer: String?, save: Bool) {
        prompts.removeAll { $0.id == prompt.id }
        if save, let answer, prompt.request.isPasswordPrompt {
            PasswordVault.setPassword(answer, for: passwordKey(for: prompt.request))
        }
        prompt.continuation.resume(returning: answer)
    }

    // MARK: Settings side effects

    func settingsChanged() {
        TerminalRegistry.shared.applySettings(settings)
        RecordingStore.configure(quotaMB: settings.recordingQuotaMB, retentionDays: settings.recordingRetentionDays,
                                 compressAfterDays: settings.compressRecordingsAfterDays)
        if config.mainURL != settings.resolvedSSHConfigURL { reloadConfig() }
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
