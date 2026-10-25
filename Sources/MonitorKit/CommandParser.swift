import Foundation
import TetherCore

extension ProbeParser {
    /// Reads the output of `ProbeScripts.command` / `WindowsProbeScripts.command`. Dates are moved
    /// to this Mac's clock (the host's clock may be off). Missing or garbled parts leave fields nil.
    public static func command(_ text: String, anchor: ShellAnchor, receivedAt: Date = Date()) -> CommandFrame {
        let s = sections(text)
        var frame = CommandFrame(takenAt: receivedAt)
        if let p = s["problem"]?.first {
            frame.problem = p == "screen-windows" ? .screenWindows : .noShell
            return frame
        }
        guard let root = s["root"]?.first.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) else {
            frame.problem = .noShell
            return frame
        }
        // Host clock → this Mac's clock.
        let hostNow = s["now"]?.first.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        let offset = hostNow.map { receivedAt.timeIntervalSince1970 - $0 } ?? 0
        let hostTime = hostNow ?? receivedAt.timeIntervalSince1970

        var tree: [CommandProcess]
        if let linux = s["linux"] {
            tree = linuxProcesses(s, header: linux, offset: offset)
        } else if let windows = s["windows"] {
            tree = windowsProcesses(windows, root: root, offset: offset)
        } else {
            tree = bsdProcesses(s["procs"] ?? [], hostTime: hostTime, offset: offset)
        }
        guard !tree.isEmpty || anchor.isWindows else {
            frame.problem = .noShell
            return frame
        }

        switch anchor {
        case .windows:
            frame.shellPid = root
            frame.processes = windowsCommand(tree, shell: root)
        case .screen:
            let windows = tree.filter { $0.ppid == root }
            guard windows.count == 1, let shell = windows.first else {
                frame.problem = windows.isEmpty ? .noShell : .screenWindows
                return frame
            }
            frame.shellPid = shell.pid
            frame.processes = foreground(tree, shell: shell)
        case .posix:
            guard let shell = tree.first(where: { $0.pid == root }) else {
                frame.problem = .noShell
                return frame
            }
            frame.shellPid = root
            frame.processes = foreground(tree, shell: shell)
        }

