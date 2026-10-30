import Foundation
import Observation
import SSHTransport
import TetherCore

/// What runs in one terminal: its processes, CPU, memory, disk and network use, and its record in
/// the command history.
///
/// A sampler holds one terminal's state; its host's `CommandHub` does the looking — one watcher
/// and one batched look for all the host's terminals. The hub asks `isDue` and hands back frames
/// (`ingest`) and the watcher's news (`watched`). Idle terminals cost nothing: while the watcher
/// says the shell waits, nobody looks. A record survives disconnects: when the terminal comes back
/// and the same process (pid and start time) still runs, the record continues; when it is gone, it
/// ended while disconnected. Commands too short for a look are kept from the watcher's news alone.
@MainActor
@Observable
public final class CommandSampler {
    public enum Status: Equatable, Sendable {
        /// Not looked yet (or offline).
        case waiting
        /// The shell waits for input.
        case idle
        case running
        /// This terminal cannot tell (e.g. several screen windows, an old session).
        case unsupported(String)
        /// The last look failed.
        case unreachable(String)
    }

    /// Who the records belong to.
    public struct Context: Sendable {
        public var hostKey: String
        public var hostName: String
        public var sessionID: UUID
        public var sessionTitle: String
        public init(hostKey: String, hostName: String, sessionID: UUID, sessionTitle: String) {
            self.hostKey = hostKey
            self.hostName = hostName
            self.sessionID = sessionID
            self.sessionTitle = sessionTitle
        }
    }

    public private(set) var status: Status = .waiting {
        didSet { if status != .idle { idleSeenAt = nil } }
    }
    /// When the shell was last seen waiting at its prompt (the latest look, or the watcher's news);
    /// nil while something runs or it is not known.
    @ObservationIgnored public private(set) var idleSeenAt: Date?
    public private(set) var frame: CommandFrame?
    /// Readings of the current command (newest last), for the live graphs.
    public private(set) var samples: [CommandSample] = []
    /// Its history record, with the running min / average / peak.
    public private(set) var recordID: UUID?
    /// CPU percent of each of the command's processes at the last look.
    public private(set) var processCPU: [Int: Double] = [:]
    /// The command's connections, with their rates where the host counts them.
    public private(set) var connections: [ConnectionTraffic] = []
    /// Problems of the looks, for the user to inspect (never shown in the terminal).
    public private(set) var diagnostics = DiagnosticLog()

    public func clearDiagnostics() { diagnostics.clear() }
    public static let liveSamples = 60

    public var latest: CommandSample? { samples.last }
    public var record: CommandRecord? { recordID.flatMap { history?.record($0) } }

    /// Writes records (nil or `keepHistory` off: nothing is kept).
    @ObservationIgnored public var history: CommandHistoryStore?
    @ObservationIgnored public var keepHistory = true
    /// The running command is shown live (below the terminal): keep looking even without history.
    @ObservationIgnored public var showLive = true
    /// Also keep each command's processes / connections in its record.
    @ObservationIgnored public var keepProcesses = true
    @ObservationIgnored public var keepConnections = true
    /// Rates per process on the host, when its traffic stream runs (Linux with nethogs).
    @ObservationIgnored public var traffic: ProcessTraffic?

    @ObservationIgnored private let anchor: () async -> ShellAnchor?
    @ObservationIgnored private let context: () -> Context
    @ObservationIgnored private var online = false
    /// The foreground program's name from tmux (nil: cannot tell).
    @ObservationIgnored private var foreground: String?
    /// What tmux named while a look found the shell idle: the shell itself.
    @ObservationIgnored private var idleForeground: String?
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var previous: CommandFrame?
    @ObservationIgnored private var failures = 0
    /// After a reconnect, the open record still has to be matched against what runs now.
    @ObservationIgnored private var resumeChecked = false
    /// Changes whenever the terminal goes on- or offline: a look that started before is dropped.
    @ObservationIgnored private var epoch = 0
    /// Looks in a row that did not find the shell (one miss does not end a command).
    @ObservationIgnored private var misses = 0
    @ObservationIgnored private var frozen = false

    public init(anchor: @escaping () async -> ShellAnchor?, context: @escaping () -> Context) {
        self.anchor = anchor
        self.context = context
    }

    // MARK: Control (from the app)

