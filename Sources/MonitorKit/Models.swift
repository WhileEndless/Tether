import Foundation

public struct DiskUsage: Identifiable, Hashable, Sendable {
    public var filesystem: String
    public var sizeKB: Int64
    public var usedKB: Int64
    public var availableKB: Int64
    public var mount: String
    public var id: String { mount }
    /// Used share as `df` reports it: used / (used + available), so blocks reserved for root on
    /// Linux file systems do not make a full disk look like 95 %.
    public var fraction: Double {
        let total = usedKB + availableKB
        return total > 0 ? Double(usedKB) / Double(total) : 0
    }
}

/// Raw cumulative CPU counters from /proc/stat, used to compute utilisation between samples.
public struct CPUTimes: Hashable, Sendable {
    public var busy: UInt64
    public var total: UInt64

    public func usage(since previous: CPUTimes) -> Double? {
        guard total > previous.total else { return nil }
        let dt = Double(total - previous.total)
        let db = Double(busy >= previous.busy ? busy - previous.busy : 0)
        return min(max(db / dt, 0), 1)
    }
}

public struct SystemSnapshot: Sendable {
    public var timestamp = Date()
    public var hostname = ""
    public var kernel = ""
    public var osName = ""
    public var architecture = ""
    public var uptime: TimeInterval = 0
    public var load: [Double] = []
    public var cpuCount = 0
    /// 0...1, nil until two samples exist.
    public var cpuUsage: Double?
    public var cpuTimes: [CPUTimes] = []
    public var memTotal: Int64 = 0      // bytes
    public var memUsed: Int64 = 0
    public var memAvailable: Int64 = 0
    public var swapTotal: Int64 = 0
    public var swapUsed: Int64 = 0
    public var disks: [DiskUsage] = []
    public var gpus: [GPUInfo] = []
    public var connection: ConnectionInfo?
    public var interfaces: [NetworkInterface] = []
    /// Detailed operating system information (key → value: id, version, codename, build,
    /// kernelbuild, virt, hardware, shell…), filled from the first frame.
    public var osInfo: [String: String] = [:]

    /// Total download / upload rate over physical (or, failing that, all non-loopback) interfaces.
    public var networkRates: (rx: Double, tx: Double)? {
        let real = interfaces.filter { $0.isPhysical || (!$0.looksVirtual && $0.name != "lo") }
        let use = real.isEmpty ? interfaces.filter { $0.name != "lo" && !$0.name.hasPrefix("lo") } : real
        let rx = use.compactMap(\.rxRate), tx = use.compactMap(\.txRate)
        guard !rx.isEmpty || !tx.isEmpty else { return nil }
        return (rx.reduce(0, +), tx.reduce(0, +))
    }

    public var memFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }
    public var swapFraction: Double { swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : 0 }

    public init() {}
}

public struct ProcessEntry: Identifiable, Hashable, Sendable {
    public var pid: Int
    public var user: String
    public var cpu: Double
    public var mem: Double
    public var rssKB: Int64
    public var elapsed: String
    public var command: String
    public var id: Int { pid }

    /// Executable name without path or arguments.
    public var name: String {
        let first = command.split(separator: " ").first.map(String.init) ?? command
        return (first as NSString).lastPathComponent
    }
}

public struct LoginEntry: Identifiable, Hashable, Sendable {
    public var user: String
    public var terminal: String
    public var since: String
    public var from: String
    public var id: String { user + terminal + since }
}

public struct ConnectionEntry: Identifiable, Hashable, Sendable {
    public var local: String
    public var peer: String
    public var state: String
    public var process: String
    /// Set by the parser when the local port is one sshd listens on (any port, not just 22).
    public var isSSH = false
    public var id: String { local + ">" + peer }

    /// Port part of an address like `10.0.0.1:22`, `[::1]:2222` or BSD-style `10.0.0.1.22`.
    static func port(of address: String) -> String {
        if let i = address.lastIndex(of: ":") { return String(address[address.index(after: i)...]) }
        if let i = address.lastIndex(of: ".") { return String(address[address.index(after: i)...]) }
        return ""
    }
}