        let pids = Set(frame.processes.map(\.pid))
        frame.sockets = icmpSockets(s["icmp"] ?? [], processes: frame.processes,
                                    listed: commandSockets(s["sockets"] ?? [], pids: pids) + windowsSockets(s["tcp"] ?? [], pids: pids))
        if let lines = s["flows"] {
            let flows = flows(lines)
            frame.measuresNetwork = true
            for (pid, p) in flows.processes where pids.contains(pid) { frame.networkBytes[pid] = p.counts }
            frame.socketCounters = flows.sockets.filter { pids.contains($0.value.pid) }
        }
        let counted = !frame.networkBytes.isEmpty || frame.socketCounters.values.contains { $0.counts != nil }
        if !frame.sockets.isEmpty && !counted {
            frame.notes.append(anchor.isWindows
                ? "Windows lists the connections but does not count their bytes: no network speed per process."
                : "The host lists the connections but reports no byte counters for them (ss missing, or a Linux kernel older than 4.1): no network speed.")
        }
        return frame
    }

    /// The foreground job of a POSIX shell: the processes of the terminal's foreground group (when
    /// it is not the shell's own) and everything they started. The group's leader comes first.
    static func foreground(_ tree: [CommandProcess], shell: CommandProcess) -> [CommandProcess] {
        guard let fg = shell.terminalGroup, fg > 0, fg != shell.group else { return [] }
        let members = tree.filter { $0.pid != shell.pid && $0.group == fg }
        guard !members.isEmpty else { return [] }
        var included = Set(members.map(\.pid))
        // The tree is breadth-first, so parents come before their children.
        for p in tree where !included.contains(p.pid) && included.contains(p.ppid) { included.insert(p.pid) }
        let leader = members.first { $0.pid == fg }
            ?? members.min { ($0.started ?? .distantFuture, $0.pid) < ($1.started ?? .distantFuture, $1.pid) }!
        return [leader] + tree.filter { included.contains($0.pid) && $0.pid != leader.pid }
    }

    /// Windows has no foreground group: the newest program the shell started leads, and every
    /// process below the shell belongs to the command (console hosts aside).
    static func windowsCommand(_ tree: [CommandProcess], shell: Int) -> [CommandProcess] {
        let consoleHosts: Set<String> = ["conhost.exe", "openconsole.exe"]
        let real = tree.filter { !consoleHosts.contains($0.name.lowercased()) }
        guard let leader = real.filter({ $0.ppid == shell }).max(by: { ($0.started ?? .distantPast, $0.pid) < ($1.started ?? .distantPast, $1.pid) }) else { return [] }
        return [leader] + real.filter { $0.pid != leader.pid }
    }

    // MARK: Platforms

    static func linuxProcesses(_ s: [String: [String]], header: [String], offset: TimeInterval) -> [CommandProcess] {
        let hz = header.count > 0 ? max(Double(header[0].trimmingCharacters(in: .whitespaces)) ?? 100, 1) : 100
        let page = header.count > 1 ? Int64(header[1].trimmingCharacters(in: .whitespaces)) ?? 4096 : 4096
        let boot = header.count > 2 ? Double(header[2].trimmingCharacters(in: .whitespaces)) : nil
        var users: [String: String] = [:]
        for line in s["users"] ?? [] {
            let f = line.split(separator: " ", maxSplits: 1).map(String.init)
            if f.count == 2 { users[f[0]] = f[1] }
        }
        var commands: [Int: String] = [:]
        for line in s["cmdline"] ?? [] {
            let f = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if f.count == 2, let pid = Int(f[0]) { commands[pid] = f[1].trimmingCharacters(in: .whitespaces) }
        }
        var details: [Int: (uid: String, io: (Int64, Int64)?, command: String)] = [:]
        for line in s["detail"] ?? [] {
            let f = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, let pid = Int(f[0]) else { continue }
            let io = f[2].split(separator: " ").compactMap { Int64($0) }
            details[pid] = (f[1], io.count == 2 ? (io[0], io[1]) : nil,
                            f.count > 3 ? f[3].trimmingCharacters(in: .whitespaces) : commands[pid] ?? "")
        }
        // A process whose owner could not be read still has its command line.
        for (pid, command) in commands where details[pid] == nil { details[pid] = ("-", nil, command) }
        return (s["procs"] ?? []).compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 9, let pid = Int(f[0]), let ppid = Int(f[1]) else { return nil }
            var p = CommandProcess(pid: pid, ppid: ppid, group: Int(f[2]), terminalGroup: Int(f[3]), state: f[4])
            p.cpuSeconds = Double(f[5]).map { $0 / hz }
            p.threads = Int(f[6])
            if let boot, let ticks = Double(f[7]) {
                p.hostStarted = boot + ticks / hz
                p.started = Date(timeIntervalSince1970: boot + ticks / hz + offset)
            }
            p.rssBytes = Int64(f[8]).map { $0 * page }
            if let d = details[pid] {
                p.user = users[d.uid] ?? d.uid
                p.readBytes = d.io?.0
                p.writeBytes = d.io?.1
                p.commandLine = d.command
            }
            return p
        }
    }

    /// `pid ppid pgid tpgid stat uid user time rss etime args` from ps (macOS, the BSDs).
    static func bsdProcesses(_ lines: [String], hostTime: TimeInterval, offset: TimeInterval) -> [CommandProcess] {
        lines.compactMap { line in
            let f = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 10, let pid = Int(f[0]), let ppid = Int(f[1]) else { return nil }
            var p = CommandProcess(pid: pid, ppid: ppid, group: Int(f[2]), terminalGroup: Int(f[3]), user: f[6], state: f[4])
            p.cpuSeconds = clockSeconds(f[7])
            p.rssBytes = Int64(f[8]).map { $0 * 1024 }
            if let elapsed = clockSeconds(f[9]) {
                p.hostStarted = hostTime - elapsed
                p.started = Date(timeIntervalSince1970: hostTime - elapsed + offset)
            }
            p.commandLine = f.count > 10 ? f[10] : ""
            return p
        }
    }

    /// `pid ppid cpu ws threads start read write user command`, tab-separated (PowerShell).
    static func windowsProcesses(_ lines: [String], root: Int, offset: TimeInterval) -> [CommandProcess] {
        lines.compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 10, let pid = Int(f[0]), let ppid = Int(f[1]) else { return nil }
            var p = CommandProcess(pid: pid, ppid: ppid, user: f[8].isEmpty ? "-" : f[8])
            p.cpuSeconds = Double(f[2])
            p.rssBytes = Int64(f[3])
            p.threads = Int(f[4])
            p.hostStarted = Double(f[5])
            p.started = Double(f[5]).map { Date(timeIntervalSince1970: $0 + offset) }
            p.readBytes = Int64(f[6])
            p.writeBytes = Int64(f[7])
            p.commandLine = f[9]
            return p
        }
    }

    /// `[[dd-]hh:]mm:ss[.cc]` (ps `time` and `etime`) in seconds.
    static func clockSeconds(_ text: String) -> Double? {
        var days = 0.0
        var rest = Substring(text)
        if let dash = rest.firstIndex(of: "-") {
            guard let d = Double(rest[..<dash]) else { return nil }
            days = d
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, !parts.contains(where: { $0 == nil }) else { return nil }
        let total = parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        return days * 86_400 + total
    }

    // MARK: Sockets

    /// Lines `pid<TAB>…` from ss, netstat or lsof.
    static func commandSockets(_ lines: [String], pids: Set<Int>) -> [CommandSocket] {
        lines.compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, let pid = Int(parts[0]), pids.contains(pid) else { return nil }
            let f = parts[1].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 5 else { return nil }
            let proto = f[0].lowercased()
            if proto.hasPrefix("tcp") || proto.hasPrefix("udp") {
                if Int(f[1]) != nil {
                    // netstat: Proto Recv-Q Send-Q Local Foreign [State] PID/Program
                    let state = f.count > 6 ? f[5] : "-"
                    return CommandSocket(proto: String(proto.prefix(3)).uppercased(), state: state, local: f[3], peer: f[4], pid: pid)
                }
                // ss: Netid State Recv-Q Send-Q Local Peer Process
                guard f.count >= 6 else { return nil }
                return CommandSocket(proto: proto.uppercased(), state: f[1], local: f[4], peer: f[5], pid: pid)
            }
            // lsof: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME [(STATE)]
            guard f.count >= 9, ["TCP", "UDP", "ICMP", "ICMPV6"].contains(f[7].uppercased()) else { return nil }
            let ends = f[8].components(separatedBy: "->")
            var state = "-"
            if f.count > 9 { state = f[9].trimmingCharacters(in: CharacterSet(charactersIn: "()")) }
            return CommandSocket(proto: f[7], state: state, local: ends[0], peer: ends.count > 1 ? ends[1] : "*:*", pid: pid)
        }
    }

    /// `proto state local peer pid`, tab-separated (PowerShell).
    static func windowsSockets(_ lines: [String], pids: Set<Int>) -> [CommandSocket] {
        lines.compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let pid = Int(f[4]), pids.contains(pid) else { return nil }
            return CommandSocket(proto: f[0], state: f[1], local: f[2], peer: f[3], pid: pid)
        }
    }
}

