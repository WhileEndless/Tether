import Foundation
import Observation
import CryptoKit

/// Lowest, highest and time-weighted average of one measurement over a command's run.
public struct MetricSummary: Codable, Hashable, Sendable {
    public var min: Double
    public var max: Double
    public var mean: Double
    /// Seconds the mean is weighted over.
    public var seconds: Double
    public var samples: Int

    public init(_ value: Double) {
        min = value
        max = value
        mean = value
        seconds = 0
        samples = 1
    }

    /// Adds a reading that stood for `weight` seconds.
    public mutating func add(_ value: Double, weight: Double) {
        min = Swift.min(min, value)
        max = Swift.max(max, value)
        samples += 1
        let w = Swift.max(weight, 0)
        if seconds + w > 0 { mean = (mean * seconds + value * w) / (seconds + w) }
        seconds += w
    }

    static func adding(_ value: Double?, to summary: MetricSummary?, weight: Double) -> MetricSummary? {
        guard let value, value.isFinite else { return summary }
        guard var summary else { return MetricSummary(value) }
        summary.add(value, weight: weight)
        return summary
    }
}

/// One reading of a running command, computed from two looks (`CommandSampler`).
public struct CommandSample: Identifiable, Hashable, Sendable {
    public var date: Date
    /// Percent of one CPU core (several busy cores go above 100).
    public var cpu: Double?
    public var memory: Int64?
    public var threads: Int?
    public var processes: Int
    /// Bytes per second.
    public var received: Double?
    public var sent: Double?
    public var read: Double?
    public var written: Double?
    public var id: Date { date }

    public init(date: Date, cpu: Double? = nil, memory: Int64? = nil, threads: Int? = nil, processes: Int = 1,
                received: Double? = nil, sent: Double? = nil, read: Double? = nil, written: Double? = nil) {
        self.date = date
        self.cpu = cpu
        self.memory = memory
        self.threads = threads
        self.processes = processes
        self.received = received
        self.sent = sent
        self.read = read
        self.written = written
    }
}