public struct RemoteSessionEntry: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case tmux, screen }
    public var kind: Kind
    public var name: String
    public var created: Date?
    public var attached: Bool
    public var windows: Int?
    public var lastActivity: Date?
    public var id: String { kind.rawValue + ":" + name }
    /// Created by Tether (as opposed to the user's own tmux/screen sessions).
    public var isTether: Bool { name.hasPrefix("tether-") }
}

public enum LogSource: Hashable, Sendable, CaseIterable, Identifiable {
    case system, auth, kernel
    case file(String)

    public static var allCases: [LogSource] { [.system, .auth, .kernel] }
    public var id: String { title }

    public var title: String {
        switch self {
        case .system: "System"
        case .auth: "Authentication"
        case .kernel: "Kernel"
        case .file(let p): p
        }
    }
}

/// One GPU as reported by nvidia-smi, rocm-smi or sysfs. Fields are nil when the driver does not
/// report them (e.g. unified-memory GPUs report no dedicated memory).
public struct GPUInfo: Identifiable, Hashable, Sendable {
    public enum Vendor: String, Sendable { case nvidia = "NVIDIA", amd = "AMD", other = "GPU" }
    public var index: Int
    public var vendor: Vendor
    public var name: String
    public var utilization: Double?      // 0...1
    public var memoryUsed: Int64?        // bytes
    public var memoryTotal: Int64?       // bytes
    public var temperature: Double?      // °C
    public var power: Double?            // W
    public var powerLimit: Double?       // W
    public var id: String { "\(vendor.rawValue)-\(index)" }
    public var memoryFraction: Double? {
        guard let u = memoryUsed, let t = memoryTotal, t > 0 else { return nil }
        return Double(u) / Double(t)
    }
}

public struct GPUProcess: Identifiable, Hashable, Sendable {
    public var pid: Int
    public var name: String
    public var memoryUsed: Int64?
    public var gpu: String
    public var id: String { "\(gpu)-\(pid)" }
}

/// A network interface with its traffic counters and (derived) current rates.
public struct NetworkInterface: Identifiable, Hashable, Sendable {
    public var name: String
    public var rxBytes: UInt64
    public var txBytes: UInt64
    /// Bytes per second since the previous snapshot (nil on the first one).
    public var rxRate: Double?
    public var txRate: Double?
    public var addresses: [String] = []
    public var mac = ""
    public var state = ""          // up / down / unknown
    public var speedMbps: Int?
    /// Backed by real hardware (has a device); false for lo, docker, veth, bridges, tunnels…
    public var isPhysical = false
    public var id: String { name }

    /// Interfaces that are usually virtual, by name, when sysfs does not tell us.
    static let virtualPrefixes = ["lo", "docker", "veth", "br-", "virbr", "vnet", "tun", "tap", "wg", "tailscale",
                                  "zt", "cni", "flannel", "cali", "kube", "vxlan", "genev", "dummy", "bond", "team",
                                  "utun", "awdl", "llw", "bridge", "gif", "stf", "anpi", "ap"]
    public var looksVirtual: Bool { Self.virtualPrefixes.contains { name.hasPrefix($0) } }

    /// Sort key: real, up, busy interfaces first; virtual and idle ones last.
    public var priority: (Int, Int, Double) {
        let physical = isPhysical || (!looksVirtual && state != "down") ? 0 : 1
        let up = state == "down" ? 1 : 0
        return (physical, up, -((rxRate ?? 0) + (txRate ?? 0)))
    }
}

/// Information about the SSH connection as seen from the server.
public struct ConnectionInfo: Hashable, Sendable {
    /// From $SSH_CONNECTION: the address the server sees us coming from, and its own address/port.
    public var clientAddress = ""
    public var clientPort = ""
    public var serverAddress = ""
    public var serverPort = ""
    /// All addresses of the server.
    public var addresses: [String] = []
    /// Ports sshd listens on (from ss/netstat, or sshd_config).
    public var sshPorts: [String] = []
    public var cpuModel = ""
}

