import Foundation

/// A connection (socket) with the bytes it moved since it opened: from the kernel's TCP counters
/// on Linux, nettop flows on macOS (see `ProbeScripts.flowFunctions`).
public struct SocketCounter: Hashable, Sendable {
    public var pid: Int
    public var name: String
    public var proto: String
    public var local: String
    public var peer: String
    /// nil when the host does not count bytes for this socket.
    public var counts: ByteCounts?
    /// Identifies the connection between looks and across sources (ss, lsof, nettop).
    public var key: String { ConnectionTraffic.key(local: local, peer: peer) }
}

/// One connection of a process as shown: where it goes, its state and how fast it moves data.
public struct ConnectionTraffic: Identifiable, Hashable, Sendable {
    public var proto: String
    public var state: String
    public var local: String
    public var peer: String
    public var pid: Int
    public var processName: String
    /// Bytes per second; nil when the host does not count this connection.
    public var received: Double?
    public var sent: Double?
    /// Bytes since the connection opened, when counted.
    public var receivedBytes: Int64?
    public var sentBytes: Int64?
    public var id: String { "\(pid) \(proto) \(Self.key(local: local, peer: peer))" }

    public var rate: Double { (received ?? 0) + (sent ?? 0) }
    /// Listening or unconnected (no peer).
    public var isListening: Bool {
        guard isTCPorUDP else { return false }
        return peer.hasPrefix("*") || state.uppercased().hasPrefix("LISTEN") || state == "UNCONN"
    }
    /// ICMP (ping) and raw sockets carry no ports and no byte counts.
    public var isTCPorUDP: Bool { proto.uppercased().hasPrefix("TCP") || proto.uppercased().hasPrefix("UDP") }

    /// The peer's host and port: `192.0.2.1:443` → ("192.0.2.1", 443), `[::1]:22` → ("::1", 22).
    public var peerHost: String { Self.split(peer).host }
    public var peerPort: Int? { Self.split(peer).port }
    public var localPort: Int? { Self.split(local).port }

    public init(proto: String, state: String, local: String, peer: String, pid: Int, processName: String,
                received: Double? = nil, sent: Double? = nil, receivedBytes: Int64? = nil, sentBytes: Int64? = nil) {
        self.proto = proto
        self.state = state
        self.local = local
        self.peer = peer
        self.pid = pid
        self.processName = processName
        self.received = received
        self.sent = sent
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }

    static func key(local: String, peer: String) -> String {
        normalize(local) + ">" + normalize(peer)
    }

    /// One spelling for an endpoint: `[::1]:22`, `::1.22` (nettop) and `::ffff:192.0.2.1:22` (ss)
    /// become `[::1]:22` and `192.0.2.1:22`; `*.*` becomes `*:*`.
    static func normalize(_ endpoint: String) -> String {
        let (host, port) = split(endpoint)
        let p = port.map(String.init) ?? "*"
        if host.contains(":") { return "[\(host)]:\(p)" }
        return "\(host):\(p)"
    }

