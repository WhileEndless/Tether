import Foundation

/// Pure functions that turn probe output into models. Kept separate for unit testing.
public enum ProbeParser {
    static func sections(_ text: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var current: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                current = String(line.dropFirst(2))
                result[current!, default: []] = []
            } else if let current {
                result[current, default: []].append(line)
            }
        }
        return result.mapValues { $0.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    }

    public static func cpuTimes(_ line: String) -> CPUTimes? {
        let f = line.split(separator: " ").dropFirst().compactMap { UInt64($0) }
        guard f.count >= 4 else { return nil }
        // user nice system idle iowait irq softirq steal
        let idle = f[3] + (f.count > 4 ? f[4] : 0)
        let total = f.prefix(8).reduce(0, +)
        return CPUTimes(busy: total - idle, total: total)
    }

    public static func system(_ text: String, previous: SystemSnapshot?) -> SystemSnapshot {
        let s = sections(text)
        var snap = SystemSnapshot()
        if let u = s["uname"] {
            snap.hostname = u.count > 0 ? u[0] : ""
            snap.kernel = u.count > 1 ? u[1] : ""
            snap.architecture = u.count > 2 ? u[2] : ""
        }
        snap.osName = s["os"]?.first ?? ""
        snap.uptime = Double(s["uptime"]?.first?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
        snap.load = (s["load"]?.first ?? "").split(separator: " ").compactMap { Double($0) }
        snap.cpuCount = Int(s["ncpu"]?.first?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0

        if let cpu = s["cpu"] {
            snap.cpuTimes = cpu.compactMap(cpuTimes)
            if snap.cpuTimes.count >= 2 {
                snap.cpuUsage = snap.cpuTimes[1].usage(since: snap.cpuTimes[0])
            } else if let last = snap.cpuTimes.last, let prev = previous?.cpuTimes.last {
                snap.cpuUsage = last.usage(since: prev)
            }
        }
        if let line = s["cpupct"]?.first {
            // "CPU usage: 3.33% user, 5.0% sys, 91.66% idle"
            if let idleRange = line.range(of: #"([0-9.]+)% idle"#, options: .regularExpression) {
                let num = line[idleRange].replacingOccurrences(of: "% idle", with: "")
                if let idle = Double(num) { snap.cpuUsage = max(0, min(1, 1 - idle / 100)) }
            }
        }
        if let mem = s["meminfo"] {
            var kv: [String: Int64] = [:]
            for line in mem {
                let p = line.split(separator: ":")
                guard p.count == 2 else { continue }
                let v = p[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.flatMap { Int64($0) } ?? 0
                kv[String(p[0])] = v * 1024
            }
            snap.memTotal = kv["MemTotal"] ?? 0
            var available: Int64 = kv["MemFree"] ?? 0
            available += kv["Buffers"] ?? 0
            available += kv["Cached"] ?? 0
            available += kv["SReclaimable"] ?? 0
            if let a = kv["MemAvailable"] { available = a }
            snap.memAvailable = available
            snap.memUsed = max(snap.memTotal - available, 0)
            snap.swapTotal = kv["SwapTotal"] ?? 0
            snap.swapUsed = max(snap.swapTotal - (kv["SwapFree"] ?? 0), 0)
        }
        if let mem = s["darwinmem"] {
            snap.memTotal = Int64(mem.first ?? "") ?? 0
            var pageSize: Int64 = 4096
            var pages: [String: Int64] = [:]
            for line in mem {
                if line.contains("page size of"),
                   let n = line.split(separator: " ").compactMap({ Int64($0) }).first { pageSize = n }
                let p = line.split(separator: ":")
                if p.count == 2, let v = Int64(p[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
                    pages[p[0].trimmingCharacters(in: .whitespaces)] = v
                }
                if line.hasPrefix("swap ") {
                    snap.swapTotal = darwinSwapValue(line, key: "total")
                    snap.swapUsed = darwinSwapValue(line, key: "used")
                }
            }
            var used: Int64 = pages["Pages active"] ?? 0
            used += pages["Pages wired down"] ?? 0
            used += pages["Pages occupied by compressor"] ?? 0
            snap.memUsed = used * pageSize
            snap.memAvailable = max(snap.memTotal - snap.memUsed, 0)
        }
        snap.gpus = gpus(nvidia: s["nvidia"], rocm: s["rocm"], amdSysfs: s["amdsysfs"])
        snap.interfaces = interfaces(counters: s["netdev"], info: s["netinfo"], addresses: s["netaddr"],
                                     previous: previous, now: snap.timestamp)
        if s["conn"] != nil || s["ips"] != nil {
            var c = previous?.connection ?? ConnectionInfo()
            let conn = (s["conn"]?.first ?? "").split(separator: " ").map(String.init)
            if conn.count >= 4 {
                c.clientAddress = conn[0]; c.clientPort = conn[1]; c.serverAddress = conn[2]; c.serverPort = conn[3]
            }
            if let ips = s["ips"] { c.addresses = ips.map { $0.trimmingCharacters(in: .whitespaces) } }
            if let ports = s["sshports"] { c.sshPorts = sshPorts(ports) }
            if let model = s["cpumodel"]?.first?.trimmingCharacters(in: .whitespaces), !model.isEmpty { c.cpuModel = model }
            snap.connection = c
        }
        if let info = s["osinfo"] {
            for line in info {
                let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2, !kv[1].trimmingCharacters(in: .whitespaces).isEmpty {
                    snap.osInfo[kv[0]] = kv[1].trimmingCharacters(in: .whitespaces)
                }
            }
        } else if let prev = previous {
            snap.osInfo = prev.osInfo
        }
        if snap.hostname.isEmpty, let prev = previous {
            snap.hostname = prev.hostname; snap.kernel = prev.kernel
            snap.architecture = prev.architecture; snap.osName = prev.osName
        }
        // macOS (APFS): "/" is the read-only system snapshot, a few GB of its own; the volumes of a
        // container share its space, so what is used is everything that is not free (as Finder shows).
        let apfs = s["darwinmem"] != nil
        snap.disks = (s["disk"] ?? []).compactMap(disk).map { d in
            guard apfs, d.sizeKB > d.availableKB else { return d }
            var d = d
            d.usedKB = d.sizeKB - d.availableKB
            return d
        }.filter { d in
            // Hide pseudo filesystems.
            !["tmpfs", "devtmpfs", "overlay", "shm", "udev", "devfs", "map"].contains(where: { d.filesystem.hasPrefix($0) })
                && !d.mount.hasPrefix("/System/Volumes/") && !d.mount.hasPrefix("/snap/") && !d.mount.hasPrefix("/run")
                && !d.mount.hasPrefix("/dev") && !d.mount.hasPrefix("/sys") && !d.mount.hasPrefix("/proc") && d.sizeKB > 0
        }
        return snap
    }

    private static func darwinSwapValue(_ line: String, key: String) -> Int64 {
        // "swap total = 2048.00M  used = 1024.50M  free = ..."
        guard let r = line.range(of: key + #" = ([0-9.]+)([KMG])"#, options: .regularExpression) else { return 0 }
        let token = line[r].split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let unit = token.last, let value = Double(token.dropLast()) else { return 0 }
        let mult: Double = unit == "G" ? 1_073_741_824 : unit == "M" ? 1_048_576 : 1024
        return Int64(value * mult)
    }

    static func disk(_ line: String) -> DiskUsage? {
        let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard f.count >= 6, let size = Int64(f[1]), let used = Int64(f[2]), let avail = Int64(f[3]) else { return nil }
        return DiskUsage(filesystem: f[0], sizeKB: size, usedKB: used, availableKB: avail,
                         mount: f[5...].joined(separator: " "))
    }

    /// Interfaces with rates computed against the previous snapshot. Static details (state, MAC,
    /// speed, addresses) only arrive in the first frame and are carried forward.
    static func interfaces(counters: [String]?, info: [String]?, addresses: [String]?,
                           previous: SystemSnapshot?, now: Date) -> [NetworkInterface] {
        guard let counters else { return previous?.interfaces ?? [] }
        let old = Dictionary((previous?.interfaces ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let dt = previous.map { now.timeIntervalSince($0.timestamp) } ?? 0
        var details: [String: (state: String, mac: String, speed: Int?, physical: Bool)] = [:]
        for line in info ?? [] {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5 else { continue }
            details[f[0]] = (f[1], f[2], Int(f[3]).flatMap { $0 > 0 ? $0 : nil }, f[4] == "1")
        }
        var addrs: [String: [String]] = [:]
        for line in addresses ?? [] {
            let f = line.split(separator: " ").map(String.init)
            guard f.count >= 2 else { continue }
            let a = f[1].split(separator: "%").first.map(String.init) ?? f[1]
            if !a.hasPrefix("fe80") { addrs[f[0], default: []].append(a) }
        }
        var result: [NetworkInterface] = []
        var seen = Set<String>()
        for line in counters {
            let f = line.split(separator: " ").map(String.init)
            guard f.count >= 3, let rx = UInt64(f[1]), let tx = UInt64(f[2]), seen.insert(f[0]).inserted else { continue }
            var i = old[f[0]] ?? NetworkInterface(name: f[0], rxBytes: rx, txBytes: tx)
            if let o = old[f[0]], dt > 0.2, rx >= o.rxBytes, tx >= o.txBytes {
                i.rxRate = Double(rx - o.rxBytes) / dt
                i.txRate = Double(tx - o.txBytes) / dt
            } else {
                i.rxRate = nil
                i.txRate = nil
            }
            i.rxBytes = rx
            i.txBytes = tx
            if let d = details[f[0]] { i.state = d.state; i.mac = d.mac; i.speedMbps = d.speed; i.isPhysical = d.physical }
            if let a = addrs[f[0]] { i.addresses = a }
            result.append(i)
        }
        return result.sorted { a, b in
            let pa = a.priority, pb = b.priority
            if pa.0 != pb.0 { return pa.0 < pb.0 }
            if pa.1 != pb.1 { return pa.1 < pb.1 }
            if pa.2 != pb.2 { return pa.2 < pb.2 }
            return a.name < b.name
        }
    }

    /// Ports sshd listens on, from `ss -tlnp` addresses and `cfg:<port>` lines (sshd_config).
    static func sshPorts(_ lines: [String]) -> [String] {
        var ports: [String] = []
        for l in lines {
            let p = l.hasPrefix("cfg:") ? String(l.dropFirst(4)) : ConnectionEntry.port(of: l)
            if !p.isEmpty, Int(p) != nil, !ports.contains(p) { ports.append(p) }
        }
        return ports
    }

    static func number(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces))
    }

    public static func gpus(nvidia: [String]?, rocm: [String]?, amdSysfs: [String]?) -> [GPUInfo] {
        var result: [GPUInfo] = []
        for line in nvidia ?? [] {
            // index, name, utilization.gpu, memory.used, memory.total, temperature.gpu, power.draw, power.limit
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 8, let index = Int(f[0]) else { continue }
            result.append(GPUInfo(index: index, vendor: .nvidia, name: f[1],
                                  utilization: number(f[2]).map { $0 / 100 },
                                  memoryUsed: number(f[3]).map { Int64($0 * 1_048_576) },
                                  memoryTotal: number(f[4]).map { Int64($0 * 1_048_576) },
                                  temperature: number(f[5]), power: number(f[6]), powerLimit: number(f[7])))
        }
        if let rocm, let data = rocm.joined(separator: "\n").data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            for (key, card) in json.sorted(by: { $0.key < $1.key }) where key.hasPrefix("card") {
                func value(_ prefixes: [String]) -> Double? {
                    for (k, v) in card where prefixes.contains(where: { k.lowercased().contains($0) }) {
                        if let d = Double("\(v)".filter { "0123456789.".contains($0) }) { return d }
                    }
                    return nil
                }
                let name = (card["Card series"] ?? card["Card SKU"] ?? card["Card model"]).map { "\($0)" } ?? "AMD GPU"
                result.append(GPUInfo(index: Int(key.dropFirst(4)) ?? result.count, vendor: .amd, name: name,
                                      utilization: value(["gpu use"]).map { $0 / 100 },
                                      memoryUsed: value(["vram total used memory"]).map { Int64($0) },
                                      memoryTotal: value(["vram total memory"]).map { Int64($0) },
                                      temperature: value(["temperature (sensor edge)", "temperature (sensor junction)"]),
                                      power: value(["average graphics package power", "current socket graphics package power"]),
                                      powerLimit: nil))
            }
        }
        if result.isEmpty {
            for line in amdSysfs ?? [] {
                // index|busy%|vram used|vram total|temp millideg|power microwatts
                let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 6, let index = Int(f[0]) else { continue }
                result.append(GPUInfo(index: index, vendor: .amd, name: "AMD GPU \(index)",
                                      utilization: number(f[1]).map { $0 / 100 },
                                      memoryUsed: Int64(f[2]), memoryTotal: Int64(f[3]),
                                      temperature: number(f[4]).map { $0 / 1000 },
                                      power: number(f[5]).map { $0 / 1_000_000 }, powerLimit: nil))
            }
        }
        return result
    }

    /// Listening sockets, de-duplicated (IPv4/IPv6 twins), most exposed first, then by port.
    /// Ports published by containers are labelled with the container name.
    public static func listening(_ text: String, containers: [ContainerEntry] = []) -> [ListeningSocket] {
        var published: [Int: String] = [:]
        for c in containers where c.isRunning {
            for m in c.portMappings { if let p = m.hostPort { published[p] = c.name } }
        }
        var out: [ListeningSocket] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 2, let port = Int(ConnectionEntry.port(of: f[1])) else { continue }
            var address = String(f[1].dropLast(String(port).count + 1))
            if address.hasSuffix(".") || address.hasSuffix(":") { address.removeLast() }
            if address == "*" { address = "0.0.0.0" }
            let s = ListeningSocket(proto: f[0], address: address, port: port, process: f.count > 2 ? f[2] : "",
                                    pid: f.count > 3 ? Int(f[3]) : nil, container: published[port])
            if let i = out.firstIndex(where: { $0.proto == s.proto && $0.port == s.port }) {
                // Keep the most exposed binding (e.g. 0.0.0.0 over 127.0.0.1) and any known process name.
                if s.exposure < out[i].exposure { out[i].address = s.address }
                if out[i].process.isEmpty { out[i].process = s.process; out[i].pid = s.pid }
            } else {
                out.append(s)
            }
        }
        return out.sorted { ($0.exposure, $0.proto, $0.port) < ($1.exposure, $1.proto, $1.port) }
    }

    public static func gpuProcesses(_ text: String) -> [GPUProcess] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 4, let pid = Int(f[1]) else { return nil }
            return GPUProcess(pid: pid, name: f[2], memoryUsed: number(f[3]).map { Int64($0 * 1_048_576) }, gpu: f[0])
        }
    }

    public static func services(_ text: String) -> [ServiceEntry] {
        let s = sections(text)
        if let units = s["systemd"] {
            return units.compactMap { line in
                let f = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true).map(String.init)
                guard f.count >= 4, f[0].hasSuffix(".service") else { return nil }
                return ServiceEntry(name: f[0], load: f[1], active: f[2], sub: f[3], description: f.count > 4 ? f[4] : "")
            }
        }
        if let jobs = s["launchd"] {
            return jobs.compactMap { line in
                let f = line.split(separator: "\t").map(String.init)
                guard f.count >= 3 else { return nil }
                let running = f[0] != "-"
                return ServiceEntry(name: f[2], load: "loaded", active: running ? "active" : (f[1] == "0" ? "inactive" : "failed"),
                                    sub: running ? "running" : "dead", description: running ? "pid \(f[0])" : "exit \(f[1])")
            }
        }
        if let win = s["winsvc"] {
            // name|status|start type|display name (Windows services)
            return win.compactMap { line in
                let f = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 4 else { return nil }
                let running = f[1] == "Running"
                let state: (String, String) = running ? ("active", "running")
                    : f[1] == "Stopped" ? ("inactive", "dead") : ("activating", f[1].lowercased())
                return ServiceEntry(name: f[0], load: f[2] == "Disabled" ? "disabled" : "loaded", active: state.0, sub: state.1,
                                    description: f[3])
            }
        }
        if let sysv = s["sysv"] {
            return sysv.compactMap { line in
                // " [ + ]  ssh"
                guard let close = line.firstIndex(of: "]") else { return nil }
                let state = line[..<close]
                let name = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                let running = state.contains("+")
                return ServiceEntry(name: name, load: "loaded", active: running ? "active" : "inactive",
                                    sub: running ? "running" : "dead", description: "")
            }
        }
        return []
    }

    public static func containers(_ text: String) -> [ContainerEntry] {
        var result: [ContainerEntry] = []
        for (engine, lines) in sections(text) where engine == "docker" || engine == "podman" {
            for line in lines {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 5 else { continue }
                result.append(ContainerEntry(id: f[0], image: f[1], name: f[2], status: f[3], state: f[4],
                                             ports: f.count > 5 ? f[5] : "", engine: engine))
            }
        }
        return result.sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) }
    }

    public static func processes(_ text: String) -> [ProcessEntry] {
        text.split(separator: "\n").compactMap { raw in
            let f = raw.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 7, let pid = Int(f[0]) else { return nil }
            return ProcessEntry(pid: pid, user: f[1], cpu: Double(f[2]) ?? 0, mem: Double(f[3]) ?? 0,
                                rssKB: Int64(f[4]) ?? 0, elapsed: f[5], command: f[6])
        }
    }

    public static func connections(_ text: String) -> (logins: [LoginEntry], connections: [ConnectionEntry]) {
        let s = sections(text)
        let logins: [LoginEntry] = (s["who"] ?? []).compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 3 else { return nil }
            var from = ""
            var rest = Array(f[2...])
            if let last = rest.last, last.hasPrefix("("), last.hasSuffix(")") {
                from = String(last.dropFirst().dropLast())
                rest.removeLast()
            }
            return LoginEntry(user: f[0], terminal: f[1], since: rest.joined(separator: " "), from: from)
        }
        var conns: [ConnectionEntry] = []
        for line in s["ss"] ?? [] {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // Recv-Q Send-Q Local Peer [Process]
            guard f.count >= 4 else { continue }
            var proc = f.count > 4 ? f[4...].joined(separator: " ") : ""
            if let r = proc.range(of: #"\(\"([^\"]+)\""#, options: .regularExpression) {
                proc = String(proc[r]).trimmingCharacters(in: CharacterSet(charactersIn: "(\""))
            }
            conns.append(ConnectionEntry(local: f[2], peer: f[3], state: "ESTAB", process: proc))
        }
        for line in s["netstat"] ?? [] {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 6 else { continue }
            conns.append(ConnectionEntry(local: f[3], peer: f[4], state: f[5], process: ""))
        }
        // An SSH connection is one to a port sshd listens on — not necessarily 22.
        var ports = Set(sshPorts(s["sshports"] ?? []))
        let own = (s["conn"]?.first ?? "").split(separator: " ")
        if own.count >= 4 { ports.insert(String(own[3])) }
        if ports.isEmpty { ports = ["22"] }
        for i in conns.indices {
            conns[i].isSSH = ports.contains(ConnectionEntry.port(of: conns[i].local)) || conns[i].process == "sshd"
        }
        return (logins, conns.sorted { ($0.isSSH ? 0 : 1, $0.local) < ($1.isSSH ? 0 : 1, $1.local) })
    }

    /// tmux/screen sessions on the host. An empty prefix lists all of them.
    public static func remoteSessions(_ text: String, prefix: String = "") -> [RemoteSessionEntry] {
        let s = sections(text)
        var out: [RemoteSessionEntry] = []
        for line in s["tmux"] ?? [] {
            let f = line.split(separator: "|").map(String.init)
            guard f.count >= 3, prefix.isEmpty || f[0].hasPrefix(prefix) else { continue }
            let created = Double(f[1]).map { Date(timeIntervalSince1970: $0) }
            out.append(RemoteSessionEntry(kind: .tmux, name: f[0], created: created, attached: f[2] != "0",
                                          windows: f.count > 3 ? Int(f[3]) : nil,
                                          lastActivity: f.count > 4 ? Double(f[4]).map { Date(timeIntervalSince1970: $0) } : nil))
        }
        for line in s["screen"] ?? [] {
            // "\t12345.tether-abc\t(Detached)"
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let first = t.split(whereSeparator: { $0 == "\t" || $0 == " " }).first,
                  let dot = first.firstIndex(of: ".") else { continue }
            let name = String(first[first.index(after: dot)...])
            guard prefix.isEmpty || name.hasPrefix(prefix) else { continue }
            out.append(RemoteSessionEntry(kind: .screen, name: name, created: nil, attached: t.contains("Attached")))
        }
        return out
    }
}
