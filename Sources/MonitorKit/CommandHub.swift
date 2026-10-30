import Foundation
import SSHTransport
import TetherCore

/// What the watcher says about one terminal (see `ProbeScripts.commandWatch`).
public enum WatchEvent: Equatable, Sendable {
    case busy(pid: Int, commandLine: String)
    case idle
    case gone

    /// `<tab> busy <pid> <command line>`, `<tab> idle`, `<tab> gone`; `.` and anything else: nil.
    static func parse(_ line: String) -> (tab: Int, event: WatchEvent)? {
        // Stream records keep their line break (and Windows output may end in CR).
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
        guard f.count >= 2, let tab = Int(f[0]), tab >= 0 else { return nil }
        switch f[1] {
        case "busy":
            guard f.count >= 3, let pid = Int(f[2]) else { return nil }
            return (tab, .busy(pid: pid, commandLine: f.count > 3 ? f[3].trimmingCharacters(in: .whitespaces) : ""))
        case "idle": return (tab, .idle)
        case "gone": return (tab, .gone)
        default: return nil
        }
    }
}

/// Everything about running commands on one host, done once for all its terminals:
///
/// - one watcher on the host (`commandWatch`) for every terminal's shell, which says at once when a
///   command starts or ends — idle terminals then cost nothing, and short commands are still seen;
/// - one look (`command`) per round for every terminal that wants one, sharing what is read from
///   the host (processes, sockets, counters) between them.
///
/// Nothing is left on the host: the watcher writes a heartbeat and ends when nobody reads it (or
/// is stopped with its stream), looks are single commands. Without terminals the hub is idle.
@MainActor
public final class CommandHub {
    private let executor: RemoteExecutor
    private var samplers: [UUID: CommandSampler] = [:]
    private var loop: Task<Void, Never>?
    private var nap: Task<Void, Never>?

    /// Settings (Settings ▸ Monitoring): the watcher, how often it checks, how often to look.
    public var watchEnabled = true { didSet { if watchEnabled != oldValue { restartWatcher() } } }
    public var watchInterval: TimeInterval = 0.5 { didSet { if watchInterval != oldValue { restartWatcher() } } }

    /// No Tether window is visible: the watcher goes on (it costs nothing while commands are idle,
    /// and keeps the history's starts and ends right), looks at running commands only every 15 s.
    public var backgrounded = false
    private var lastLook: Date?

    private var watcher: RemoteStream?
    /// The terminals the running watcher reports on, by its tab numbers.
    private var watched: [UUID] = []
    private var watchedAnchors: [ShellAnchor] = []
    private var watcherRetryAt: Date?
    private var anchorsRefreshedAt: Date?

    public init(executor: RemoteExecutor) {
        self.executor = executor
    }

    public func register(_ sampler: CommandSampler) {
        samplers[sampler.id] = sampler
        sampler.hub = self
        samplerChanged(sampler)
    }

    func unregister(_ sampler: CommandSampler) {
        samplers[sampler.id] = nil
        if samplers.values.allSatisfy({ !$0.isOnline }) { stop() } else { wake() }
    }

    /// A terminal went on- or offline or its foreground changed: look soon, keep the watcher's list
    /// current (the anchors are asked again only when the set of online terminals changed).
    func samplerChanged(_ sampler: CommandSampler, onlineChanged: Bool = true) {
        if onlineChanged { anchorsRefreshedAt = nil }
        if samplers.values.contains(where: \.isOnline) { start() } else { stop() }
        wake()
    }

    /// Cuts the current wait short (a command started, a view opened).
    public func wake() { nap?.cancel() }

    /// Starts again after `stop()` if a terminal is online (the Mac woke up).
    public func resume() {
        if samplers.values.contains(where: \.isOnline) { start() }
    }

    /// Ends the loop and the watcher (no terminals left online, the Mac goes to sleep, the app quits).
    public func stop() {
        loop?.cancel()
        loop = nil
        nap?.cancel()
        stopWatcher()
    }