    static func split(_ endpoint: String) -> (host: String, port: Int?) {
        var e = endpoint.trimmingCharacters(in: .whitespaces)
        if e == "*.*" || e == "*:*" { return ("*", nil) }
        // Interface suffix of link-local addresses (fe80::1%en0).
        if let pct = e.firstIndex(of: "%"), let end = e[pct...].firstIndex(where: { $0 == "]" || $0 == ":" || $0 == "." }) {
            e.removeSubrange(pct..<end)
        }
        if e.hasPrefix("["), let close = e.firstIndex(of: "]") {
            let host = String(e[e.index(after: e.startIndex)..<close])
            let rest = e[e.index(after: close)...]
            return (unmap(host), rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil)
        }
        // nettop: `*.5353` (any address), `::ffff:192.0.2.1.443` (IPv4 mapped, port after a dot).
        if e.hasPrefix("*."), let port = Int(e.dropFirst(2)) { return ("*", port) }
        if e.lowercased().hasPrefix("::ffff:"), e.filter({ $0 == "." }).count == 4, let dot = e.lastIndex(of: "."),
           let port = Int(e[e.index(after: dot)...]) {
            return (unmap(String(e[..<dot])), port)
        }
        let colons = e.filter { $0 == ":" }.count
        if colons > 1 {
            // IPv6 without brackets: nettop writes the port after a dot, ss after the last colon.
            if let dot = e.lastIndex(of: "."), let port = Int(e[e.index(after: dot)...]), !e[..<dot].contains(".") {
                return (unmap(String(e[..<dot])), port)
            }
            if let colon = e.lastIndex(of: ":") { return (unmap(String(e[..<colon])), Int(e[e.index(after: colon)...])) }
        }
        if colons == 1, let colon = e.lastIndex(of: ":") {
            return (String(e[..<colon]), Int(e[e.index(after: colon)...]))
        }
        return (e, nil)
    }

    /// IPv4 mapped into IPv6 reads as IPv4.
    private static func unmap(_ host: String) -> String {
        host.lowercased().hasPrefix("::ffff:") && host.dropFirst(7).contains(".") ? String(host.dropFirst(7)) : host
    }
}

/// Network use per process and connection from one look (`@@flows` lines).
public struct FlowSample: Sendable {
    /// Totals per process (macOS reports them; on Linux they are the sum of its sockets).
    public var processes: [Int: (name: String, counts: ByteCounts)] = [:]
    public var sockets: [String: SocketCounter] = [:]
    public init() {}
}

/// Rates from two looks at the counters.
public enum FlowRates {
    /// Bytes per second of each connection; one that closed in between is gone from both looks.
    /// A connection not in the previous look counts with everything it moved only when `isNew`
    /// says it opened since (its process started since); otherwise this look is its baseline — an
    /// old connection seen for the first time must not show its lifetime total as one second's
    /// speed. nil without counters.
    public static func sockets(_ now: [String: SocketCounter], previous: [String: SocketCounter], seconds dt: Double,
                               isNew: (SocketCounter) -> Bool = { _ in false }) -> [String: ByteRates]? {
        guard dt > 0, now.values.contains(where: { $0.counts != nil }) else { return nil }
        var result: [String: ByteRates] = [:]
        for (key, c) in now {
            guard let counts = c.counts else { continue }
            // The same connection may be reported under a parent or a child (shared socket).
            let old: ByteCounts
            if let before = previous[key]?.counts { old = before } else if isNew(c) { old = ByteCounts(received: 0, sent: 0) } else { old = counts }
            result[key] = ByteRates(received: Double(max(counts.received - old.received, 0)) / dt,
                                    sent: Double(max(counts.sent - old.sent, 0)) / dt)
        }
        return result
    }

    /// The connection rates summed per process.
    public static func perProcess(_ rates: [String: ByteRates], sockets: [String: SocketCounter]) -> [Int: ByteRates] {
        var result: [Int: ByteRates] = [:]
        for (key, r) in rates {
            guard let pid = sockets[key]?.pid else { continue }
            var sum = result[pid] ?? ByteRates(received: 0, sent: 0)
            sum.received += r.received
            sum.sent += r.sent
            result[pid] = sum
        }
        return result
    }

    /// Bytes per second of each process from its totals (macOS: includes connections closed between looks).
    public static func processes(_ now: [Int: ByteCounts], previous: [Int: ByteCounts], seconds dt: Double) -> [Int: ByteRates] {
        guard dt > 0 else { return [:] }
        var result: [Int: ByteRates] = [:]
        for (pid, counts) in now {
            let old = previous[pid] ?? ByteCounts(received: 0, sent: 0)
            result[pid] = ByteRates(received: Double(max(counts.received - old.received, 0)) / dt,
                                    sent: Double(max(counts.sent - old.sent, 0)) / dt)
        }
        return result
    }

