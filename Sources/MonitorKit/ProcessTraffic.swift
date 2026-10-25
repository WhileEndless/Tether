import Foundation
import Observation
import SSHTransport

/// Network use of one process on a host.
public struct ProcessTrafficEntry: Identifiable, Hashable, Sendable {
    public var pid: Int
    public var name: String
    /// Bytes per second; nil when the source only counts connections.
    public var received: Double?
    public var sent: Double?
    /// Open sockets (the `connections` source).
    public var connections: Int?
    /// Its connections with their rates (nettop and the TCP counters; nethogs does not tell).
    public var flows: [ConnectionTraffic] = []
    /// Bytes moved since the view started watching (rates × time).
    public var totalReceived: Double = 0
    public var totalSent: Double = 0
    /// Last time it moved data; quiet processes stay listed for a while (`ProcessTraffic.keepQuiet`).
    public var lastActive: Date?
    /// Recent rates, oldest first, for a small graph.
    public var history: [Double] = []
    public var id: Int { pid }
    public var total: Double { totalReceived + totalSent }
    /// Both directions, bytes per second.
    public var rate: Double { (received ?? 0) + (sent ?? 0) }

    public init(pid: Int, name: String, received: Double? = nil, sent: Double? = nil, connections: Int? = nil,
                flows: [ConnectionTraffic] = []) {
        self.flows = flows
        self.pid = pid
        self.name = name
        self.received = received
        self.sent = sent
        self.connections = connections
    }
}

/// Traffic per process on the whole host, streamed while someone looks (`retain`/`release`):
/// nettop on macOS, nethogs on Linux when it is installed and allowed to capture, otherwise only
/// the number of sockets per process. Nothing is installed; a missing tool only means less detail.
@MainActor
@Observable
public final class ProcessTraffic {
    public enum Source: Equatable, Sendable {
        case nettop
        case nethogs
        /// The kernel's byte counters of TCP sockets (Linux, `ss -ti`): no capture, no root for one's own processes.
        case tcp
        /// Socket counts only (no counters on this host).
        case connections
        case unavailable(String)

        /// Whether rates (bytes per second) are known.
        public var hasRates: Bool { self == .nettop || self == .nethogs || self == .tcp }
    }

    public private(set) var source: Source?
    /// Busiest first.
    public private(set) var entries: [ProcessTrafficEntry] = []
    /// Why a better source is not used (e.g. nethogs needs root), or an error.
    public private(set) var message: String?
    public private(set) var updatedAt: Date?
    /// Problems of the stream, for the user to inspect.
    public private(set) var diagnostics = DiagnosticLog()

    public func clearDiagnostics() { diagnostics.clear() }

    @ObservationIgnored private let executor: RemoteExecutor
    @ObservationIgnored private var stream: RemoteStream?
    @ObservationIgnored private var interest = 0
    @ObservationIgnored private var interval: TimeInterval = 2
    @ObservationIgnored private var lastFlows: (date: Date, sample: FlowSample)?
    /// Every process seen while watching, with totals (see `merge`).
    @ObservationIgnored private var tracked: [Int: ProcessTrafficEntry] = [:]
    /// When the current source started reporting (totals count from here).
    public private(set) var watchingSince: Date?
    /// How long a process that went quiet stays in the list.
    public static let keepQuiet: TimeInterval = 60
    static let historyLength = 30
    @ObservationIgnored private var frozen = false

    public init(executor: RemoteExecutor) {
        self.executor = executor
    }

    public func retain(interval: TimeInterval = 2) {
        interest += 1
        self.interval = max(interval, 1)
        if stream == nil && !frozen { start() }
    }