/// A command that ran in one of Tether's terminals: what, where, how long and how much it used.
public struct CommandRecord: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case running
        case finished
        /// It ended while the terminal was disconnected: some time between `lastSeen` and `endedBefore`.
        case endedWhileDisconnected
        /// Its terminal was closed (or Tether quit and the session did not come back) while it ran.
        case trackingStopped
    }

    /// A point of the usage graph: seconds since start, CPU percent, memory in bytes.
    /// Stored as a short array `[t, cpu, memory]` (rounded), not an object: a long history keeps
    /// thousands of them.
    public struct Point: Codable, Hashable, Sendable {
        public var t: Double
        public var cpu: Double?
        public var memory: Double?

        public init(t: Double, cpu: Double?, memory: Double?) {
            self.t = t
            self.cpu = cpu
            self.memory = memory
        }

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            t = try c.decode(Double.self)
            cpu = try c.decodeIfPresent(Double.self)
            memory = c.isAtEnd ? nil : try c.decodeIfPresent(Double.self)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode((t * 10).rounded() / 10)
            try c.encode(cpu.map { ($0 * 10).rounded() / 10 })
            try c.encode(memory.map { $0.rounded() })
        }
    }

    public var id: UUID
    public var hostKey: String
    public var hostName: String
    public var sessionID: UUID
    public var sessionTitle: String
    /// With secrets masked (`CommandRedactor`).
    public var commandLine: String
    public var pid: Int
    /// When the process started (the host's report, on this Mac's clock).
    public var started: Date
    /// The start on the host's clock, to recognize the process after a reconnect.
    public var hostStarted: Double?
    public var lastSeen: Date
    public var ended: Date?
    /// Latest possible end, when it ended unseen.
    public var endedBefore: Date?
    public var status: Status
    /// Time the terminal was disconnected while the command ran (no readings then).
    public var disconnectedSeconds: Double = 0

    public var cpu: MetricSummary?
    public var memory: MetricSummary?
    public var threads: MetricSummary?
    public var processes: MetricSummary?
    public var received: MetricSummary?
    public var sent: MetricSummary?
    public var read: MetricSummary?
    public var written: MetricSummary?
    /// Totals in bytes (rate × time), where rates were known.
    public var receivedBytes: Double?
    public var sentBytes: Double?
    public var readBytes: Double?
    public var writtenBytes: Double?
    public var series: [Point] = []
    /// The processes it ran and the connections it had (when kept, see `CommandSampler.keepDetails`).
    public var processList: [ProcessSummary]?
    public var connectionList: [ConnectionSummary]?
    /// Processes not kept because the list was full.
    public var droppedProcesses: Int?
    /// Connections were left out because the list was full.
    public var moreConnections: Bool?
    /// When the details were last added to (to tell new processes from known ones).
    var detailsAt: Date?
    /// Seen only by the watcher: it ended before a look could measure it (command line and time only).
    public var short: Bool?

    public var duration: TimeInterval { max((ended ?? lastSeen).timeIntervalSince(started), 0) }
    public var isRunning: Bool { status == .running }

    /// Executable name without path or arguments.
    public var name: String {
        CommandProcess.programName(commandLine)
    }

    public static let maxPoints = 120

    /// Adds a reading that stood for `weight` seconds.
    mutating func add(_ sample: CommandSample, weight: Double) {
        lastSeen = max(lastSeen, sample.date)
        cpu = MetricSummary.adding(sample.cpu, to: cpu, weight: weight)
        memory = MetricSummary.adding(sample.memory.map(Double.init), to: memory, weight: weight)
        threads = MetricSummary.adding(sample.threads.map(Double.init), to: threads, weight: weight)
        processes = MetricSummary.adding(Double(sample.processes), to: processes, weight: weight)
        received = MetricSummary.adding(sample.received, to: received, weight: weight)
        sent = MetricSummary.adding(sample.sent, to: sent, weight: weight)
        read = MetricSummary.adding(sample.read, to: read, weight: weight)
        written = MetricSummary.adding(sample.written, to: written, weight: weight)
        func total(_ rate: Double?, _ sum: Double?) -> Double? { rate.map { (sum ?? 0) + $0 * weight } ?? sum }
        receivedBytes = total(sample.received, receivedBytes)
        sentBytes = total(sample.sent, sentBytes)
        readBytes = total(sample.read, readBytes)
        writtenBytes = total(sample.written, writtenBytes)
        series.append(Point(t: sample.date.timeIntervalSince(started), cpu: sample.cpu, memory: sample.memory.map(Double.init)))
        if series.count > Self.maxPoints { series = Self.halve(series) }
    }

    /// Merges neighbouring points (keeping the peaks), so long runs keep a graph of fixed size.
    static func halve(_ points: [Point]) -> [Point] {
        stride(from: 0, to: points.count, by: 2).map { i in
            guard i + 1 < points.count else { return points[i] }
            let a = points[i], b = points[i + 1]
            func peak(_ x: Double?, _ y: Double?) -> Double? { [x, y].compactMap { $0 }.max() }
            return Point(t: b.t, cpu: peak(a.cpu, b.cpu), memory: peak(a.memory, b.memory))
        }
    }
}

/// The command history: on this Mac only, one file per host, optionally encrypted (`Codec`).
///
/// Running commands are written now and then (and at every start, end and disconnect), so a crash
/// loses little. A file that cannot be opened is never overwritten: while it is locked (encrypted,
/// Tether locked) new records wait in memory and are merged when `reload()` succeeds; a damaged
/// file is moved aside under a free name.
@MainActor
@Observable
public final class CommandHistoryStore {
    /// How files are sealed and opened (encryption lives in the app, see `RecordingKit.SealedData`).
    public struct Codec: Sendable {
        public enum Opened: Sendable { case data(Data), locked, unreadable }
        public var seal: @Sendable (Data) -> Data?
        public var open: @Sendable (Data) -> Opened
        public init(seal: @escaping @Sendable (Data) -> Data?, open: @escaping @Sendable (Data) -> Opened) {
            self.seal = seal
            self.open = open
        }
        public static let plain = Codec(seal: { $0 }, open: { .data($0) })
    }

    /// Newest first, all hosts.
    public private(set) var records: [CommandRecord] = []
    /// Some host's file could not be opened yet (Tether is locked).
    public private(set) var isLocked = false
    /// Files that could not be written or read, for the user to inspect.
    public private(set) var diagnostics = DiagnosticLog()

    public func clearDiagnostics() { diagnostics.clear() }

