import Foundation

/// A process a command ran, as kept in its history record.
public struct ProcessSummary: Codable, Hashable, Identifiable, Sendable {
    public var pid: Int
    public var name: String
    /// With secrets masked, cut at `CommandRecord.maxCommandLine` characters.
    public var commandLine: String
    public var user: String
    public var started: Date?
    public var firstSeen: Date
    public var lastSeen: Date
    /// Percent of one core while it was seen.
    public var cpu: MetricSummary?
    public var memoryPeak: Double?
    public var id: String { "\(pid) \(started?.timeIntervalSince1970 ?? 0)" }
}

/// A connection a command had open, as kept in its history record.
public struct ConnectionSummary: Codable, Hashable, Identifiable, Sendable {
    public var proto: String
    public var local: String
    public var peer: String
    public var pid: Int
    public var processName: String
    public var state: String
    public var firstSeen: Date
    public var lastSeen: Date
    /// The connection's own counters at the last look (bytes since it opened), when counted.
    public var receivedBytes: Int64?
    public var sentBytes: Int64?
    /// Highest speed seen, bytes per second.
    public var peakReceived: Double?
    public var peakSent: Double?
    public var id: String { "\(pid) \(proto) \(ConnectionTraffic.key(local: local, peer: peer))" }

    public var service: String? {
        let c = ConnectionTraffic(proto: proto, state: state, local: local, peer: peer, pid: pid, processName: processName)
        return ServicePorts.name(c.isListening ? c.localPort : c.peerPort)
    }
}

extension CommandRecord {
    /// At most this many processes and connections are kept per command (the first ones seen);
    /// the rest are only counted.
    public static let maxDetails = 50
    public static let maxCommandLine = 300

    /// Adds what one look saw: the command's processes (with their CPU since the previous look) and
    /// its connections. Known ones are updated, new ones added while there is room.
    mutating func note(processes: [CommandProcess], cpu: [Int: Double], weight: Double, at date: Date) {
        var list = processList ?? []
        for p in processes {
            if let i = list.firstIndex(where: { $0.pid == p.pid && CommandSampler.sameStart($0.started, p.started) }) {
                list[i].lastSeen = date
                list[i].cpu = MetricSummary.adding(cpu[p.pid], to: list[i].cpu, weight: weight)
                if let rss = p.rssBytes { list[i].memoryPeak = max(list[i].memoryPeak ?? 0, Double(rss)) }
            } else if list.count < Self.maxDetails {
                list.append(ProcessSummary(pid: p.pid, name: p.name,
                                           commandLine: String(CommandRedactor.redact(p.commandLine).prefix(Self.maxCommandLine)),
                                           user: p.user, started: p.started, firstSeen: date, lastSeen: date,
                                           cpu: cpu[p.pid].map(MetricSummary.init), memoryPeak: p.rssBytes.map(Double.init)))
            } else if let started = p.started, started > (detailsAt ?? .distantPast) {
                // Counted once: it started since the previous look, so this is its first.
                droppedProcesses = (droppedProcesses ?? 0) + 1
            }
        }
        processList = list
        detailsAt = date
    }

    mutating func note(connections: [ConnectionTraffic], at date: Date) {
        var list = connectionList ?? []
        for c in connections where !c.isListening {
            if let i = list.firstIndex(where: { $0.id == ConnectionSummary.id(c) }) {
                list[i].lastSeen = date
                if c.state != "-" { list[i].state = c.state }
                if let r = c.receivedBytes { list[i].receivedBytes = max(list[i].receivedBytes ?? 0, r) }
                if let s = c.sentBytes { list[i].sentBytes = max(list[i].sentBytes ?? 0, s) }
                if let r = c.received { list[i].peakReceived = max(list[i].peakReceived ?? 0, r) }
                if let s = c.sent { list[i].peakSent = max(list[i].peakSent ?? 0, s) }
            } else if list.count < Self.maxDetails {
                list.append(ConnectionSummary(proto: c.proto, local: c.local, peer: c.peer, pid: c.pid, processName: c.processName,
                                              state: c.state, firstSeen: date, lastSeen: date, receivedBytes: c.receivedBytes,
                                              sentBytes: c.sentBytes, peakReceived: c.received, peakSent: c.sent))
            } else {
                moreConnections = true
            }
        }
        connectionList = list
    }
}

extension ConnectionSummary {
    static func id(_ c: ConnectionTraffic) -> String { "\(c.pid) \(c.proto) \(ConnectionTraffic.key(local: c.local, peer: c.peer))" }
}