extension ProbeParser {
    /// The output of the batched probe (`ProbeScripts.command` with several terminals): one frame
    /// per anchor, in order. A terminal missing from the output gets a frame saying its shell is gone.
    public static func commandBatch(_ text: String, anchors: [ShellAnchor], receivedAt: Date = Date()) -> [CommandFrame] {
        var shared: [Substring] = []
        var chunks: [Int: [Substring]] = [:]
        var current: Int?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@@tab ") {
                current = Int(line.dropFirst(7).trimmingCharacters(in: .whitespaces))
                if let current { chunks[current] = [] }
            } else if let current {
                chunks[current, default: []].append(line)
            } else {
                shared.append(line)
            }
        }
        let head = shared.joined(separator: "\n")
        return anchors.indices.map { i in
            guard let body = chunks[i] else { return CommandFrame(takenAt: receivedAt, problem: .noShell) }
            return command(head + "\n" + body.joined(separator: "\n"), anchor: anchors[i], receivedAt: receivedAt)
        }
    }

    /// Programs that send ICMP (ping and the like) and take the target as their last plain word.
    static let icmpTools: Set<String> = ["ping", "ping6", "fping", "fping6", "ping.exe", "tracert", "tracert.exe",
                                         "pathping", "pathping.exe", "mtr", "arping", "hping3", "nping"]

    /// ICMP and raw sockets (Linux /proc/net; lsof lists them with the others), plus the target of
    /// ping-like programs taken from their command line where no socket shows it — Windows sends
    /// ICMP without a socket a program can see, and ICMP sockets have no peer.
    static func icmpSockets(_ lines: [String], processes: [CommandProcess], listed: [CommandSocket]) -> [CommandSocket] {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        // ICMP sockets lsof listed: their target comes from the command line too.
        var result = listed.map { s -> CommandSocket in
            guard !s.proto.uppercased().hasPrefix("TCP"), !s.proto.uppercased().hasPrefix("UDP"), s.peer.hasPrefix("*") else { return s }
            var s = s
            s.proto = "ICMP"
            s.peer = icmpTarget(byPid[s.pid]?.commandLine ?? "") ?? "*"
            return s
        }
        var seen = Set(result.filter { $0.proto == "ICMP" }.map { "\($0.pid) ICMP" })
        for line in lines {
            let f = line.split(separator: "\t").map(String.init)
            guard f.count >= 2, let pid = Int(f[0]), byPid[pid] != nil, seen.insert("\(pid) \(f[1])").inserted else { continue }
            result.append(CommandSocket(proto: f[1], state: "-", local: "*", peer: icmpTarget(byPid[pid]?.commandLine ?? "") ?? "*", pid: pid))
        }
        for p in processes where icmpTools.contains(p.name.lowercased()) && !seen.contains("\(p.pid) ICMP") {
            guard let target = icmpTarget(p.commandLine) else { continue }
            result.append(CommandSocket(proto: "ICMP", state: "from command line", local: "*", peer: target, pid: p.pid))
        }
        return result
    }

    /// The target of a ping-like command: the last word that looks like a host (a name, an IPv4
    /// address with four parts, or an IPv6 address), not an option or an option's number:
    /// `ping -c 3 192.0.2.1`, `ping 192.0.2.1 -i 0.2`, `ping -t example.com`.
    static func icmpTarget(_ commandLine: String) -> String? {
        let words = commandLine.split(separator: " ").map(String.init).dropFirst()
        return words.last { w in
            guard !w.hasPrefix("-"), !w.hasPrefix("/"), w.count <= 255 else { return false }
            if w.contains(":") { return true }
            if w.contains(where: \.isLetter) { return true }
            let parts = w.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
        }
    }
}

extension ShellAnchor {
    var isWindows: Bool {
        if case .windows = self { return true }
        return false
    }

    /// The arguments of the command probe for this anchor.
    var probeArguments: [String] {
        switch self {
        case .posix(let pid): ["pid", String(pid)]
        case .screen(let session): ["screen", session]
        case .windows(let tag): [tag]
        }
    }
}