    /// Bytes the history takes on disk (all hosts, as written).
    public private(set) var storageBytes = 0
    /// The oldest finished records go when the files together would grow beyond this.
    public var maxTotalBytes = 50 * 1_048_576
    @ObservationIgnored private var fileSizes: [String: Int] = [:] {
        didSet { storageBytes = fileSizes.values.reduce(0, +) }
    }

    /// Keep finished records this many days (0 = only the per-host limit applies).
    public var retentionDays = 90
    public var maxRecordsPerHost = 500

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let codec: Codec
    /// Names of files that are locked: not written until opened.
    @ObservationIgnored private var lockedFiles: Set<String> = []
    /// Of `lockedFiles`, those encrypted with a key that is not loaded (rather than unreadable).
    @ObservationIgnored private var sealedFiles: Set<String> = []
    @ObservationIgnored private var dirty: Set<String> = []
    /// While a host's file cannot be opened (Tether locked), what is recorded for it meanwhile is
    /// written next to it, `<file>.pending-<run>.json`, one per run of the app; once the file opens,
    /// they are merged into it and removed. So nothing waits in memory only.
    @ObservationIgnored private let runID = String(UUID().uuidString.prefix(8)).lowercased()
    /// Pending files whose records were read into `records` (removed once their host is written).
    @ObservationIgnored private var mergedPending: Set<URL> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private let writer = DispatchQueue(label: "tether.command-history", qos: .utility)

    public init(directory: URL, codec: Codec = .plain) {
        self.directory = directory
        self.codec = codec
    }

    // MARK: Reading

    /// Readers never load (that changes `records`, which views observe): the app calls `load()`
    /// first, and everything that writes loads too.
    public func records(hostKey: String? = nil, sessionID: UUID? = nil) -> [CommandRecord] {
        return records.filter { (hostKey == nil || $0.hostKey == hostKey) && (sessionID == nil || $0.sessionID == sessionID) }
    }

    /// The record of the command still running in a terminal (as last seen), if any.
    public func running(sessionID: UUID) -> CommandRecord? {
        return records.first { $0.sessionID == sessionID && $0.isRunning }
    }

    public func record(_ id: UUID) -> CommandRecord? { records.first { $0.id == id } }

    // MARK: Writing

    /// Starts a record for a command first seen now.
    @discardableResult
    public func begin(hostKey: String, hostName: String, sessionID: UUID, sessionTitle: String, process: CommandProcess,
                      at date: Date, seenSince: Date? = nil) -> UUID {
        loadIfNeeded()
        let record = CommandRecord(id: UUID(), hostKey: hostKey, hostName: hostName, sessionID: sessionID, sessionTitle: sessionTitle,
                                   commandLine: CommandRedactor.redact(process.commandLine.isEmpty ? process.name : process.commandLine),
                                   pid: process.pid, started: min(process.started ?? date, date, seenSince ?? date), lastSeen: date,
                                   status: .running)
        var r = record
        r.hostStarted = process.hostStarted
        records.insert(r, at: 0)
        changed(hostKey, soon: true)
        return record.id
    }

    /// Keeps a command the watcher saw that ended before it could be measured.
    public func addShort(hostKey: String, hostName: String, sessionID: UUID, sessionTitle: String, pid: Int,
                         commandLine: String, started: Date, ended: Date) {
        loadIfNeeded()
        let line = commandLine.isEmpty ? "?" : commandLine
        var record = CommandRecord(id: UUID(), hostKey: hostKey, hostName: hostName, sessionID: sessionID, sessionTitle: sessionTitle,
                                   commandLine: CommandRedactor.redact(line), pid: pid, started: started, lastSeen: ended,
                                   status: .finished)
        record.ended = ended
        record.short = true
        records.insert(record, at: 0)
        changed(hostKey, soon: false)
    }