    /// The terminal's state changed. `foreground` is tmux's name for the foreground program (nil: unknown).
    public func update(online: Bool, foreground: String?) {
        let cameOnline = online && !self.online
        let changed = online != self.online || foreground != self.foreground
        if online != self.online { epoch += 1 }
        self.online = online
        self.foreground = foreground
        if cameOnline { resumeChecked = false; previous = nil; idleForeground = nil; misses = 0; watchedBusy = nil }
        if !online {
            previous = nil
            watchedBusy = nil
            if status == .running || status == .idle { status = .waiting }
        }
        if foreground != nil, !cameOnline, changed { anchorStale = true }
        if changed { hub?.samplerChanged(self, onlineChanged: cameOnline || !online) }
    }

    /// A view shows this terminal's command details (faster looks, also while idle).
    public func watch() {
        watchers += 1
        hub?.wake()
    }

    public func unwatch() {
        watchers = max(watchers - 1, 0)
    }

    /// The terminal closed: a running record stops being tracked, a short one seen last is kept.
    public func close() {
        online = false
        endShortCommand(at: Date())
        if let recordID { history?.end(recordID, status: .trackingStopped) }
        recordID = nil
        hub?.unregister(self)
        hub = nil
    }

    // MARK: For the hub

    /// The host's hub (set when registered).
    @ObservationIgnored weak var hub: CommandHub?
    @ObservationIgnored let id = UUID()
    @ObservationIgnored private(set) var lastLookAt: Date?
    /// The anchor last asked for (the watcher needs every terminal's, also idle ones).
    @ObservationIgnored private(set) var knownAnchor: ShellAnchor?
    /// What the watcher said: busy (true), idle (false), nil while there is no watcher news.
    @ObservationIgnored private(set) var watchedBusy: Bool?
    @ObservationIgnored private var shortCommand: (pid: Int, commandLine: String, since: Date)?

    var isOnline: Bool { online }
    var currentEpoch: Int { epoch }

    /// Seconds between looks, set by the app (Settings ▸ Monitoring); faster while details show
    /// and right after a command appeared (its CPU and speeds need a second look).
    @ObservationIgnored public var lookInterval: TimeInterval = 3

    var interval: TimeInterval {
        if watchers > 0 || (status == .running && samples.count < 2) { return min(2, lookInterval) }
        // Without a watcher or tmux, a new command is only noticed by looking: not too seldom.
        return watchedBusy == nil && foreground == nil ? max(lookInterval, 5) : lookInterval
    }

    private var shouldLook: Bool {
        guard online, !frozen else { return false }
        if recordID != nil || !resumeChecked { return true }
        // The watcher tells when something runs: no looks while it says the shell waits.
        if let watchedBusy { return watchedBusy }
        if watchers > 0 { return true }
        guard showLive || (keepHistory && history != nil) else { return false }
        guard let foreground, let idleForeground else { return true }
        return foreground != idleForeground
    }

    /// Whether this terminal wants a look now (its interval passed, with a pause after failures).
    func isDue(at now: Date) -> Bool {
        guard shouldLook else { return false }
        guard let last = lastLookAt else { return true }
        let wait = failures > 0 ? min(interval * pow(2, Double(min(failures, 4))), 30) : interval
        return now.timeIntervalSince(last) >= wait - 0.05
    }

    /// The shell's anchor, asked fresh (tmux) and remembered for the watcher.
    func resolveAnchor() async -> ShellAnchor? {
        let a = await anchor()
        knownAnchor = a
        anchorAskedAt = Date()
        anchorStale = false
        return a
    }

    /// The anchor for a look: the remembered one while it is recent and nothing changed (a tmux
    /// pane switch shows as a foreground change), else asked fresh.
    func anchorForLook() async -> ShellAnchor? {
        if let known = knownAnchor, !anchorStale, let at = anchorAskedAt, Date().timeIntervalSince(at) < 30 { return known }
        return await resolveAnchor()
    }

    @ObservationIgnored private var anchorAskedAt: Date?
    @ObservationIgnored private var anchorStale = false

    /// Identifies what a look was asked for: a frame is dropped when the terminal went on- or offline,
    /// or the watcher said something, while the look ran (it would describe an older moment).
    struct LookToken: Equatable { var epoch: Int; var news: Int }
    @ObservationIgnored private var news = 0
    var lookToken: LookToken { LookToken(epoch: epoch, news: news) }

    /// The watcher stopped (turned off, or restarted for other terminals): its last news no longer holds.
    func watcherStopped() { watchedBusy = nil }