    /// Connections as shown: the counted ones with their rates, plus sockets that are only listed
    /// (ss, lsof, Windows), which add their state. Busiest first, listening sockets last.
    public static func connections(counters: [String: SocketCounter], rates: [String: ByteRates]?,
                                   listed: [CommandSocket], names: [Int: String]) -> [ConnectionTraffic] {
        var byKey: [String: ConnectionTraffic] = [:]
        for (key, c) in counters {
            let r = rates?[key]
            byKey[key] = ConnectionTraffic(proto: c.proto, state: "-", local: c.local, peer: c.peer, pid: c.pid,
                                           processName: c.name.isEmpty ? names[c.pid] ?? "" : c.name,
                                           received: r?.received, sent: r?.sent,
                                           receivedBytes: c.counts?.received, sentBytes: c.counts?.sent)
        }
        for s in listed {
            let key = ConnectionTraffic.key(local: s.local, peer: s.peer)
            if var known = byKey[key] {
                known.state = s.state
                byKey[key] = known
            } else {
                byKey[key] = ConnectionTraffic(proto: s.proto, state: s.state, local: s.local, peer: s.peer, pid: s.pid,
                                               processName: names[s.pid] ?? "")
            }
        }
        return byKey.values.sorted { a, b in
            if a.isListening != b.isListening { return !a.isListening }
            if a.rate != b.rate { return a.rate > b.rate }
            return (a.receivedBytes ?? 0) + (a.sentBytes ?? 0) > (b.receivedBytes ?? 0) + (b.sentBytes ?? 0)
        }
    }
}

extension ProbeParser {
    /// `P` and `F` lines of `@@flows` (see `ProbeScripts.flowFunctions`).
    static func flows(_ lines: [String]) -> FlowSample {
        var sample = FlowSample()
        for line in lines {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let pid = Int(f[1]) else { continue }
            func counts(_ rx: String, _ tx: String) -> ByteCounts? {
                Int64(rx).flatMap { r in Int64(tx).map { ByteCounts(received: r, sent: $0) } }
            }
            if f[0] == "P", let c = counts(f[3], f[4]) {
                sample.processes[pid] = (f[2], c)
            } else if f[0] == "F", f.count >= 8 {
                let c = SocketCounter(pid: pid, name: f[2], proto: f[3], local: f[4], peer: f[5], counts: counts(f[6], f[7]))
                sample.sockets[c.key] = c
            }
        }
        return sample
    }
}

/// Names of well-known ports, to say where a connection goes.
public enum ServicePorts {
    static let names: [Int: String] = [
        20: "FTP data", 21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS", 67: "DHCP", 68: "DHCP", 80: "HTTP",
        110: "POP3", 123: "NTP", 143: "IMAP", 161: "SNMP", 389: "LDAP", 443: "HTTPS", 445: "SMB", 465: "SMTPS",
        514: "Syslog", 587: "SMTP submission", 636: "LDAPS", 853: "DNS over TLS", 873: "rsync", 993: "IMAPS", 995: "POP3S",
        1433: "SQL Server", 1521: "Oracle", 2049: "NFS", 2375: "Docker", 2376: "Docker (TLS)", 2379: "etcd",
        3000: "Dev server", 3306: "MySQL", 3389: "RDP", 5000: "Dev server", 5222: "XMPP", 5223: "Apple Push",
        5353: "mDNS", 5432: "PostgreSQL", 5672: "AMQP", 5900: "VNC", 6379: "Redis", 6443: "Kubernetes API",
        8000: "HTTP (alt)", 8080: "HTTP (alt)", 8443: "HTTPS (alt)", 9000: "HTTP (alt)", 9090: "Prometheus",
        9092: "Kafka", 9200: "Elasticsearch", 11211: "Memcached", 27017: "MongoDB",
    ]

    public static func name(_ port: Int?) -> String? { port.flatMap { names[$0] } }
}
