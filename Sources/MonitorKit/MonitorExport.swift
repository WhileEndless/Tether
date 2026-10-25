import Foundation

/// Files to take monitoring data elsewhere (a spreadsheet, a script, a bug report). Rendering is
/// pure and Sendable, so it can run off the main thread. Numbers use "." and no grouping, dates
/// are ISO 8601 (UTC), command lines are those of the history (secrets already masked).
public enum MonitorExport {
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        /// One row per command, with the hosts it connected to and the programs it ran.
        case csv
        /// One row per process a command ran.
        case processesCSV = "csv-processes"
        /// One row per connection a command had: remote address, port, service, bytes, speed.
        case connectionsCSV = "csv-connections"
        /// Everything, self-describing (named fields, units in the names).
        case json
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .csv: "CSV (spreadsheet)"
            case .processesCSV: "CSV: one row per process"
            case .connectionsCSV: "CSV: one row per connection"
            case .json: "JSON (all details)"
            }
        }
        public var fileExtension: String { self == .json ? "json" : "csv" }
        /// Added to the file name, so the tables of one export can sit side by side.
        public var nameSuffix: String {
            switch self {
            case .processesCSV: " processes"
            case .connectionsCSV: " connections"
            default: ""
            }
        }
        /// Formats of exports with one table (host panel tables, live connections, traffic).
        public static let table: [Format] = [.csv, .json]
    }

    // MARK: Command history

    /// The command history in `format`. Every table carries the record id, so the command,
    /// process and connection tables join in a spreadsheet; JSON holds everything.
    public static func history(_ records: [CommandRecord], format: Format, exportedAt: Date = Date()) -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let file = HistoryExport(format: "tether-command-history", version: 2, exported: exportedAt,
                                     units: HistoryExport.unitNotes, records: records.map(HistoryExport.Record.init))
            return (try? encoder.encode(file)) ?? Data()
        case .processesCSV:
            var rows = [["record_id", "command_started", "host", "tab", "command", "pid", "name", "user", "command_line",
                         "started", "first_seen", "last_seen", "cpu_percent_min", "cpu_percent_avg", "cpu_percent_max",
                         "memory_peak_bytes"]]
            for r in records {
                for p in r.processList ?? [] {
                    rows.append([r.id.uuidString, date(r.started), r.hostName, r.sessionTitle, r.commandLine,
                                 String(p.pid), p.name, p.user, p.commandLine, p.started.map(date) ?? "",
                                 date(p.firstSeen), date(p.lastSeen),
                                 p.cpu.map { number($0.min) } ?? "", p.cpu.map { number($0.mean) } ?? "", p.cpu.map { number($0.max) } ?? "",
                                 p.memoryPeak.map(number) ?? ""])
                }
            }
            return csv(rows)
        case .connectionsCSV:
            var rows = [["record_id", "command_started", "host", "tab", "command", "pid", "process", "protocol", "state",
                         "local", "remote", "remote_host", "remote_port", "service", "first_seen", "last_seen",
                         "received_bytes", "sent_bytes", "peak_received_bytes_per_s", "peak_sent_bytes_per_s"]]
            for r in records {
                for c in r.connectionList ?? [] {
                    let split = ConnectionTraffic.split(c.peer)
                    rows.append([r.id.uuidString, date(r.started), r.hostName, r.sessionTitle, r.commandLine,
                                 String(c.pid), c.processName, c.proto, c.state, c.local, c.peer,
                                 split.host, split.port.map(String.init) ?? "", c.service ?? "",
                                 date(c.firstSeen), date(c.lastSeen),
                                 c.receivedBytes.map(String.init) ?? "", c.sentBytes.map(String.init) ?? "",
                                 c.peakReceived.map(number) ?? "", c.peakSent.map(number) ?? ""])
                }
            }
            return csv(rows)
        case .csv:
            var columns = ["record_id", "started", "last_seen", "ended", "ended_before", "duration_s", "status", "short", "host", "host_key",
                           "tab", "session_id", "pid", "command", "disconnected_s"]
            for m in metricNames { columns += ["\(m)_min", "\(m)_avg", "\(m)_max"] }
            columns += ["received_total_bytes", "sent_total_bytes", "read_total_bytes", "written_total_bytes",
                        "processes_seen", "connections_seen", "remote_hosts", "programs"]
            var rows = [columns]
            for r in records {
                var row = [r.id.uuidString, date(r.started), date(r.lastSeen), r.ended.map(date) ?? "", r.endedBefore.map(date) ?? "",
                           number(r.duration), r.status.rawValue, r.short == true ? "yes" : "", r.hostName, r.hostKey,
                           r.sessionTitle, r.sessionID.uuidString, String(r.pid), r.commandLine, number(r.disconnectedSeconds)]
                for m in metrics(r) { row += [m.map { number($0.min) } ?? "", m.map { number($0.mean) } ?? "", m.map { number($0.max) } ?? ""] }
                row += [r.receivedBytes, r.sentBytes, r.readBytes, r.writtenBytes].map { $0.map(number) ?? "" }
                row += [r.processList.map { String($0.count + (r.droppedProcesses ?? 0)) } ?? "",
                        r.connectionList.map { String($0.count) + (r.moreConnections == true ? "+" : "") } ?? "",
                        remoteHosts(r), programs(r)]
                rows.append(row)
            }
            return csv(rows)
        }
    }

    /// The remote ends a command connected to, once each: `192.0.2.7:443 (https)`; listening sockets
    /// and connections without a remote end are left out.
    static func remoteHosts(_ r: CommandRecord) -> String { remoteHostList(r).joined(separator: "; ") }

    static func remoteHostList(_ r: CommandRecord) -> [String] {
        var seen = Set<String>()
        var list: [String] = []
        for c in r.connectionList ?? [] {
            let traffic = ConnectionTraffic(proto: c.proto, state: c.state, local: c.local, peer: c.peer, pid: c.pid, processName: c.processName)
            guard !traffic.isListening, !c.peer.isEmpty, c.peer != "*", c.peer != "*:*" else { continue }
            let text = c.service.map { "\(c.peer) (\($0))" } ?? c.peer
            if seen.insert(text).inserted { list.append(text) }
        }
        return list
    }

    /// The programs a command ran, once each, in the order they were seen.
    static func programs(_ r: CommandRecord) -> String { programList(r).joined(separator: "; ") }

    static func programList(_ r: CommandRecord) -> [String] {
        var seen = Set<String>()
        return (r.processList ?? []).map(\.name).filter { seen.insert($0).inserted }
    }

    /// The JSON export: says what the file is and what the numbers mean, so it reads without Tether.
    struct HistoryExport: Encodable {
        var format: String
        var version: Int
        var exported: Date
        var units: [String: String]
        var records: [Record]

        static let unitNotes = [
            "cpu_percent": "percent of one CPU core (200 = two cores busy)",
            "memory_bytes": "resident memory of the command and its processes, bytes",
            "*_bytes_per_s": "bytes per second",
            "*_bytes": "bytes",
            "min, avg, max": "lowest, time-weighted average and highest over the run",
            "times": "ISO 8601, UTC",
        ]

        struct Metric: Encodable {
            var min: Double, avg: Double, max: Double, seconds: Double, samples: Int
            init?(_ m: MetricSummary?) {
                guard let m else { return nil }
                min = m.min; avg = m.mean; max = m.max; seconds = m.seconds; samples = m.samples
            }
        }

        struct Point: Encodable {
            var secondsSinceStart: Double
            var cpuPercent: Double?
            var memoryBytes: Double?
        }

        struct Process: Encodable {
            var pid: Int, name: String, user: String, commandLine: String
            var started: Date?, firstSeen: Date, lastSeen: Date
            var cpuPercent: Metric?
            var memoryPeakBytes: Double?
        }

        struct Connection: Encodable {
            var pid: Int, process: String, `protocol`: String, state: String
            var local: String, remote: String, remoteHost: String, remotePort: Int?, service: String?
            var firstSeen: Date, lastSeen: Date
            var receivedBytes: Int64?, sentBytes: Int64?
            var peakReceivedBytesPerS: Double?, peakSentBytesPerS: Double?
        }

        struct Record: Encodable {
            var id: UUID, host: String, hostKey: String, tab: String, sessionId: UUID
            var command: String, pid: Int, status: String, short: Bool
            var started: Date, ended: Date?, endedBefore: Date?, lastSeen: Date
            var durationS: Double, disconnectedS: Double
            var cpuPercent: Metric?, memoryBytes: Metric?, threads: Metric?, processes: Metric?
            var receivedBytesPerS: Metric?, sentBytesPerS: Metric?, readBytesPerS: Metric?, writtenBytesPerS: Metric?
            var receivedTotalBytes: Double?, sentTotalBytes: Double?, readTotalBytes: Double?, writtenTotalBytes: Double?
            var remoteHosts: [String], programs: [String]
            var processList: [Process]?, processesNotKept: Int?
            var connectionList: [Connection]?, moreConnectionsNotKept: Bool
            var graph: [Point]

            init(_ r: CommandRecord) {
                id = r.id; host = r.hostName; hostKey = r.hostKey; tab = r.sessionTitle; sessionId = r.sessionID
                command = r.commandLine; pid = r.pid; status = r.status.rawValue; short = r.short == true
                started = r.started; ended = r.ended; endedBefore = r.endedBefore; lastSeen = r.lastSeen
                durationS = r.duration; disconnectedS = r.disconnectedSeconds
                cpuPercent = Metric(r.cpu); memoryBytes = Metric(r.memory); threads = Metric(r.threads); processes = Metric(r.processes)
                receivedBytesPerS = Metric(r.received); sentBytesPerS = Metric(r.sent)
                readBytesPerS = Metric(r.read); writtenBytesPerS = Metric(r.written)
                receivedTotalBytes = r.receivedBytes; sentTotalBytes = r.sentBytes
                readTotalBytes = r.readBytes; writtenTotalBytes = r.writtenBytes
                remoteHosts = MonitorExport.remoteHostList(r)
                programs = MonitorExport.programList(r)
                processList = r.processList?.map {
                    Process(pid: $0.pid, name: $0.name, user: $0.user, commandLine: $0.commandLine, started: $0.started,
                            firstSeen: $0.firstSeen, lastSeen: $0.lastSeen, cpuPercent: Metric($0.cpu), memoryPeakBytes: $0.memoryPeak)
                }
                processesNotKept = r.droppedProcesses
                connectionList = r.connectionList?.map {
                    let split = ConnectionTraffic.split($0.peer)
                    return Connection(pid: $0.pid, process: $0.processName, protocol: $0.proto, state: $0.state,
                                      local: $0.local, remote: $0.peer, remoteHost: split.host, remotePort: split.port,
                                      service: $0.service, firstSeen: $0.firstSeen, lastSeen: $0.lastSeen,
                                      receivedBytes: $0.receivedBytes, sentBytes: $0.sentBytes,
                                      peakReceivedBytesPerS: $0.peakReceived, peakSentBytesPerS: $0.peakSent)
                }
                moreConnectionsNotKept = r.moreConnections == true
                graph = r.series.map { Point(secondsSinceStart: $0.t, cpuPercent: $0.cpu, memoryBytes: $0.memory) }
            }
        }
    }

    /// CPU in percent of one core, memory in bytes, rates in bytes per second.
    static let metricNames = ["cpu_percent", "memory_bytes", "threads", "processes",
                              "received_bytes_per_s", "sent_bytes_per_s", "read_bytes_per_s", "written_bytes_per_s"]
    static func metrics(_ r: CommandRecord) -> [MetricSummary?] {
        [r.cpu, r.memory, r.threads, r.processes, r.received, r.sent, r.read, r.written]
    }

    // MARK: Connections and traffic

    /// Connections with their speed and the bytes they moved.
    public static func connections(_ list: [ConnectionTraffic], format: Format = .csv) -> Data {
        var rows = [["pid", "process", "protocol", "state", "local", "remote", "remote_host", "remote_port", "service",
                     "received_bytes_per_s", "sent_bytes_per_s", "received_bytes", "sent_bytes"]]
        for c in list {
            rows.append([String(c.pid), c.processName, c.proto, c.state, c.local, c.peer,
                         c.peerHost, c.peerPort.map(String.init) ?? "",
                         ServicePorts.name(c.isListening ? c.localPort : c.peerPort) ?? "",
                         c.received.map(number) ?? "", c.sent.map(number) ?? "",
                         c.receivedBytes.map(String.init) ?? "", c.sentBytes.map(String.init) ?? ""])
        }
        return table(rows, format: format)
    }

    /// Traffic by process on a host, one row per connection (processes without connection details
    /// get one row of their own).
    public static func traffic(_ entries: [ProcessTrafficEntry], format: Format = .csv) -> Data {
        var rows = [["pid", "process", "process_received_bytes_per_s", "process_sent_bytes_per_s",
                     "process_received_since_opened_bytes", "process_sent_since_opened_bytes", "last_active", "connections",
                     "protocol", "state", "local", "remote", "remote_host", "remote_port", "service",
                     "received_bytes_per_s", "sent_bytes_per_s", "received_bytes", "sent_bytes"]]
        for e in entries {
            let head = [String(e.pid), e.name, e.received.map(number) ?? "", e.sent.map(number) ?? "",
                        number(e.totalReceived), number(e.totalSent), e.lastActive.map(date) ?? "", e.connections.map(String.init) ?? ""]
            if e.flows.isEmpty { rows.append(head + Array(repeating: "", count: 11)) }
            for f in e.flows {
                let port: String = f.peerPort.map(String.init) ?? ""
                let service: String = ServicePorts.name(f.isListening ? f.localPort : f.peerPort) ?? ""
                let speeds: [String] = [f.received.map(number) ?? "", f.sent.map(number) ?? ""]
                let bytes: [String] = [f.receivedBytes.map(String.init) ?? "", f.sentBytes.map(String.init) ?? ""]
                rows.append(head + [f.proto, f.state, f.local, f.peer, f.peerHost, port, service] + speeds + bytes)
            }
        }
        return table(rows, format: format)
    }

    // MARK: Host panel tables

    /// A table as CSV, or as JSON: an array of objects keyed by the column names.
    static func table(_ rows: [[String]], format: Format) -> Data {
        guard format == .json, let header = rows.first else { return csv(rows) }
        let objects = rows.dropFirst().map { row in
            Dictionary(uniqueKeysWithValues: zip(header, row.map { $0 as Any }))
        }
        return (try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// The Processes tab: CPU and memory in percent of the host, resident memory in bytes.
    public static func processes(_ list: [ProcessEntry], format: Format = .csv) -> Data {
        table([["pid", "user", "cpu_percent", "memory_percent", "resident_bytes", "elapsed", "name", "command"]]
            + list.map { [String($0.pid), $0.user, number($0.cpu), number($0.mem), String($0.rssKB * 1024), $0.elapsed, $0.name, $0.command] },
              format: format)
    }

    /// Listening ports, with who listens and how far the address is reachable.
    public static func listening(_ list: [ListeningSocket], format: Format = .csv) -> Data {
        table([["protocol", "address", "port", "service", "reachable_from", "process", "pid", "container"]]
            + list.map { [$0.proto, $0.address, String($0.port), ServicePorts.name($0.port) ?? "", $0.exposure.rawValue,
                          $0.process, $0.pid.map(String.init) ?? "", $0.container ?? ""] }, format: format)
    }

    public static func services(_ list: [ServiceEntry], format: Format = .csv) -> Data {
        table([["name", "load", "active", "sub", "description"]]
            + list.map { [$0.name, $0.load, $0.active, $0.sub, $0.description] }, format: format)
    }

    public static func containers(_ list: [ContainerEntry], format: Format = .csv) -> Data {
        table([["id", "name", "image", "state", "status", "ports", "engine"]]
            + list.map { [$0.id, $0.name, $0.image, $0.state, $0.status, $0.ports, $0.engine] }, format: format)
    }

    /// Who is logged in, and from where.
    public static func logins(_ list: [LoginEntry], format: Format = .csv) -> Data {
        table([["user", "terminal", "since", "from"]] + list.map { [$0.user, $0.terminal, $0.since, $0.from] }, format: format)
    }

    /// Established TCP connections of the whole host.
    public static func tcpConnections(_ list: [ConnectionEntry], format: Format = .csv) -> Data {
        table([["local", "remote", "remote_host", "remote_port", "service", "state", "process", "ssh"]]
            + list.map { c in
                let peer = ConnectionTraffic.split(c.peer)
                return [c.local, c.peer, peer.host, peer.port.map(String.init) ?? "", ServicePorts.name(peer.port) ?? "",
                        c.state, c.process, c.isSSH ? "yes" : ""]
            }, format: format)
    }

    /// Kubernetes pods, one row per pod; each container's readiness, restarts and reason too.
    public static func pods(_ list: [KubePod], format: Format = .csv) -> Data {
        table([["namespace", "name", "status", "phase", "ready", "containers", "restarts", "node", "created", "terminating",
                "reasons", "container_details"]]
            + list.map { p in
                [p.namespace, p.name, p.status, p.phase, String(p.readyCount), String(p.containers.count), String(p.restarts), p.node,
                 p.created.map(date) ?? "", p.terminating ? "yes" : "",
                 p.containers.map(\.reason).filter { !$0.isEmpty }.joined(separator: "; "),
                 p.containers.enumerated().map { i, c in
                     "\(i + 1): \(c.ready ? "ready" : "not ready"), \(c.restarts) restarts\(c.reason.isEmpty ? "" : ", \(c.reason)")"
                 }.joined(separator: "; ")]
            }, format: format)
    }

    /// GPUs (one row each) and the processes using them (one row each), in one table. A process's
    /// `gpu` is the index of its GPU, matched by NVIDIA's GPU id (also in `gpu_uuid`).
    public static func gpus(_ list: [GPUInfo], processes: [GPUProcess], format: Format = .csv) -> Data {
        var rows = [["kind", "gpu", "gpu_uuid", "vendor", "name", "utilization_percent", "memory_used_bytes", "memory_total_bytes",
                     "temperature_c", "power_w", "power_limit_w", "pid"]]
        for g in list {
            let used: String = g.memoryUsed.map(String.init) ?? ""
            let total: String = g.memoryTotal.map(String.init) ?? ""
            let values: [String] = [g.utilization.map { number($0 * 100) } ?? "", used, total,
                                    g.temperature.map(number) ?? "", g.power.map(number) ?? "", g.powerLimit.map(number) ?? ""]
            rows.append(["gpu", String(g.index), g.uuid ?? "", g.vendor.rawValue, g.name] + values + [""])
        }
        for p in processes {
            let index = list.first { $0.uuid == p.gpu }.map { String($0.index) } ?? ""
            rows.append(["process", index, p.gpu, "", p.name, "", p.memoryUsed.map(String.init) ?? "", "", "", "", "", String(p.pid)])
        }
        return table(rows, format: format)
    }

    // MARK: Formatting

    /// RFC 4180: fields with commas, quotes or line breaks are quoted, quotes doubled; CRLF rows.
    /// A field starting with = + - @ is prefixed with ' so spreadsheets never run it as a formula.
    static func csv(_ rows: [[String]]) -> Data {
        let text = rows.map { row in
            row.map { field -> String in
                var f = field
                if let first = f.first, "=+-@\t\r".contains(first), Double(f) == nil { f = "'" + f }
                guard f.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return f }
                return "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: ",")
        }.joined(separator: "\r\n") + "\r\n"
        return Data(text.utf8)
    }

    static func number(_ v: Double) -> String {
        guard v.isFinite else { return "" }
        if v == v.rounded() && abs(v) < 1e15 { return String(Int64(v)) }
        return String(format: "%.2f", v)
    }

    static func date(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: d)
    }

    /// `tether-command-history 2026-10-25 14.05.csv`
    public static func suggestedName(_ base: String, format: Format, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        let clean = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return String(clean.prefix(100)) + format.nameSuffix + " " + f.string(from: date) + "." + format.fileExtension
    }
}