    /// The hub could not find this terminal's shell.
    func noAnchor() {
        lastLookAt = Date()
        let why = "This terminal does not tell which process is its shell (tmux did not answer, or the session started before this version)."
        status = .unsupported(why)
        diagnostics.add(why, source: "command")
        failures += 1   // looked at again later, less often
        resumeChecked = true
    }

    /// A problem of the host's watcher, kept with this terminal's diagnostics.
    func note(_ why: String) { diagnostics.add(why, source: "watcher") }

    /// The batched look failed for the whole host.
    func lookFailed(_ why: String) {
        lastLookAt = Date()
        failures += 1
        status = .unreachable(why)
        diagnostics.add(why, source: "command")
    }

    /// A frame from the hub's look (dropped when the terminal went off- or online meanwhile).
    func took(_ frame: CommandFrame, token: LookToken, stderr: String) {
        lastLookAt = Date()
        guard online, token == lookToken else { return }
        failures = 0
        // Output on stderr from a look that worked: kept, not shown (the scripts silence expected misses).
        if !stderr.isEmpty { diagnostics.add(stderr, source: "command") }
        frame.notes.forEach { diagnostics.add($0, source: "network") }
        ingest(frame)
    }

    /// News from the watcher: a program took the foreground (busy), the shell waits (idle), or the
    /// shell is gone. Busy and idle bring the next look forward.
    func watched(_ event: WatchEvent, at date: Date = Date()) {
        news += 1
        switch event {
        case .busy(let pid, let commandLine):
            endShortCommand(at: date)
            watchedBusy = true
            idleSeenAt = nil
            if let record, record.isRunning, record.pid == pid { break }
            // Another program took over: the one recorded ended now (more exact than its last look).
            finish(.finished, at: date)
            shortCommand = (pid, commandLine, date)
        case .idle:
            endShortCommand(at: date)
            finish(.finished, at: date)
            watchedBusy = false
            if online { idleSeenAt = date }
            // The watcher is sure: no look is needed to show that nothing runs.
            if online, status == .running || status == .waiting {
                status = .idle
                previous = nil
                samples = []
                processCPU = [:]
                connections = []
                if var f = frame { f.processes = []; f.sockets = []; frame = f }
            }
        case .gone:
            watchedBusy = nil
            knownAnchor = nil
        }
    }

    /// A command the watcher saw but no look caught (it ended first) is kept with what is known:
    /// its command line and how long it ran.
    private func endShortCommand(at date: Date) {
        guard let short = shortCommand else { return }
        shortCommand = nil
        guard keepHistory, let history else { return }
        let c = context()
        history.addShort(hostKey: c.hostKey, hostName: c.hostName, sessionID: c.sessionID, sessionTitle: c.sessionTitle,
                         pid: short.pid, commandLine: short.commandLine, started: short.since, ended: date)
    }

    func ingest(_ new: CommandFrame) {
        frame = new
        // History was turned off (or the tab is private): a record still open ends here.
        if !keepHistory, recordID != nil { finish(.trackingStopped) }
        if let problem = new.problem {
            let why = problem == .screenWindows
                ? "Several screen windows: which one is shown cannot be told."
                : "The shell of this terminal was not found on the host."
            status = .unsupported(why)
            diagnostics.add(why, source: "command")
            failures += 1
            misses += 1
            // One miss can be a hiccup; the second ends the command.
            if misses >= 2 {
                resumeChecked = true
                finish(.finished)
                previous = nil
            }
            return
        }
        misses = 0
        guard let leader = new.leader else {
            status = .idle
            idleSeenAt = new.takenAt
            idleForeground = foreground
            if !resumeChecked { resume(with: nil, at: new.takenAt) }
            finish(.finished)
            previous = nil
            samples = []
            processCPU = [:]
            connections = []
            return
        }
        status = .running
        if !resumeChecked { resume(with: leader, at: new.takenAt) }
        let same: Bool
        if let last = previous?.leader {
            same = Self.sameProcess(last, leader)
        } else if let record {
            // Continued after a reconnect (see `resume`).
            same = record.isRunning && Self.isRecorded(leader, in: record)
        } else {
            same = false
        }
        if !same {
            finish(.finished)
            samples = []
            previous = nil
            if keepHistory, let history {
                let c = context()
                // The watcher saw it start (to the half second): a better start than ps's whole seconds.
                let since = shortCommand?.pid == leader.pid ? shortCommand?.since : nil
                recordID = history.begin(hostKey: c.hostKey, hostName: c.hostName, sessionID: c.sessionID,
                                         sessionTitle: c.sessionTitle, process: leader, at: new.takenAt, seenSince: since)
            }
            if shortCommand?.pid == leader.pid { shortCommand = nil }
        }
        let rates = traffic?.rates(for: Set(new.processes.map(\.pid)))
        let sample = Self.sample(new, previous: previous, traffic: rates)
        processCPU = Self.cpuByProcess(new, previous: previous)
        connections = Self.connections(new, previous: previous)
        // The time since the previous look (also after a slower, backed-off one); a longer gap is a
        // disconnect, counted separately.
        let weight = previous.map { min(new.takenAt.timeIntervalSince($0.takenAt), 60) } ?? 0
        samples.append(sample)
        if samples.count > Self.liveSamples { samples.removeFirst(samples.count - Self.liveSamples) }
        if let recordID {
            history?.add(sample, to: recordID, weight: weight)
            if keepProcesses || keepConnections {
                history?.addDetails(to: recordID, processes: keepProcesses ? new.processes : nil, cpu: processCPU,
                                    connections: keepConnections ? connections : nil, weight: weight, at: new.takenAt)
            }
        }
        previous = new
    }