    public func release() {
        interest = max(interest - 1, 0)
        guard interest == 0 else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.interest == 0 else { return }
            self.stream?.stop()
            self.stream = nil
        }
    }

    /// Current rates of these processes together, when the source measures rates and is current.
    public func rates(for pids: Set<Int>) -> ByteRates? {
        guard source?.hasRates == true, let updatedAt, Date().timeIntervalSince(updatedAt) < max(interval * 3, 6) else { return nil }
        let mine = entries.filter { pids.contains($0.pid) }
        return ByteRates(received: mine.compactMap(\.received).reduce(0, +), sent: mine.compactMap(\.sent).reduce(0, +))
    }

    private func start() {
        let s = RemoteStream(separator: "@@end\n")
        s.onRecord = { [weak self] text in self?.ingest(text) }
        s.onEnd = { [weak self] status, err in
            guard let self, self.stream === s else { return }
            self.stream = nil
            if status != 0 && status != 15, !err.isEmpty {
                self.message = DiagnosticLog.tail(err, lines: 2)
                self.diagnostics.add("The traffic stream stopped (exit \(status)): " + DiagnosticLog.tail(err), source: "network")
            }
            if self.interest > 0 {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    guard let self, self.interest > 0, self.stream == nil else { return }
                    self.start()
                }
            }
        }
        stream = s
        let executor = self.executor
        let interval = self.interval
        Task { [weak self] in
            let platform = await executor.resolvedPlatform()
            guard let self, self.stream === s else { return }
            s.start(executor: executor, script: RemoteScript(ProbeScripts.processTraffic, windows: WindowsProbeScripts.processTraffic),
                    platform: platform,
                    arguments: [String(Int(interval))], purpose: "monitor")
        }
    }

    func ingest(_ record: String, at date: Date = Date()) {
        let s = ProbeParser.sections(record)
        if let name = s["source"]?.first {
            switch name {
            case "nettop": source = .nettop
            case "nethogs": source = .nethogs
            case "tcp": source = .tcp
            default: source = .connections
            }
            switch source {
            case .tcp?: message = "TCP only, from the kernel's socket counters. Other users' processes need root."
            case .connections?: message = "This host does not count bytes per connection: connections are listed instead, without speeds."
            default: message = nil
            }
            entries = []
            lastFlows = nil
            tracked = [:]
            watchingSince = date
            updatedAt = nil
            return
        }
        if s["failed"] != nil {
            let said = (s["nethogs"] ?? []).filter { !$0.contains("\t") }.suffix(3).joined(separator: "\n")
            message = "nethogs could not capture traffic." + (said.isEmpty ? "" : "\n" + said)
            diagnostics.add(message ?? "", source: "nethogs")
            return
        }
        if let lines = s["flows"] {
            guard let found = flowRates(ProbeParser.flows(lines), at: date) else { return }
            entries = merge(found, at: date)
        } else if let lines = s["nethogs"] {
            let parsed = ProbeParser.nethogs(lines)
            // The first record holds only nethogs' start-up messages.
            if parsed.isEmpty && updatedAt == nil { return }
            entries = merge(parsed, at: date)
        } else if let lines = s["sockets"] {
            entries = ProbeParser.socketCounts(lines)
        } else {
            return
        }
        updatedAt = date
    }

    /// Keeps the list calm: a process stays (dimmed by the view) for `keepQuiet` after it went
    /// quiet, collects totals and a short history, and the list is ordered by total — which changes
    /// slowly — instead of jumping with every sample.
    private func merge(_ fresh: [ProcessTrafficEntry], at date: Date) -> [ProcessTrafficEntry] {
        let dt = updatedAt.map { min(max(date.timeIntervalSince($0), 0), 30) } ?? interval
        var next: [Int: ProcessTrafficEntry] = [:]
        for e in fresh {
            var t = tracked[e.pid] ?? ProcessTrafficEntry(pid: e.pid, name: e.name)
            if !e.name.isEmpty { t.name = e.name }
            t.received = e.received
            t.sent = e.sent
            t.flows = e.flows
            t.totalReceived += (e.received ?? 0) * dt
            t.totalSent += (e.sent ?? 0) * dt
            if e.rate > 0 || t.lastActive == nil { t.lastActive = date }
            t.history = Array((t.history + [e.rate]).suffix(Self.historyLength))
            next[e.pid] = t
        }
        for (pid, var t) in tracked where next[pid] == nil {
            guard let active = t.lastActive, date.timeIntervalSince(active) < Self.keepQuiet else { continue }
            t.received = 0
            t.sent = 0
            t.flows = []
            t.history = Array((t.history + [0]).suffix(Self.historyLength))
            next[pid] = t
        }
        tracked = next
        return next.values.sorted { ($0.total, $1.pid) > ($1.total, $0.pid) }
    }

    /// What to install on a host for traffic per process, said to the user (Tether never installs
    /// anything). `ss` (iproute2) gives TCP speeds without root; nethogs adds UDP and every user's
    /// processes when it may run as root. nil for hosts we have no suggestion for.
    public static func installSuggestion(osID: String?) -> String? {
        switch osID?.lowercased() ?? "" {
        case "debian", "ubuntu", "linuxmint", "raspbian", "pop", "elementary", "kali", "zorin":
            "sudo apt install iproute2 nethogs"
        case "fedora":
            "sudo dnf install iproute nethogs"
        case "rhel", "centos", "rocky", "almalinux", "ol", "amzn", "scientific":
            "sudo dnf install epel-release && sudo dnf install iproute nethogs"
        case "arch", "manjaro", "endeavouros", "garuda":
            "sudo pacman -S iproute2 nethogs"
        case "alpine":
            "sudo apk add iproute2 nethogs"
        case "opensuse", "opensuse-leap", "opensuse-tumbleweed", "sles", "sled":
            "sudo zypper install iproute2 nethogs"
        case "gentoo":
            "sudo emerge sys-apps/iproute2 net-analyzer/nethogs"
        case "void":
            "sudo xbps-install iproute2 nethogs"
        default:
            nil
        }
    }

    /// Processes that moved data since the previous look, with their connections; nil on the
    /// first look (rates need two).
    private func flowRates(_ sample: FlowSample, at date: Date) -> [ProcessTrafficEntry]? {
        defer { lastFlows = (date, sample) }
        guard let last = lastFlows, case let dt = date.timeIntervalSince(last.date), dt > 0 else { return nil }
        let socketRates = FlowRates.sockets(sample.sockets, previous: last.sample.sockets, seconds: dt) ?? [:]
        // Process totals (macOS) also count connections closed between looks; only processes seen
        // in both looks, so a total since start is never taken for a rate.
        let perProcess: [Int: ByteRates] = sample.processes.isEmpty
            ? FlowRates.perProcess(socketRates, sockets: sample.sockets)
            : FlowRates.processes(sample.processes.filter { last.sample.processes[$0.key] != nil }.mapValues(\.counts),
                                  previous: last.sample.processes.mapValues(\.counts), seconds: dt)
        var socketsByPid: [Int: [String: SocketCounter]] = [:]
        for (key, c) in sample.sockets { socketsByPid[c.pid, default: [:]][key] = c }
        return perProcess.compactMap { pid, r -> ProcessTrafficEntry? in
            guard r.received + r.sent > 0 else { return nil }
            let name = sample.processes[pid]?.name ?? socketsByPid[pid]?.values.first?.name ?? ""
            let flows = FlowRates.connections(counters: socketsByPid[pid] ?? [:], rates: socketRates, listed: [], names: [pid: name])
            return ProcessTrafficEntry(pid: pid, name: name, received: r.received, sent: r.sent, flows: flows)
        }
        .sorted { $0.rate > $1.rate }
    }

    #if DEBUG
    /// Demo screenshots: fixed entries, the host is never contacted.
    public func loadDemo(source: Source, entries: [ProcessTrafficEntry], message: String? = nil) {
        frozen = true
        stream?.stop()
        stream = nil
        self.source = source
        self.entries = entries
        self.message = message
        updatedAt = .distantFuture
    }
    #endif
}

