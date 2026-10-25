import Foundation

/// Files to take monitoring data elsewhere (a spreadsheet, a script, a bug report). Rendering is
/// pure and Sendable, so it can run off the main thread. Numbers use "." and no grouping, dates
/// are ISO 8601 (UTC), command lines are those of the history (secrets already masked).
public enum MonitorExport {
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case csv, json
        public var id: String { rawValue }
        public var title: String { self == .csv ? "CSV (spreadsheet)" : "JSON (all details)" }
        public var fileExtension: String { rawValue }
    }

    // MARK: Command history

    /// One row per command (CSV), or every record with its graph points (JSON).
    public static func history(_ records: [CommandRecord], format: Format, exportedAt: Date = Date()) -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let file = HistoryFile(format: "tether-command-history", version: 1, exported: exportedAt, records: records)
            return (try? encoder.encode(file)) ?? Data()
        case .csv:
            var columns = ["started", "ended", "duration_s", "status", "host", "tab", "pid", "command", "disconnected_s"]
            for m in metricNames { columns += ["\(m)_min", "\(m)_avg", "\(m)_max"] }
            columns += ["received_total_bytes", "sent_total_bytes", "read_total_bytes", "written_total_bytes",
                        "processes_seen", "connections_seen"]
            var rows = [columns]
            for r in records {
                var row = [date(r.started), r.ended.map(date) ?? "", number(r.duration), r.status.rawValue, r.hostName, r.sessionTitle,
                           String(r.pid), r.commandLine, number(r.disconnectedSeconds)]
                for m in metrics(r) { row += [m.map { number($0.min) } ?? "", m.map { number($0.mean) } ?? "", m.map { number($0.max) } ?? ""] }
                row += [r.receivedBytes, r.sentBytes, r.readBytes, r.writtenBytes].map { $0.map(number) ?? "" }
                row += [r.processList.map { String($0.count + (r.droppedProcesses ?? 0)) } ?? "",
                        r.connectionList.map { String($0.count) + (r.moreConnections == true ? "+" : "") } ?? ""]
                rows.append(row)
            }
            return csv(rows)
        }
    }

    /// The JSON wrapper: says what the file is, so a later version can still read it.
    struct HistoryFile: Codable {
        var format: String
        var version: Int
        var exported: Date
        var records: [CommandRecord]
    }

    /// CPU in percent of one core, memory in bytes, rates in bytes per second.
    static let metricNames = ["cpu_percent", "memory_bytes", "threads", "processes",
                              "received_bytes_per_s", "sent_bytes_per_s", "read_bytes_per_s", "written_bytes_per_s"]
    static func metrics(_ r: CommandRecord) -> [MetricSummary?] {
        [r.cpu, r.memory, r.threads, r.processes, r.received, r.sent, r.read, r.written]
    }

    // MARK: Connections and traffic

    /// Connections with their speed and the bytes they moved.
    public static func connections(_ list: [ConnectionTraffic]) -> Data {
        var rows = [["pid", "process", "protocol", "state", "local", "remote", "service",
                     "received_bytes_per_s", "sent_bytes_per_s", "received_bytes", "sent_bytes"]]
        for c in list {
            rows.append([String(c.pid), c.processName, c.proto, c.state, c.local, c.peer,
                         ServicePorts.name(c.isListening ? c.localPort : c.peerPort) ?? "",
                         c.received.map(number) ?? "", c.sent.map(number) ?? "",
                         c.receivedBytes.map(String.init) ?? "", c.sentBytes.map(String.init) ?? ""])
        }
        return csv(rows)
    }

    /// Traffic by process on a host, one row per connection (processes without connection details
    /// get one row of their own).
    public static func traffic(_ entries: [ProcessTrafficEntry]) -> Data {
        var rows = [["pid", "process", "process_received_bytes_per_s", "process_sent_bytes_per_s", "connections",
                     "protocol", "local", "remote", "received_bytes_per_s", "sent_bytes_per_s"]]
        for e in entries {
            let head = [String(e.pid), e.name, e.received.map(number) ?? "", e.sent.map(number) ?? "", e.connections.map(String.init) ?? ""]
            if e.flows.isEmpty { rows.append(head + ["", "", "", "", ""]) }
            for f in e.flows {
                rows.append(head + [f.proto, f.local, f.peer, f.received.map(number) ?? "", f.sent.map(number) ?? ""])
            }
        }
        return csv(rows)
    }

    // MARK: Formatting

    /// RFC 4180: fields with commas, quotes or line breaks are quoted, quotes doubled; CRLF rows.
    /// A field starting with = + - @ is prefixed with ' so spreadsheets never run it as a formula.
    static func csv(_ rows: [[String]]) -> Data {
        let text = rows.map { row in
            row.map { field -> String in
                var f = field
                if let first = f.first, "=+-@".contains(first), Double(f) == nil { f = "'" + f }
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
        return String(clean.prefix(100)) + " " + f.string(from: date) + "." + format.fileExtension
    }
}