    /// First look after (re)connecting: continue the record left running when the same process
    /// still runs, otherwise close it — it ended while nobody could see it.
    /// Also after a reconnect within the same run (the record is then still this sampler's), and
    /// only while history is kept: a record left open while it was turned off just ends.
    private func resume(with leader: CommandProcess?, at date: Date) {
        resumeChecked = true
        guard let history else { return }
        guard let open = recordID.flatMap(history.record).flatMap({ $0.isRunning ? $0 : nil })
                ?? history.running(sessionID: context().sessionID) else {
            recordID = nil
            return
        }
        let gap = date.timeIntervalSince(open.lastSeen)
        let unseen = gap > max(interval * 3, 15)
        if keepHistory, let leader, Self.isRecorded(leader, in: open) {
            recordID = open.id
            if unseen { history.addGap(gap, to: open.id, until: date) }
        } else {
            history.end(open.id, status: unseen ? .endedWhileDisconnected : .finished, before: unseen ? date : nil)
            recordID = nil
        }
    }

    private func finish(_ status: CommandRecord.Status, at date: Date? = nil) {
        guard let recordID else { return }
        history?.end(recordID, status: status, at: date)
        self.recordID = nil
    }

    /// Same pid and start: on the host's clock when both are known (steady), else on this Mac's.
    nonisolated static func sameProcess(_ a: CommandProcess, _ b: CommandProcess) -> Bool {
        guard a.pid == b.pid else { return false }
        if let x = a.hostStarted, let y = b.hostStarted { return abs(x - y) < 3 }
        return sameStart(a.started, b.started)
    }

    /// Whether `record` is about this process (see `sameProcess`).
    static func isRecorded(_ p: CommandProcess, in record: CommandRecord) -> Bool {
        guard p.pid == record.pid else { return false }
        if let x = p.hostStarted, let y = record.hostStarted { return abs(x - y) < 3 }
        return sameStart(p.started, record.started)
    }