/// Bytes per second in both directions.
public struct ByteRates: Hashable, Sendable {
    public var received: Double
    public var sent: Double
}

extension ProbeParser {
    /// `program/pid/uid<TAB>sent KB/s<TAB>received KB/s` lines of `nethogs -t`. The program path may
    /// itself contain slashes, so the line is read from the right.
    static func nethogs(_ lines: [String]) -> [ProcessTrafficEntry] {
        var byPid: [Int: ProcessTrafficEntry] = [:]
        for line in lines {
            let f = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 3, let sent = Double(f[1]), let received = Double(f[2]) else { continue }
            var parts = f[0].split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let pid = Int(parts[parts.count - 2]), pid > 0 else { continue }
            parts.removeLast(2)
            let program = parts.joined(separator: "/")
            let name = (program as NSString).lastPathComponent
            var e = byPid[pid] ?? ProcessTrafficEntry(pid: pid, name: name.isEmpty ? program : name, received: 0, sent: 0)
            e.received = (e.received ?? 0) + received * 1024
            e.sent = (e.sent ?? 0) + sent * 1024
            byPid[pid] = e
        }
        return byPid.values.sorted { $0.rate > $1.rate }
    }

    /// Sockets per process from `ss -tunap` (`users:(("name",pid=1,fd=3))`) or `netstat -tunap` (`1/name`).
    static func socketCounts(_ lines: [String]) -> [ProcessTrafficEntry] {
        var counts: [Int: ProcessTrafficEntry] = [:]
        let ssUser = try? NSRegularExpression(pattern: #"\("([^"]*)",pid=([0-9]+)"#)
        for line in lines {
            var found: [(Int, String)] = []
            if let ssUser {
                for m in ssUser.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    guard let n = Range(m.range(at: 1), in: line), let p = Range(m.range(at: 2), in: line), let pid = Int(line[p]) else { continue }
                    found.append((pid, String(line[n])))
                }
            }
            if found.isEmpty, let last = line.split(separator: " ").last, let slash = last.firstIndex(of: "/"),
               let pid = Int(last[..<slash]) {
                found.append((pid, String(last[last.index(after: slash)...])))
            }
            // A socket shared by several processes counts once for each of them.
            var onLine = Set<Int>()
            // ss: Netid State Recv-Q Send-Q Local Peer …; netstat (and the Windows list): Proto Recv-Q Send-Q Local Foreign State …
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let netstat = f.count > 5 && Int(f[1]) != nil
            let local = f.count > 5 ? (netstat ? f[3] : f[4]) : ""
            let peer = f.count > 5 ? (netstat ? f[4] : f[5]) : ""
            let state = f.count > 5 ? (netstat ? f[5] : f[1]) : "-"
            for (pid, name) in found where onLine.insert(pid).inserted {
                var e = counts[pid] ?? ProcessTrafficEntry(pid: pid, name: name, connections: 0)
                e.connections = (e.connections ?? 0) + 1
                if !local.isEmpty, e.flows.count < 50 {
                    e.flows.append(ConnectionTraffic(proto: (f.first ?? "tcp").uppercased(), state: state, local: local, peer: peer,
                                                     pid: pid, processName: name))
                }
                counts[pid] = e
            }
        }
        return counts.values.sorted { ($0.connections ?? 0, $1.name) > ($1.connections ?? 0, $0.name) }
    }
}