public struct ServiceEntry: Identifiable, Hashable, Sendable {
    public var name: String
    public var load: String
    public var active: String
    public var sub: String
    public var description: String
    public var id: String { name }
    public var isRunning: Bool { sub == "running" }
    public var isFailed: Bool { active == "failed" }
}

public struct ContainerEntry: Identifiable, Hashable, Sendable {
    public var id: String
    public var image: String
    public var name: String
    public var status: String
    public var state: String
    public var ports: String
    public var engine: String
    public var isRunning: Bool { state.lowercased() == "running" }

    /// Published ports parsed from Docker's `0.0.0.0:8080->80/tcp, :::8080->80/tcp, 9000/tcp` notation.
    public var portMappings: [PortMapping] { PortMapping.parse(ports) }
}

/// Where a listening socket can be reached from.
public enum Exposure: String, Sendable, Comparable {
    /// Bound to all addresses (0.0.0.0 / ::): reachable from any network the host is on.
    case allInterfaces = "All interfaces"
    /// Bound to a specific (non-loopback) address.
    case interface = "One interface"
    /// Loopback only: reachable from the host itself (or through a port forward).
    case localOnly = "Local only"

    public static func of(address: String) -> Exposure {
        let a = address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if a.isEmpty || a == "*" || a == "0.0.0.0" || a == "::" || a.hasPrefix("0.0.0.0%") || a.hasPrefix("::%") { return .allInterfaces }
        if a.hasPrefix("127.") || a == "::1" || a == "localhost" || a.hasPrefix("::ffff:127.") { return .localOnly }
        return .interface
    }

    private var rank: Int { self == .allInterfaces ? 0 : self == .interface ? 1 : 2 }
    public static func < (a: Exposure, b: Exposure) -> Bool { a.rank < b.rank }
}

/// A published container port: host side → container side.
public struct PortMapping: Hashable, Sendable, Identifiable {
    public var hostAddress: String
    public var hostPort: Int?
    public var containerPort: Int
    public var proto: String
    public var id: String { "\(hostAddress):\(hostPort ?? 0)->\(containerPort)/\(proto)" }
    public var isPublished: Bool { hostPort != nil }
    public var exposure: Exposure { isPublished ? Exposure.of(address: hostAddress) : .localOnly }

    public static func parse(_ text: String) -> [PortMapping] {
        var result: [PortMapping] = []
        for part in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let pieces = part.components(separatedBy: "->")
            let containerSide = pieces.last ?? ""
            let cp = containerSide.split(separator: "/")
            guard let containerPort = Int(cp.first?.split(separator: "-").first ?? "") else { continue }
            let proto = cp.count > 1 ? String(cp[1]) : "tcp"
            var m = PortMapping(hostAddress: "", hostPort: nil, containerPort: containerPort, proto: proto)
            if pieces.count == 2 {
                let host = pieces[0]
                if let colon = host.lastIndex(of: ":") {
                    m.hostAddress = String(host[..<colon])
                    m.hostPort = Int(host[host.index(after: colon)...].split(separator: "-").first ?? "")
                }
            }
            // Docker lists IPv4 and IPv6 bindings separately; keep one per port.
            if !result.contains(where: { $0.hostPort == m.hostPort && $0.containerPort == m.containerPort && $0.proto == m.proto }) {
                result.append(m)
            }
        }
        return result
    }
}

/// A socket listening on the server.
public struct ListeningSocket: Identifiable, Hashable, Sendable {
    public var proto: String          // tcp / udp
    public var address: String
    public var port: Int
    public var process: String
    public var pid: Int?
    /// Set when the port is published by a container.
    public var container: String?
    public var id: String { "\(proto)-\(address)-\(port)" }
    public var exposure: Exposure { Exposure.of(address: address) }
}
