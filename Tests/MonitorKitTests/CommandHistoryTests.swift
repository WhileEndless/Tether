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

    /// Starting and ending commands adds to a small journal instead of writing the host's whole
    /// file again; another launch reads both; once the journal is large it is folded into the file.
    @Test func changesAreAddedToAJournalNotRewritten() throws {
        try withFolder { dir in
            let store = CommandHistoryStore(directory: dir)
            let session = UUID()
            for i in 0..<40 {
                let id = store.begin(hostKey: "web", hostName: "web", sessionID: session, sessionTitle: "web",
                                     process: process(100 + i, started: now.addingTimeInterval(Double(i) * 10)), at: now.addingTimeInterval(Double(i) * 10))
                store.end(id, status: .finished, at: now.addingTimeInterval(Double(i) * 10 + 5))
            }
            store.flush()                               // the first write: the whole file
            let file = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" })
            let journal = file.deletingPathExtension().appendingPathExtension("journal")
            let written = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
            let id = store.begin(hostKey: "web", hostName: "web", sessionID: session, sessionTitle: "web",
                                 process: process(999, started: now.addingTimeInterval(1000)), at: now.addingTimeInterval(1000))
            store.flush()
            store.end(id, status: .finished, at: now.addingTimeInterval(1010))
            store.flush()
            #expect(FileManager.default.fileExists(atPath: journal.path), "the change went to the journal")
            #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) == written,
                    "the file was not written again")
            let again = CommandHistoryStore(directory: dir)
            again.load()
            #expect(again.records().count == 41)
            #expect(again.record(id)?.status == .finished && again.record(id)?.ended == now.addingTimeInterval(1010))
            // Removing records writes the file whole, and the journal goes.
            again.clear()
            again.flush()
            #expect(!FileManager.default.fileExists(atPath: journal.path))
        }
    }

    /// A journal entry cut short (Tether stopped while adding it) is skipped when read, and the next
    /// write is the whole file, so what is added after it can be read too.
    @Test func aJournalCutShortIsRepaired() throws {
        try withFolder { dir in
            let store = CommandHistoryStore(directory: dir)
            let session = UUID()
            let first = store.begin(hostKey: "web", hostName: "web", sessionID: session, sessionTitle: "web",
                                    process: process(1, started: now), at: now)
            store.flush()
            store.end(first, status: .finished, at: now.addingTimeInterval(5))
            store.flush()
            let journal = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "journal" })
            let handle = try FileHandle(forWritingTo: journal)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0, 0, 9, 9, 1, 2, 3]))     // a frame that never finished
            try handle.close()
            let again = CommandHistoryStore(directory: dir)
            again.load()
            #expect(again.record(first)?.status == .finished)
            let second = again.begin(hostKey: "web", hostName: "web", sessionID: session, sessionTitle: "web",
                                     process: process(2, started: now.addingTimeInterval(10)), at: now.addingTimeInterval(10))
            again.flush()
            let third = CommandHistoryStore(directory: dir)
            third.load()
            #expect(third.record(second) != nil, "added after the cut, and read")
            #expect(third.record(first)?.status == .finished)
        }
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

    /// When the shell was last seen at its prompt (for mouse tracking a program left on).
    @Test func samplerTellsWhenTheShellWasSeenIdle() {
        let s = CommandSampler(anchor: { nil }) {
            CommandSampler.Context(hostKey: "web", hostName: "web", sessionID: UUID(), sessionTitle: "web")
        }
        s.keepHistory = false
        s.update(online: true, foreground: nil)
        #expect(s.idleSeenAt == nil)
        // A look finds nothing but the shell.
        s.ingest(CommandFrame(takenAt: now, shellPid: 1))
        #expect(s.status == .idle)
        #expect(s.idleSeenAt == now)
        // A program runs: not idle any more.
        var busy = CommandFrame(takenAt: now.addingTimeInterval(2), shellPid: 1)
        busy.processes = [CommandProcess(pid: 10, ppid: 1, cpuSeconds: 1, rssBytes: 100, started: now)]
        s.ingest(busy)
        #expect(s.idleSeenAt == nil)
        // The watcher says it ended, then that another one started.
        s.watched(.idle, at: now.addingTimeInterval(5))
        #expect(s.idleSeenAt == now.addingTimeInterval(5))
        s.watched(.busy(pid: 11, commandLine: "fzf"), at: now.addingTimeInterval(6))
        #expect(s.idleSeenAt == nil)
        // Offline: nothing known.
        s.watched(.idle, at: now.addingTimeInterval(7))
        s.update(online: false, foreground: nil)
        #expect(s.idleSeenAt == nil)
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
        let p = CommandProcess(pid: 8, ppid: 7, user: "user", state: "R", cpuSeconds: 1, rssBytes: 4096, commandLine: "curl https://example.com")
        r.note(processes: [p], cpu: [8: 30], weight: 2, at: now)
        r.note(connections: [ConnectionTraffic(proto: "TCP", state: "ESTAB", local: "192.0.2.1:5000", peer: "192.0.2.2:443", pid: 8,
                                               processName: "curl", received: 100, sent: 10, receivedBytes: 1000, sentBytes: 50)], at: now)

        let csv = String(decoding: MonitorExport.history([r], format: .csv), as: UTF8.self)
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines[0].hasPrefix("record_id,started,last_seen,ended,ended_before,duration_s,status,short,host,host_key,tab,session_id,pid,command"))
        #expect(lines[0].hasSuffix(",remote_hosts,programs"))
        #expect(lines[1].contains("\"web, eu\""))
        #expect(lines[1].contains("\"'=cmd \"\"quoted\"\"\""))   // quoted, and never a formula
        #expect(lines[1].contains(",90,finished,"))
        #expect(lines[1].contains(",12.50,12.50,12.50,"))
        #expect(lines[1].hasSuffix(",192.0.2.2:443 (HTTPS),curl"))   // where it connected, what it ran

        let processes = String(decoding: MonitorExport.history([r], format: .processesCSV), as: UTF8.self).components(separatedBy: "\r\n")
        #expect(processes[1].hasPrefix(r.id.uuidString))
        #expect(processes[1].contains(",8,curl,user,curl https://example.com,"))

        let connections = String(decoding: MonitorExport.history([r], format: .connectionsCSV), as: UTF8.self).components(separatedBy: "\r\n")
        #expect(connections[0].contains(",remote,remote_host,remote_port,service,"))
        #expect(connections[1].contains(",8,curl,TCP,ESTAB,192.0.2.1:5000,192.0.2.2:443,192.0.2.2,443,HTTPS,"))
        #expect(connections[1].contains(",1000,50,100,10"))

        // JSON: named fields with units, the processes and connections with their details.
        let json = try #require(JSONSerialization.jsonObject(with: MonitorExport.history([r], format: .json)) as? [String: Any])
        #expect(json["format"] as? String == "tether-command-history" && json["version"] as? Int == 2)
        let record = try #require((json["records"] as? [[String: Any]])?.first)
        #expect(record["id"] as? String == r.id.uuidString)
        #expect((record["cpu_percent"] as? [String: Any])?["avg"] as? Double == 12.5)
        #expect(record["remote_hosts"] as? [String] == ["192.0.2.2:443 (HTTPS)"])
        let conn = try #require((record["connection_list"] as? [[String: Any]])?.first)
        #expect(conn["remote_host"] as? String == "192.0.2.2" && conn["remote_port"] as? Int == 443 && conn["service"] as? String == "HTTPS")
        #expect((record["process_list"] as? [[String: Any]])?.first?["command_line"] as? String == "curl https://example.com")
        #expect((record["graph"] as? [[String: Any]])?.first?["cpu_percent"] as? Double == 12.5)

        let live = String(decoding: MonitorExport.connections([ConnectionTraffic(proto: "TCP", state: "ESTAB", local: "192.0.2.1:1",
                                                                                   peer: "192.0.2.2:443", pid: 3, processName: "curl")]), as: UTF8.self)
        #expect(live.contains("3,curl,TCP,ESTAB,192.0.2.1:1,192.0.2.2:443,192.0.2.2,443,HTTPS"))
        #expect(MonitorExport.suggestedName("tether-command-history", format: .connectionsCSV).hasPrefix("tether-command-history connections "))
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

