import Foundation

/// One process of the command running in a terminal. Everything a host may not tell is optional.
public struct CommandProcess: Identifiable, Hashable, Sendable {
    public var pid: Int
    public var ppid: Int
    /// Process group (POSIX).
    public var group: Int?
    /// The terminal's foreground process group, as this process sees it (POSIX).
    public var terminalGroup: Int?
    public var user: String
    /// R, S, D, T, Z … (POSIX), "-" when unknown.
    public var state: String
    /// CPU time used since it started (user + system), in seconds.
    public var cpuSeconds: Double?
    public var rssBytes: Int64?
    public var threads: Int?
    public var started: Date?
    /// The start on the host's own clock (epoch seconds): steady between looks, so it identifies
    /// the process (`started` moves with the clock offset measured at each look).
    public var hostStarted: Double?
    public var commandLine: String
    /// Bytes read from / written to storage since it started (Linux /proc/<pid>/io, Windows I/O counters).
    public var readBytes: Int64?
    public var writeBytes: Int64?
    public var id: Int { pid }

    /// Executable name without path or arguments.
    public var name: String { Self.programName(commandLine) }

    /// The program of a command line: `/usr/bin/python3 x.py` → python3, `-bash` → bash,
    /// `"C:\Program Files\nodejs\node.exe" app.js` → node.exe.
    static func programName(_ commandLine: String) -> String {
        let line = commandLine.trimmingCharacters(in: .whitespaces)
        var first: Substring
        if line.hasPrefix("\""), let close = line.dropFirst().firstIndex(of: "\"") {
            first = line[line.index(after: line.startIndex)..<close]
        } else {
            first = line.split(separator: " ").first ?? Substring(line)
        }
        if let slash = first.lastIndex(where: { $0 == "/" || $0 == "\\" }) { first = first[first.index(after: slash)...] }
        return first.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public init(pid: Int, ppid: Int, group: Int? = nil, terminalGroup: Int? = nil, user: String = "-", state: String = "-",
                cpuSeconds: Double? = nil, rssBytes: Int64? = nil, threads: Int? = nil, started: Date? = nil,
                commandLine: String = "", readBytes: Int64? = nil, writeBytes: Int64? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.group = group
        self.terminalGroup = terminalGroup
        self.user = user
        self.state = state
        self.cpuSeconds = cpuSeconds
        self.rssBytes = rssBytes
        self.threads = threads
        self.started = started
        self.commandLine = commandLine
        self.readBytes = readBytes
        self.writeBytes = writeBytes
    }
}

/// A socket one of the command's processes has open.
public struct CommandSocket: Identifiable, Hashable, Sendable {
    public var proto: String
    public var state: String
    public var local: String
    public var peer: String
    public var pid: Int
    public var id: String { "\(pid) \(proto) \(local) \(peer)" }

    public init(proto: String, state: String, local: String, peer: String, pid: Int) {
        self.proto = proto
        self.state = state
        self.local = local
        self.peer = peer
        self.pid = pid
    }
}

/// Bytes a process sent and received.
public struct ByteCounts: Hashable, Sendable {
    public var received: Int64
    public var sent: Int64
    public init(received: Int64, sent: Int64) {
        self.received = received
        self.sent = sent
    }
}

/// One look at the command running in a terminal.
public struct CommandFrame: Sendable {
    public enum Problem: Equatable, Sendable {
        /// The shell is not running any more.
        case noShell
        /// Several screen windows: which one is shown cannot be told.
        case screenWindows
    }

    public var takenAt: Date
    public var problem: Problem?
    /// The shell's pid on the host.
    public var shellPid: Int?
    /// The command's processes: the one started from the shell first, then those it started.
    /// Empty while the shell waits for input.
    public var processes: [CommandProcess] = []
    public var sockets: [CommandSocket] = []
    /// Network bytes per pid since each process started, when the host can tell (macOS).
    public var networkBytes: [Int: ByteCounts] = [:]
    /// The command's connections with byte counters, by `SocketCounter.key` (Linux TCP, macOS).
    public var socketCounters: [String: SocketCounter] = [:]
    /// The host reports network use for this command (zero traffic is then a real zero).
    public var measuresNetwork = false
    /// What this look could not find out, for the diagnostics (never an error on screen).
    public var notes: [String] = []

    public var leader: CommandProcess? { processes.first }
    public var isIdle: Bool { processes.isEmpty }

    public init(takenAt: Date = Date(), problem: Problem? = nil, shellPid: Int? = nil) {
        self.takenAt = takenAt
        self.problem = problem
        self.shellPid = shellPid
    }
}