    /// Start times come from clocks read a little apart (and ps reports whole seconds).
    nonisolated static func sameStart(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return true }
        return abs(a.timeIntervalSince(b)) < 3
    }

    /// Usage between two looks at the same command. Processes that started after the previous look
    /// count with everything they used; processes that ended in between are gone from both.
    nonisolated static func sample(_ frame: CommandFrame, previous: CommandFrame?, traffic: ByteRates?) -> CommandSample {
        let procs = frame.processes
        var s = CommandSample(date: frame.takenAt, processes: procs.count)
        let rss = procs.compactMap(\.rssBytes)
        s.memory = rss.isEmpty ? nil : rss.reduce(0, +)
        let threads = procs.compactMap(\.threads)
        s.threads = threads.isEmpty ? nil : threads.reduce(0, +)
        s.received = traffic?.received
        s.sent = traffic?.sent
        guard let previous, case let dt = frame.takenAt.timeIntervalSince(previous.takenAt), dt > 0.2 else { return s }
        let before = Dictionary(previous.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        /// The growth of a counter of each process since the previous look, summed.
        func growth(_ value: (CommandProcess) -> Double?) -> Double? {
            let each = procs.compactMap { Self.growth(of: $0, before: before, since: previous.takenAt, value) }
            return each.isEmpty ? nil : each.reduce(0, +)
        }
        s.cpu = growth(\.cpuSeconds).map { $0 / dt * 100 }
        s.read = growth { $0.readBytes.map(Double.init) }.map { $0 / dt }
        s.written = growth { $0.writeBytes.map(Double.init) }.map { $0 / dt }
        // Network: process totals (macOS), else nethogs, else the connections' counters (Linux).
        let mine = Set(procs.map(\.pid))
        if !frame.networkBytes.isEmpty {
            // A process counts from its second look, or from its start when it started since.
            let counted = frame.networkBytes.filter { pid, _ in
                previous.networkBytes[pid] != nil || procs.first { $0.pid == pid }?.started.map { $0 >= previous.takenAt.addingTimeInterval(-1) } == true
            }
            let rates = FlowRates.processes(counted, previous: previous.networkBytes, seconds: dt).filter { mine.contains($0.key) }.values
            s.received = rates.map(\.received).reduce(0, +)
            s.sent = rates.map(\.sent).reduce(0, +)
        } else if traffic == nil, let rates = FlowRates.sockets(frame.socketCounters, previous: previous.socketCounters, seconds: dt,
                                                                isNew: startedSince(previous, in: frame)) {
            let each = FlowRates.perProcess(rates, sockets: frame.socketCounters).filter { mine.contains($0.key) }.values
            s.received = each.map(\.received).reduce(0, +)
            s.sent = each.map(\.sent).reduce(0, +)
        } else if traffic == nil, frame.measuresNetwork {
            s.received = 0
            s.sent = 0
        }
        return s
    }

    /// How much a counter of `p` grew since the previous look (`before` holds that look's
    /// processes): all of it for a process started since; nil when it cannot be told.
    nonisolated static func growth(of p: CommandProcess, before: [Int: CommandProcess], since: Date,
                                   _ value: (CommandProcess) -> Double?) -> Double? {
        guard let now = value(p) else { return nil }
        if let old = before[p.pid], sameProcess(old, p) {
            return value(old).map { max(now - $0, 0) }
        }
        if let started = p.started, started >= since.addingTimeInterval(-1) { return now }
        return nil
    }

    /// The command's connections: counted ones with rates since the previous look, plus listed ones.
    nonisolated static func connections(_ frame: CommandFrame, previous: CommandFrame?) -> [ConnectionTraffic] {
        let rates = previous.flatMap {
            FlowRates.sockets(frame.socketCounters, previous: $0.socketCounters, seconds: frame.takenAt.timeIntervalSince($0.takenAt),
                              isNew: startedSince($0, in: frame))
        }
        let names = Dictionary(frame.processes.map { ($0.pid, $0.name) }, uniquingKeysWith: { a, _ in a })
        return FlowRates.connections(counters: frame.socketCounters, rates: rates, listed: frame.sockets, names: names)
    }

    /// Whether a connection's process started since the previous look (its connections are then new).
    nonisolated static func startedSince(_ previous: CommandFrame, in frame: CommandFrame) -> (SocketCounter) -> Bool {
        let fresh = Set(frame.processes.filter { p in
            p.started.map { $0 >= previous.takenAt.addingTimeInterval(-1) } ?? false
        }.map(\.pid))
        return { fresh.contains($0.pid) }
    }

    /// CPU percent of each process between two looks (for the process list).
    nonisolated static func cpuByProcess(_ frame: CommandFrame, previous: CommandFrame?) -> [Int: Double] {
        guard let previous, case let dt = frame.takenAt.timeIntervalSince(previous.takenAt), dt > 0.2 else { return [:] }
        let before = Dictionary(previous.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [Int: Double] = [:]
        for p in frame.processes {
            if let used = growth(of: p, before: before, since: previous.takenAt, \.cpuSeconds) { result[p.pid] = used / dt * 100 }
        }
        return result
    }

    #if DEBUG
    /// Demo screenshots: a fixed command with prepared readings; the host is never contacted.
    public func loadDemo(frame: CommandFrame, samples: [CommandSample], recordID: UUID?, processCPU: [Int: Double] = [:],
                         connections: [ConnectionTraffic] = []) {
        frozen = true
        self.processCPU = processCPU
        self.connections = connections
        self.frame = frame
        self.samples = samples
        self.recordID = recordID
        status = frame.isIdle ? .idle : .running
    }
    #endif
}