/// While Tether is locked, a host's history file cannot be opened: commands recorded meanwhile go
/// to a pending file next to it (one per run), and are merged into it once it opens. Nothing is
/// kept only in memory, and nothing is overwritten.
@MainActor @Suite struct CommandHistoryLockedTests {
    final class Lock: @unchecked Sendable {
        private let l = NSLock()
        private var _locked = false
        var locked: Bool { get { l.lock(); defer { l.unlock() }; return _locked } set { l.lock(); _locked = newValue; l.unlock() } }
    }

    /// "S" + data while sealed; it opens only while unlocked (like files sealed with the key).
    func codec(_ lock: Lock) -> CommandHistoryStore.Codec {
        CommandHistoryStore.Codec(seal: { Data("S".utf8) + $0 }, open: { data in
            guard data.first == UInt8(ascii: "S") else { return .unreadable }
            return lock.locked ? .locked : .data(Data(data.dropFirst()))
        })
    }

    func add(_ store: CommandHistoryStore, _ command: String, at date: Date) {
        let id = store.begin(hostKey: "web", hostName: "web", sessionID: UUID(), sessionTitle: "t",
                             process: CommandProcess(pid: 1, ppid: 0, started: date, commandLine: command), at: date)
        store.end(id, status: .finished, at: date.addingTimeInterval(1))
    }

    @Test func recordsWhileLockedAreWrittenAndMerged() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tether-chl-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = Lock()
        let now = Date()

        let first = CommandHistoryStore(directory: dir, codec: codec(lock))
        add(first, "make one", at: now)
        first.flush()
        let mainFile = try #require(try FileManager.default.contentsOfDirectory(atPath: dir.path).first)
        let mainBefore = try Data(contentsOf: dir.appendingPathComponent(mainFile))

        // Two runs while locked: each writes its own pending file, the host's file stays as it was.
        lock.locked = true
        for (i, command) in ["make two", "make three"].enumerated() {
            let run = CommandHistoryStore(directory: dir, codec: codec(lock))
            run.load()
            #expect(run.isLocked)
            add(run, command, at: now.addingTimeInterval(Double(i + 1) * 10))
            run.flush()
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.filter { $0.contains(".pending-") }.count == 2)
        #expect(try Data(contentsOf: dir.appendingPathComponent(mainFile)) == mainBefore)

        // Unlocked: everything is there once, in the host's file; the pending files are gone.
        lock.locked = false
        let after = CommandHistoryStore(directory: dir, codec: codec(lock))
        after.load()
        #expect(Set(after.records().map(\.commandLine)) == ["make one", "make two", "make three"])
        add(after, "make four", at: now.addingTimeInterval(40))
        after.flush()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".pending-") }.isEmpty)
        let reread = CommandHistoryStore(directory: dir, codec: codec(lock))
        reread.load()
        #expect(reread.records().count == 4)
    }
}