    private func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.round()
                await self.pause()
            }
        }
    }

    /// Waits until the next terminal is due (at most a second, so changes are noticed), or a wake.
    private func pause() async {
        let now = Date()
        let online = samplers.values.filter(\.isOnline)
        guard !online.isEmpty else { stop(); return }
        let t = Task<Void, Never> { try? await Task.sleep(for: .seconds(1)) }
        nap = t
        if !online.contains(where: { $0.isDue(at: now) }) { await t.value }
        nap = nil
    }

    // MARK: Looking

    private func round() async {
        await keepWatcherCurrent()
        let now = Date()
        if backgrounded, let lastLook, now.timeIntervalSince(lastLook) < 15 { return }
        let due = samplers.values.filter { $0.isOnline && $0.isDue(at: now) }
        guard !due.isEmpty else { return }
        lastLook = now
        var anchors: [ShellAnchor] = []
        var asked: [(CommandSampler, CommandSampler.LookToken)] = []
        for s in due {
            guard let a = await s.anchorForLook() else { s.noAnchor(); continue }
            anchors.append(a)
            asked.append((s, s.lookToken))
        }
        guard !anchors.isEmpty else { return }
        let r = await executor.run(RemoteScript(ProbeScripts.command, windows: WindowsProbeScripts.command),
                                   arguments: anchors.flatMap(\.probeArguments), timeout: 20, purpose: "monitor")
        guard r.succeeded else {
            let errors = DiagnosticLog.tail(r.errorOutput)
            let why = r.timedOut ? "The host did not answer within 20 s." : r.status == 255
                ? "Could not reach the host. " + errors : "The look at the running commands failed (exit \(r.status)). " + errors
            asked.forEach { $0.0.lookFailed(why) }
            return
        }
        let frames = ProbeParser.commandBatch(r.output, anchors: anchors)
        let errors = DiagnosticLog.tail(r.errorOutput)
        for ((s, token), frame) in zip(asked, frames) { s.took(frame, token: token, stderr: errors) }
    }

    // MARK: Watcher

    /// Starts, restarts or stops the watcher so it covers exactly the online terminals.
    private func keepWatcherCurrent() async {
        let online = samplers.values.filter(\.isOnline).sorted { $0.id.uuidString < $1.id.uuidString }
        guard watchEnabled, !online.isEmpty else { stopWatcher(); return }
        if let retry = watcherRetryAt, Date() < retry { return }
        // Anchors of idle terminals too (tmux is asked; plain shells know theirs): every 30 s or after a change.
        if anchorsRefreshedAt == nil || Date().timeIntervalSince(anchorsRefreshedAt!) > 30 {
            for s in online { _ = await s.resolveAnchor() }
            anchorsRefreshedAt = Date()
        }
        let covered = online.filter { $0.knownAnchor != nil }
        let anchors = covered.compactMap(\.knownAnchor)
        if watcher != nil && anchors == watchedAnchors && covered.map(\.id) == watched { return }
        stopWatcher()
        guard !anchors.isEmpty else { return }
        guard await executor.backgroundWorkAllowed() else { return }
        let platform = await executor.resolvedPlatform(quiet: true)
        let s = RemoteStream(separator: "\n")
        watched = covered.map(\.id)
        watchedAnchors = anchors
        // Lines still queued from a watcher that was replaced would map to the new tab list: dropped.
        s.onRecord = { [weak self] line in
            guard let self, self.watcher === s else { return }
            self.watcherSaid(line)
        }
        s.onEnd = { [weak self] status, err in
            guard let self, self.watcher === s else { return }
            self.watcher = nil
            self.watched = []
            self.watchedAnchors = []
            if err.contains(RemoteExecutor.deviceMessage) { self.watcherRetryAt = Date().addingTimeInterval(600); return }
            // Ended on its own (the host has no sh features it needs, or it failed): looks go on as
            // before; tried again in a minute.
            self.watcherRetryAt = Date().addingTimeInterval(60)
            for sampler in self.samplers.values { sampler.watched(.gone) }
            if status != 0 && status != 15 {
                let why = "The command watcher stopped (exit \(status)). " + DiagnosticLog.tail(err)
                self.samplers.values.forEach { $0.note(why) }
            }
            self.wake()
        }
        watcher = s
        let args = platform.isWindows ? anchors.flatMap(\.probeArguments)
            : ["-i", Self.format(watchInterval)] + anchors.flatMap(\.probeArguments)
        s.start(executor: executor, script: RemoteScript(ProbeScripts.commandWatch, windows: WindowsProbeScripts.commandWatch),
                platform: platform, arguments: args, purpose: "monitor")
    }

    private func watcherSaid(_ line: String) {
        guard let (tab, event) = WatchEvent.parse(line), tab < watched.count, let s = samplers[watched[tab]] else { return }
        s.watched(event)
        if event == .gone { anchorsRefreshedAt = nil }
        wake()
    }

    private func stopWatcher() {
        watcher?.stop()
        // Its news no longer holds: those terminals are looked at by their own schedule again.
        for id in watched { samplers[id]?.watcherStopped() }
        watcher = nil
        watched = []
        watchedAnchors = []
    }

    private func restartWatcher() {
        stopWatcher()
        watcherRetryAt = nil
        wake()
    }

    static func format(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
    }
}