    /// Adds a reading to a running record.
    public func add(_ sample: CommandSample, to id: UUID, weight: Double) {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].isRunning else { return }
        records[i].add(sample, weight: weight)
        changed(records[i].hostKey, soon: false)
    }

    /// Adds the processes and connections one look saw (each part only when it is kept).
    public func addDetails(to id: UUID, processes: [CommandProcess]?, cpu: [Int: Double], connections: [ConnectionTraffic]?,
                           weight: Double, at date: Date) {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].isRunning else { return }
        if let processes { records[i].note(processes: processes, cpu: cpu, weight: weight, at: date) }
        if let connections { records[i].note(connections: connections, at: date) }
    }

    /// The terminal was disconnected for `seconds` while the command ran.
    public func addGap(_ seconds: Double, to id: UUID, until date: Date) {
        guard seconds > 0, let i = records.firstIndex(where: { $0.id == id }), records[i].isRunning else { return }
        records[i].disconnectedSeconds += seconds
        records[i].lastSeen = max(records[i].lastSeen, date)
        changed(records[i].hostKey, soon: true)
    }

    /// Ends a running record. `before` is the latest it can have ended, when it ended unseen.
    /// `at`: when it ended, if known (the watcher's news); otherwise when it was last seen.
    public func end(_ id: UUID, status: CommandRecord.Status, before: Date? = nil, at: Date? = nil) {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].isRunning else { return }
        records[i].status = status
        if let at, at > records[i].lastSeen { records[i].lastSeen = at }
        records[i].ended = records[i].lastSeen
        records[i].endedBefore = before
        changed(records[i].hostKey, soon: true)
    }

    /// Records left running by terminals that are not open any more (closed, or Tether quit and
    /// they were not restored) stop being tracked.
    public func stopTracking(exceptSessions open: Set<UUID>) {
        loadIfNeeded()
        for r in records where r.isRunning && !open.contains(r.sessionID) { end(r.id, status: .trackingStopped) }
    }

    public func delete(_ ids: Set<UUID>) {
        let hosts = Set(records.filter { ids.contains($0.id) }.map(\.hostKey))
        records.removeAll { ids.contains($0.id) }
        hosts.forEach { changed($0, soon: true) }
    }

    /// Removes everything (of one host, or all) that is not running right now.
    public func clear(hostKey: String? = nil) {
        loadIfNeeded()
        let gone = records.filter { !$0.isRunning && (hostKey == nil || $0.hostKey == hostKey) }
        delete(Set(gone.map(\.id)))
    }

    // MARK: Files

    /// The key of the encrypted files is gone for good (the Tether password was reset): they can
    /// never be opened, so they are removed and what was recorded since is written again.
    public func forgetEncryptedFiles() {
        for name in sealedFiles {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name + ".json"))
            fileSizes[name] = nil
        }
        lockedFiles.subtract(sealedFiles)
        sealedFiles = []
        isLocked = !lockedFiles.isEmpty
        for host in Set(records.map(\.hostKey)) { changed(host, soon: true) }
    }

    /// Reads files that could not be opened before (after unlocking), merging what was recorded meanwhile.
    public func reload() {
        guard loaded, !lockedFiles.isEmpty else { return }
        let waiting = lockedFiles
        lockedFiles = []
        sealedFiles = []
        for file in files() where waiting.contains(Self.name(of: file)) {
            guard let found = read(file) else { continue }
            if Self.isPending(file) { mergedPending.insert(file) }
            records = Self.unique(records + found)
        }
        records.sort { $0.started > $1.started }
        isLocked = !lockedFiles.isEmpty
        // Opened now: what was recorded meanwhile can be written together with what was there.
        let opened = Set(waiting.map { $0.prefix { $0 != "." } }.map(String.init))
        for host in Set(records.map(\.hostKey)) where opened.contains(Self.fileName(for: host)) && !lockedFiles.contains(Self.fileName(for: host)) {
            changed(host, soon: true)
        }
    }

    /// Writes every host's file again, e.g. after encryption was turned on or off, so no file stays
    /// in the old form. Locked files wait until they can be read.
    public func rewriteAll() {
        loadIfNeeded()
        Set(records.map(\.hostKey)).forEach { changed($0, soon: true) }
    }

    /// Writes everything changed now (at quit).
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        writeDirty()
        writer.sync {}
    }

    /// Reads the files (once; later calls do nothing). Readers load on first use too, but loading
    /// changes `records`, so the app does it before views look.
    public func load() { loadIfNeeded() }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        var all: [CommandRecord] = []
        for file in files() {
            guard let list = read(file) else { continue }
            all += list
            if Self.isPending(file) { mergedPending.insert(file) }
        }
        records = Self.unique(all).sorted { $0.started > $1.started }
        isLocked = !lockedFiles.isEmpty
    }

    /// One record per id (a pending file and its host's file may hold the same command): the one
    /// seen last.
    private static func unique(_ list: [CommandRecord]) -> [CommandRecord] {
        var best: [UUID: CommandRecord] = [:]
        for r in list where best[r.id].map({ $0.lastSeen < r.lastSeen }) ?? true { best[r.id] = r }
        return Array(best.values)
    }

    private static func isPending(_ file: URL) -> Bool { file.lastPathComponent.contains(".pending-") }

    /// The host file name a pending file belongs to.
    private static func owner(ofPending file: URL) -> String {
        String(file.lastPathComponent.prefix { $0 != "." })
    }

    private static func name(of file: URL) -> String { file.deletingPathExtension().lastPathComponent }

    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.contains(".unreadable") }
    }

    /// The records in `file`; nil when it is locked (the host is then not written until opened).
    private func read(_ file: URL) -> [CommandRecord]? {
        guard let data = try? Data(contentsOf: file) else {
            // Not readable now (permissions, a disk error): treated as locked, never overwritten.
            lockedFiles.insert(Self.name(of: file))
            diagnostics.add("A command history file could not be read; it is left as it is.", source: "history")
            return nil
        }
        fileSizes[Self.name(of: file)] = data.count
        switch codec.open(data) {
        case .locked:
            lockedFiles.insert(Self.name(of: file))
            sealedFiles.insert(Self.name(of: file))
            return nil
        case .unreadable:
            moveAside(file)
            return []
        case .data(let packed):
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let plain = Self.unpack(packed), let list = try? decoder.decode(HostFile.self, from: plain) else {
                moveAside(file)
                return []
            }
            return list.records
        }
    }

    private struct HostFile: Codable {
        var hostKey: String
        var records: [CommandRecord]
    }

    /// Files are compressed (lzfse) before they are sealed: the JSON shrinks to about a tenth.
    nonisolated static let packedMagic = Data("TCHZ1".utf8)

    nonisolated static func pack(_ json: Data) -> Data? {
        guard let z = try? (json as NSData).compressed(using: .lzfse) as Data else { return nil }
        return packedMagic + z
    }

    /// The JSON of a file: unpacked, or as it is when it was written uncompressed.
    nonisolated static func unpack(_ data: Data) -> Data? {
        guard data.starts(with: packedMagic) else { return data }
        return try? (Data(data.dropFirst(packedMagic.count)) as NSData).decompressed(using: .lzfse) as Data
    }

    /// File names are a hash of the host key: no host or user names on disk outside the contents.
    nonisolated static func fileName(for hostKey: String) -> String {
        SHA256.hash(data: Data(hostKey.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(_ hostKey: String) -> URL {
        directory.appendingPathComponent(Self.fileName(for: hostKey) + ".json")
    }

    /// A damaged file is kept (under a free name) instead of being overwritten.
    private func moveAside(_ file: URL) {
        let fm = FileManager.default
        let base = file.deletingPathExtension().lastPathComponent
        var n = 1
        var target = directory.appendingPathComponent("\(base).unreadable-\(n).json")
        while fm.fileExists(atPath: target.path) {
            n += 1
            target = directory.appendingPathComponent("\(base).unreadable-\(n).json")
        }
        do {
            try fm.moveItem(at: file, to: target)
            diagnostics.add("A damaged history file was kept as \(target.lastPathComponent) and a new one started.", source: "history")
        } catch {
            diagnostics.add("A damaged history file could not be moved aside: \(error.localizedDescription)", source: "history")
        }
    }

    private func changed(_ hostKey: String, soon: Bool) {
        dirty.insert(hostKey)
        if soon {
            saveTask?.cancel()
            saveTask = nil
        } else if saveTask != nil {
            return
        }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(soon ? 1 : 30))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.writeDirty()
        }
    }

    /// Encoding, compression and sealing run on the writer queue (a host's file can be large); only
    /// a snapshot of the records is taken here. The sizes come back afterwards: over the limit, the
    /// oldest finished records go and the files are written again.
    private func writeDirty() {
        let hosts = dirty
        dirty = []
        guard !hosts.isEmpty else { return }
        prune()
        // A host whose file cannot be opened now gets this run's pending file instead (never the
        // file itself); one that can is written whole, and its merged pending files go.
        let snapshot = hosts.map { host -> (host: String, list: [CommandRecord], url: URL, pending: Bool, merged: [URL]) in
            let name = Self.fileName(for: host)
            let pending = lockedFiles.contains(name)
            let url = directory.appendingPathComponent(pending ? "\(name).pending-\(runID).json" : name + ".json")
            let merged = pending ? [] : mergedPending.filter { Self.owner(ofPending: $0) == name && $0 != url }
            return (host, records.filter { $0.hostKey == host }, url, pending, Array(merged))
        }
        let dir = directory
        let codec = self.codec
        writer.async { [weak self] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var sizes: [String: Int?] = [:]   // nil: nothing written (not sealable now)
            var removed: [URL] = []
            var pendingWritten: [URL] = []
            var failures: [String] = []
            for (host, list, url, pending, merged) in snapshot {
                do {
                    guard !list.isEmpty else {
                        if !pending {
                            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                            for file in merged where (try? FileManager.default.removeItem(at: file)) != nil { removed.append(file) }
                        }
                        sizes[host] = .some(0)
                        continue
                    }
                    guard let json = try? encoder.encode(HostFile(hostKey: host, records: list)), let packed = Self.pack(json) else {
                        failures.append("The command history of a host could not be encoded.")
                        continue
                    }
                    // Not sealable now (encryption on, Tether locked): kept in memory, written later.
                    guard let sealed = codec.seal(packed) else { sizes[host] = .some(nil); continue }
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    try sealed.write(to: url, options: [.atomic])
                    sizes[host] = pending ? .some(0) : .some(sealed.count)
                    if pending { pendingWritten.append(url) }
                    // Everything they held is in the file now.
                    for file in merged where (try? FileManager.default.removeItem(at: file)) != nil { removed.append(file) }
                } catch {
                    failures.append("The command history could not be saved: \(error.localizedDescription)")
                    sizes[host] = .some(nil)    // stays dirty: written again with the next change or at quit
                }
            }
            Task { @MainActor in self?.written(sizes, removed: removed, pending: pendingWritten, failures: failures) }
        }
    }

    /// After a write: the sizes are known; enforce the size limit.
    private func written(_ sizes: [String: Int?], removed: [URL] = [], pending: [URL] = [], failures: [String]) {
        failures.forEach { diagnostics.add($0, source: "history") }
        mergedPending.subtract(removed)
        // This run's pending files hold only records in memory: removed once their host is written.
        mergedPending.formUnion(pending)
        removed.forEach { fileSizes[Self.name(of: $0)] = nil }
        for (host, size) in sizes {
            if let size { fileSizes[Self.fileName(for: host)] = size == 0 ? nil : size } else { dirty.insert(host) }
        }
        // Files that cannot change now (locked, or waiting to be sealed) are not counted: removing
        // other hosts' records could never bring them down.
        let fixed = lockedFiles.union(dirty.map(Self.fileName(for:)))
        let total = fileSizes.filter { !fixed.contains($0.key) }.values.reduce(0, +)
        guard total > maxTotalBytes else { return }
        let finished = records.filter { !$0.isRunning && !fixed.contains(Self.fileName(for: $0.hostKey)) }
            .sorted { ($0.ended ?? $0.lastSeen) < ($1.ended ?? $1.lastSeen) }
        guard !finished.isEmpty else { return }
        // About the share that is too much (at least a tenth), oldest first.
        let share = min(max(Double(total - maxTotalBytes) / Double(total), 0.1), 1)
        let gone = finished.prefix(max(Int(Double(finished.count) * share), 1))
        let ids = Set(gone.map(\.id))
        records.removeAll { ids.contains($0.id) }
        Set(gone.map(\.hostKey)).forEach { changed($0, soon: true) }
    }

    /// Drops finished records past the retention time and beyond the per-host limit.
    private func prune() {
        let cutoff = retentionDays > 0 ? Date().addingTimeInterval(-Double(retentionDays) * 86_400) : nil
        var perHost: [String: Int] = [:]
        records = records.filter { r in
            if r.isRunning { return true }
            if let cutoff, (r.ended ?? r.lastSeen) < cutoff { return false }
            perHost[r.hostKey, default: 0] += 1
            return perHost[r.hostKey]! <= maxRecordsPerHost
        }
    }
}
