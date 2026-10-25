import Foundation
import Testing
import SSHTransport
import TetherCore
@testable import MonitorKit

/// The command history: min / average / peak, records across disconnects, files on disk.
@MainActor @Suite struct CommandHistoryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A private folder for one test, removed afterwards (also when the test fails).
    func withFolder(_ body: @MainActor (URL) throws -> Void) rethrows {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tether-ch-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    func process(_ pid: Int, started: Date, command: String = "make all") -> CommandProcess {
        CommandProcess(pid: pid, ppid: 1, started: started, commandLine: command)
    }

    @Test func summaryIsTimeWeighted() {
        var m = MetricSummary(10)
        m.add(10, weight: 1)
        m.add(40, weight: 3)
        #expect(m.min == 10 && m.max == 40)
        #expect(m.mean == 32.5)
        #expect(m.samples == 3)
    }

    @Test func seriesKeepsPeaksWithinLimit() {
        var r = CommandRecord(id: UUID(), hostKey: "h", hostName: "h", sessionID: UUID(), sessionTitle: "t", commandLine: "x",
                              pid: 1, started: now, lastSeen: now, status: .running)
        for i in 0..<500 {
            r.add(CommandSample(date: now.addingTimeInterval(Double(i)), cpu: i == 250 ? 900 : 10, memory: 1), weight: 1)
        }
        #expect(r.series.count <= CommandRecord.maxPoints)
        #expect(r.series.compactMap(\.cpu).max() == 900)
        #expect(r.cpu?.max == 900)
        #expect(r.duration == 499)
    }

    @Test func recordsSurviveAndCarryOn() throws {
        try withFolder { dir in
            let session = UUID()
            let store = CommandHistoryStore(directory: dir)
            let id = store.begin(hostKey: "web", hostName: "web", sessionID: session, sessionTitle: "web",
                                 process: process(10, started: now.addingTimeInterval(-5), command: "mysql -psecret db"), at: now)
            store.add(CommandSample(date: now.addingTimeInterval(2), cpu: 50, memory: 1000, received: 10), to: id, weight: 2)
            store.flush()

            // Another launch reads it back, still running, with the secret masked.
            let again = CommandHistoryStore(directory: dir)
            again.load()
            let r = try #require(again.running(sessionID: session))
            #expect(r.id == id)
            #expect(r.commandLine == "mysql -p\(CommandRedactor.mask) db")
            #expect(r.cpu?.mean == 50)
            #expect(r.receivedBytes == 20)
            #expect(r.started == now.addingTimeInterval(-5))

            again.stopTracking(exceptSessions: [])
            #expect(again.record(id)?.status == .trackingStopped)
            again.clear()
            #expect(again.records().isEmpty)
            again.flush()
            let empty = CommandHistoryStore(directory: dir)
            empty.load()
            #expect(empty.records().isEmpty)
        }
    }

    /// A locked file is never overwritten; what was recorded meanwhile is merged after unlocking.
    @Test func lockedFilesWait() {
        withFolder { dir in
            let unlocked = LockFlag()
            let codec = CommandHistoryStore.Codec(seal: { Data("SEALED".utf8) + $0 }, open: { data in
                guard data.starts(with: Data("SEALED".utf8)) else { return .data(data) }
                return unlocked.value ? .data(data.dropFirst(6)) : .locked
            })
            let first = CommandHistoryStore(directory: dir, codec: codec)
            let old = first.begin(hostKey: "db", hostName: "db", sessionID: UUID(), sessionTitle: "db", process: process(1, started: now), at: now)
            first.end(old, status: .finished)
            first.flush()

            let locked = CommandHistoryStore(directory: dir, codec: codec)
            locked.load()
            #expect(locked.records().isEmpty)
            #expect(locked.isLocked)
            let new = locked.begin(hostKey: "db", hostName: "db", sessionID: UUID(), sessionTitle: "db", process: process(2, started: now), at: now)
            locked.flush()
            unlocked.value = true
            locked.reload()
            #expect(!locked.isLocked)
            #expect(Set(locked.records().map(\.id)) == [old, new])
            locked.flush()
            let reread = CommandHistoryStore(directory: dir, codec: codec)
            reread.load()
            #expect(Set(reread.records().map(\.id)) == [old, new])
        }
    }

    /// A damaged file is moved aside under a free name, not overwritten.
    @Test func damagedFileIsKept() throws {
        try withFolder { dir in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = CommandHistoryStore.fileName(for: "web") + ".json"
            try Data("not json".utf8).write(to: dir.appendingPathComponent(name))
            let store = CommandHistoryStore(directory: dir)
            store.load()
            #expect(store.records().isEmpty)
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            #expect(files.contains { $0.contains(".unreadable-1") })
        }
    }

    /// After a reconnect the same process continues its record; a different one closes it.
    @Test func samplerResumesAcrossDisconnects() throws {
        try withFolder { dir in
            let store = CommandHistoryStore(directory: dir)
            let session = UUID()
            @MainActor func sampler() -> CommandSampler {
                let s = CommandSampler(anchor: { nil }) {
                    CommandSampler.Context(hostKey: "web", hostName: "web", sessionID: session, sessionTitle: "web")
                }
                s.history = store
                return s
            }
            let started = now.addingTimeInterval(-10)
            func frame(_ at: Date, pid: Int = 10, cpu: Double = 1) -> CommandFrame {
                var f = CommandFrame(takenAt: at, shellPid: 1)
                f.processes = [CommandProcess(pid: pid, ppid: 1, cpuSeconds: cpu, rssBytes: 100, started: pid == 10 ? started : at)]
                return f
            }
            let a = sampler()
            a.ingest(frame(now))
            a.ingest(frame(now.addingTimeInterval(2), cpu: 2))
            let id = try #require(a.recordID)

            // Disconnected for a minute; the same process still runs.
            let b = sampler()
            b.ingest(frame(now.addingTimeInterval(62), cpu: 3))
            #expect(b.recordID == id)
            #expect((store.record(id)?.disconnectedSeconds ?? 0) >= 59)
            b.ingest(frame(now.addingTimeInterval(64), cpu: 5))
            #expect(store.record(id)?.cpu?.max == 100)

            // Disconnected again; afterwards something else runs: the old one ended unseen.
            let c = sampler()
            c.ingest(frame(now.addingTimeInterval(200), pid: 11))
            #expect(store.record(id)?.status == .endedWhileDisconnected)
            #expect(store.record(id)?.endedBefore == now.addingTimeInterval(200))
            #expect(c.recordID != id && c.recordID != nil)
            // The shell is idle again: finished.
            let newID = try #require(c.recordID)
            c.ingest(CommandFrame(takenAt: now.addingTimeInterval(203), shellPid: 1))
            #expect(store.record(newID)?.status == .finished)
            #expect(c.status == .idle)
        }
    }

    /// Files are compressed, graph points are short arrays, and old (uncompressed) files still read.
    @Test func compactStorage() throws {
        let p = CommandRecord.Point(t: 1.234, cpu: 12.345, memory: 1000.4)
        let json = try JSONEncoder().encode(p)
        #expect(String(decoding: json, as: UTF8.self) == "[1.2,12.3,1000]")
        let back = try JSONDecoder().decode(CommandRecord.Point.self, from: Data("[5,null,null]".utf8))
        #expect(back.t == 5 && back.cpu == nil && back.memory == nil)
        let text = Data(String(repeating: "{\"records\":[]}", count: 200).utf8)
        let packed = try #require(CommandHistoryStore.pack(text))
        #expect(packed.count < text.count / 5)
        #expect(CommandHistoryStore.unpack(packed) == text)
        #expect(CommandHistoryStore.unpack(text) == text)
    }

    /// Over the size limit, the oldest finished commands go first; running ones stay.
    @Test func sizeLimitDropsOldest() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tether-ch-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let store = CommandHistoryStore(directory: dir)
            store.maxTotalBytes = 3_000
            let running = store.begin(hostKey: "web", hostName: "web", sessionID: UUID(), sessionTitle: "web",
                                      process: process(1, started: now), at: now)
            var ids: [UUID] = []
            for i in 0..<60 {
                let at = now.addingTimeInterval(Double(i) * 10)
                let id = store.begin(hostKey: i % 2 == 0 ? "web" : "db", hostName: "h", sessionID: UUID(), sessionTitle: "t",
                                     process: process(100 + i, started: at, command: "job \(UUID().uuidString)"), at: at)
                for k in 0..<30 {
                    store.add(CommandSample(date: at.addingTimeInterval(Double(k)), cpu: Double((k * 37 + i) % 100), memory: Int64(k * 4096 + i)),
                              to: id, weight: 1)
                }
                store.end(id, status: .finished)
                ids.append(id)
            }
            // Sizes are known after each write; over the limit, the oldest go and files are written again.
            for _ in 0..<30 {
                store.flush()
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(store.storageBytes <= 3_000)
            #expect(store.record(running) != nil)
            #expect(store.record(ids.last!) != nil)
            #expect(store.record(ids.first!) == nil)
        }
    }

    /// The processes and connections of a command are kept (up to a limit) with their peaks.
    @Test func detailsAreKept() {
        var r = CommandRecord(id: UUID(), hostKey: "h", hostName: "h", sessionID: UUID(), sessionTitle: "t", commandLine: "make",
                              pid: 1, started: now, lastSeen: now, status: .running)
        let a = CommandProcess(pid: 1, ppid: 0, rssBytes: 100, started: now, commandLine: "make --token=abc")
        r.note(processes: [a], cpu: [1: 10], weight: 2, at: now.addingTimeInterval(2))
        var b = a
        b.rssBytes = 300
        r.note(processes: [b], cpu: [1: 50], weight: 2, at: now.addingTimeInterval(4))
        #expect(r.processList?.count == 1)
        #expect(r.processList?.first?.cpu?.max == 50 && r.processList?.first?.memoryPeak == 300)
        #expect(r.processList?.first?.commandLine == "make --token=\(CommandRedactor.mask)")
        let many = (0..<80).map { CommandProcess(pid: 100 + $0, ppid: 1, started: now.addingTimeInterval(5), commandLine: "cc") }
        r.note(processes: many, cpu: [:], weight: 2, at: now.addingTimeInterval(6))
        #expect(r.processList?.count == CommandRecord.maxDetails)
        #expect(r.droppedProcesses == 80 - (CommandRecord.maxDetails - 1))
        r.note(processes: many, cpu: [:], weight: 2, at: now.addingTimeInterval(8))
        #expect(r.droppedProcesses == 80 - (CommandRecord.maxDetails - 1))   // not counted twice

        let c = ConnectionTraffic(proto: "TCP", state: "ESTAB", local: "192.0.2.1:5000", peer: "192.0.2.2:443", pid: 1,
                                  processName: "make", received: 100, sent: 10, receivedBytes: 1000, sentBytes: 50)
        r.note(connections: [c], at: now)
        var c2 = c
        c2.received = 900
        c2.receivedBytes = 5000
        r.note(connections: [c2], at: now.addingTimeInterval(2))
        #expect(r.connectionList?.count == 1)
        #expect(r.connectionList?.first?.peakReceived == 900 && r.connectionList?.first?.receivedBytes == 5000)
        #expect(r.connectionList?.first?.service == "HTTPS")
    }

    @Test func exportFormats() throws {
        var r = CommandRecord(id: UUID(), hostKey: "h", hostName: "web, eu", sessionID: UUID(), sessionTitle: "t",
                              commandLine: "=cmd \"quoted\"", pid: 7, started: now, lastSeen: now.addingTimeInterval(90), status: .finished)
        r.add(CommandSample(date: now.addingTimeInterval(2), cpu: 12.5, memory: 2048), weight: 2)
        let csv = String(decoding: MonitorExport.history([r], format: .csv), as: UTF8.self)
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines[0].hasPrefix("started,ended,duration_s,status,host,tab,pid,command"))
        #expect(lines[1].contains("\"web, eu\""))
        #expect(lines[1].contains("\"'=cmd \"\"quoted\"\"\""))   // quoted, and never a formula
        #expect(lines[1].contains(",90,finished,"))
        #expect(lines[1].contains(",12.50,12.50,12.50,"))
        let json = MonitorExport.history([r], format: .json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(MonitorExport.HistoryFile.self, from: json)
        #expect(file.format == "tether-command-history" && file.records.first?.id == r.id)
        let conn = String(decoding: MonitorExport.connections([ConnectionTraffic(proto: "TCP", state: "ESTAB", local: "192.0.2.1:1",
                                                                                   peer: "192.0.2.2:443", pid: 3, processName: "curl")]), as: UTF8.self)
        #expect(conn.contains("3,curl,TCP,ESTAB,192.0.2.1:1,192.0.2.2:443,HTTPS"))
    }

    /// Commands the watcher saw but no look caught are kept with their command line and duration;
    /// one a look caught is not kept twice.
    @Test func shortCommandsFromTheWatcher() throws {
        try withFolder { dir in
            let store = CommandHistoryStore(directory: dir)
            let session = UUID()
            let s = CommandSampler(anchor: { nil }) {
                CommandSampler.Context(hostKey: "web", hostName: "web", sessionID: session, sessionTitle: "web")
            }
            s.history = store
            s.update(online: true, foreground: nil)
            s.watched(.busy(pid: 40, commandLine: "curl -u user:hunter2 https://example.com"), at: now)
            s.watched(.idle, at: now.addingTimeInterval(1.5))
            let short = try #require(store.records().first)
            #expect(short.short == true && short.status == .finished)
            #expect(short.duration == 1.5)
            #expect(short.commandLine == "curl -u user:\(CommandRedactor.mask) https://example.com")

            // Caught by a look: one record, not a short one as well.
            s.watched(.busy(pid: 50, commandLine: "make"), at: now.addingTimeInterval(10))
            var f = CommandFrame(takenAt: now.addingTimeInterval(11), shellPid: 1)
            f.processes = [CommandProcess(pid: 50, ppid: 1, started: now.addingTimeInterval(10), commandLine: "make")]
            s.took(f, token: s.lookToken, stderr: "")
            s.watched(.idle, at: now.addingTimeInterval(12))
            #expect(store.records().count == 2)
            #expect(store.records().first?.short == nil)

            // Private tabs and history off: nothing kept.
            s.keepHistory = false
            s.watched(.busy(pid: 60, commandLine: "ls"), at: now.addingTimeInterval(20))
            s.watched(.idle, at: now.addingTimeInterval(21))
            #expect(store.records().count == 2)
        }
    }

    @Test func redaction() {
        let r = CommandRedactor.redact
        let m = CommandRedactor.mask
        #expect(r("curl -H 'Authorization: Bearer abc.def' https://user:pw@example.com/x")
            == "curl -H 'Authorization: Bearer \(m)' https://user:\(m)@example.com/x")
        #expect(r("deploy --password=hunter2 --token abc") == "deploy --password=\(m) --token \(m)")
        #expect(r("GITHUB_TOKEN=ghp_1 make") == "GITHUB_TOKEN=\(m) make")
        #expect(r("mkdir -p build") == "mkdir -p build")
        #expect(r("ssh -p 2222 user@example.com") == "ssh -p 2222 user@example.com")
        #expect(r("sshpass -p secret ssh example.com") == "sshpass -p \(m) ssh example.com")
        #expect(r("curl -u user:hunter2 https://example.com") == "curl -u user:\(m) https://example.com")
        #expect(r("redis-cli -h db -a hunter2 ping") == "redis-cli -h db -a \(m) ping")
        #expect(r("sudo docker login -u user -p hunter2 registry.example.com") == "sudo docker login -u user -p \(m) registry.example.com")
        #expect(r("docker run -p 8080:80 nginx") == "docker run -p 8080:80 nginx")
        #expect(r("openssl enc -k hunter2 -in a") == "openssl enc -k \(m) -in a")
        #expect(r("openssl rsa -passin pass:hunter2") == "openssl rsa -passin pass:\(m)")
        #expect(r("curl -H 'X-Api-Key: abc123' https://example.com") == "curl -H 'X-Api-Key: \(m)' https://example.com")
        #expect(r("env PGPASSWORD=hunter2 psql") == "env PGPASSWORD=\(m) psql")
        #expect(r("sudo mysql -uroot -phunter2") == "sudo mysql -uroot -p\(m)")
    }
}

/// A flag the codec closures can read.
final class LockFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
