import Foundation

/// How a terminal session survives network drops on the remote side.
public enum PersistenceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Prefer tmux control mode, then GNU screen, then a plain shell.
    case auto
    case tmux
    case screen
    /// No remote persistence: a plain login shell.
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "Automatic"
        case .tmux: "tmux (control mode)"
        case .screen: "GNU screen"
        case .off: "Off (plain shell)"
        }
    }
}

/// The kind of shell a host gives us, detected on first contact and remembered.
public enum RemotePlatform: String, Codable, Sendable {
    /// Linux, macOS, BSD and other Unix-like systems (POSIX `sh` available).
    case posix
    /// Windows with OpenSSH and cmd.exe as the default shell.
    case windowsCmd
    /// Windows with OpenSSH and PowerShell as the default shell.
    case windowsPowerShell

    public var isWindows: Bool { self != .posix }

    public var title: String {
        switch self {
        case .posix: "Unix-like"
        case .windowsCmd: "Windows (cmd)"
        case .windowsPowerShell: "Windows (PowerShell)"
        }
    }

    /// Remote command whose output tells the shells apart:
    /// sh prints `TETHER:%OS%::`, cmd expands `%OS%` to `Windows_NT`, PowerShell expands `$PSHOME`.
    public static let probeCommand = #"echo "TETHER:%OS%:$PSHOME:""#

    public static func parse(probeOutput: String) -> RemotePlatform? {
        guard let line = probeOutput.split(whereSeparator: \.isNewline).first(where: { $0.contains("TETHER:") }) else { return nil }
        if line.contains("Windows_NT") { return .windowsCmd }
        // Nothing expanded: not a shell's answer but the command shown back (a device CLI's error).
        if line.contains("TETHER:%OS%:$PSHOME") { return nil }
        guard let r = line.range(of: "TETHER:%OS%:") else { return .posix }
        let rest = line[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "\" \r"))
        return rest == ":" || rest.isEmpty || rest.hasPrefix("$PSHOME") ? .posix : .windowsPowerShell
    }
}

/// How Tether may use a host beyond the terminal: run its small scripts (monitoring, files,
/// persistence), or — for network devices, firewalls and limited shells (Cisco, Junos, FortiOS,
/// RouterOS, menus, git-shell) — only open the device's own command line and send it nothing else.
public enum ShellAccess: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Detected on first contact.
    case automatic
    /// A shell Tether can run scripts with (POSIX sh, or PowerShell on Windows).
    case scripts
    /// A device or limited shell: a plain login only.
    case device

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .scripts: "Shell (Linux, macOS, BSD, Windows)"
        case .device: "Network device or limited shell"
        }
    }

    public init(from decoder: Decoder) throws {
        self = ShellAccess(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .automatic
    }

    /// The second question asked when the first got no shell's answer: any shell (sh, csh, fish,
    /// cmd, PowerShell) prints exactly `TETHER-SHELL`; a device CLI prints an error or the line itself.
    public static let shellProbeCommand = "echo TETHER-SHELL"

    public static func answersShell(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == "TETHER-SHELL" }
    }
}

/// A label colour for hosts, groups and tabs.
public enum TagColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, red, orange, yellow, green, mint, teal, blue, indigo, purple, pink, gray
    public var id: String { rawValue }
}

/// A user-defined folder in the sidebar.
public struct HostGroup: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var color: TagColor
    public var isExpanded: Bool

    public init(id: UUID = UUID(), name: String, color: TagColor = .none, isExpanded: Bool = true) {
        self.id = id
        self.name = name
        self.color = color
        self.isExpanded = isExpanded
    }
}

/// Tether-only data attached to an SSH config host. Kept outside ~/.ssh/config so the
/// config file stays clean and portable.
public struct HostMetadata: Codable, Hashable, Sendable {
    public var groupID: UUID?
    public var color: TagColor
    public var persistence: PersistenceMode?
    public var favorite: Bool
    public var notes: String
    /// Remembered directory for the file browser.
    public var lastRemoteDirectory: String?
    /// Whether logging in with a key (no password) was verified to work. nil = not checked yet.
    public var keyLoginWorks: Bool?
    /// Saved port forwards for this host.
    public var forwards: [PortForward]?
    /// Detected shell/OS family (nil = not detected yet).
    public var platform: RemotePlatform?
    /// Found to be a network device or limited shell on first contact (see `ShellAccess`).
    public var detectedDevice: Bool?
    /// The user's choice, over what was detected.
    public var shellAccess: ShellAccess?
    /// This host's own choices for `HostFeature`s (raw value → on/off); absent ones follow the
    /// system setting.
    public var features: [String: Bool]?

    public init(groupID: UUID? = nil, color: TagColor = .none, persistence: PersistenceMode? = nil,
                favorite: Bool = false, notes: String = "", lastRemoteDirectory: String? = nil) {
        self.groupID = groupID
        self.color = color
        self.persistence = persistence
        self.favorite = favorite
        self.notes = notes
        self.lastRemoteDirectory = lastRemoteDirectory
    }
}

/// The library of groups and per-host metadata, keyed by SSH config alias.
public struct HostLibrary: Codable, Sendable {
    public var groups: [HostGroup]
    public var metadata: [String: HostMetadata]
    /// User-defined sidebar order of host aliases. Hosts not listed keep their config file order.
    public var hostOrder: [String]

    public init(groups: [HostGroup] = [], metadata: [String: HostMetadata] = [:], hostOrder: [String] = []) {
        self.groups = groups
        self.metadata = metadata
        self.hostOrder = hostOrder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([HostGroup].self, forKey: .groups) ?? []
        metadata = try c.decodeIfPresent([String: HostMetadata].self, forKey: .metadata) ?? [:]
        hostOrder = try c.decodeIfPresent([String].self, forKey: .hostOrder) ?? []
    }
}

/// What to connect to: either an alias from ssh config or an ad-hoc destination.
public enum ConnectionTarget: Codable, Hashable, Sendable {
    case alias(String)
    /// A shell on this Mac.
    case local
    /// A destination typed in directly (not saved in ssh config). `identity` is an optional key file.
    case adhoc(user: String?, host: String, port: Int?, jump: String?, identity: String? = nil)

    /// Stable key used to group sessions and look up metadata.
    public var key: String {
        switch self {
        case .local: "local"
        case .alias(let name): name
        case .adhoc(let user, let host, let port, _, _):
            (user.map { "\($0)@" } ?? "") + host + (port.map { ":\($0)" } ?? "")
        }
    }

    public var displayName: String {
        if case .local = self { return "This Mac" }
        return key
    }

    public var isLocal: Bool { if case .local = self { true } else { false } }

    /// Parses quick-connect input such as `user@host:2222 -J jump.example.com` or an alias.
    public static func parse(_ input: String, knownAliases: Set<String>) -> ConnectionTarget? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if knownAliases.contains(trimmed) { return .alias(trimmed) }

        var tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var jump: String?
        var port: Int?
        var i = 0
        var rest: [String] = []
        while i < tokens.count {
            let t = tokens[i]
            if (t == "-J" || t == "-p"), i + 1 < tokens.count {
                if t == "-J" { jump = tokens[i + 1] } else { port = Int(tokens[i + 1]) }
                i += 2
                continue
            }
            rest.append(t)
            i += 1
        }
        tokens = rest
        guard var dest = tokens.first else { return nil }
        if dest.hasPrefix("ssh://") { dest.removeFirst(6) }
        var user: String?
        if let at = dest.lastIndex(of: "@") {
            user = String(dest[..<at])
            dest = String(dest[dest.index(after: at)...])
        }
        // host:port (but not IPv6 literals without brackets)
        if dest.hasPrefix("["), let close = dest.firstIndex(of: "]") {
            let host = String(dest[dest.index(after: dest.startIndex)..<close])
            let after = dest[dest.index(after: close)...]
            if after.hasPrefix(":") { port = Int(after.dropFirst()) ?? port }
            dest = host
        } else if dest.filter({ $0 == ":" }).count == 1, let colon = dest.firstIndex(of: ":") {
            port = Int(dest[dest.index(after: colon)...]) ?? port
            dest = String(dest[..<colon])
        }
        guard !dest.isEmpty else { return nil }
        if user == nil, port == nil, jump == nil, knownAliases.contains(dest) { return .alias(dest) }
        return .adhoc(user: user, host: dest, port: port, jump: jump)
    }
}

/// Lifecycle of a terminal session as shown in the UI.
public enum SessionPhase: Equatable, Sendable {
    /// Establishing the SSH connection for the first time.
    case connecting
    /// Connected and accepting input.
    case online
    /// Connection lost; retrying. History stays visible, input is blocked.
    case waiting(attempt: Int, nextRetry: Date?)
    /// Disconnected on purpose; the tmux/screen session keeps running on the server and is
    /// re-attached when the session is opened again.
    case suspended
    /// The remote session is confirmed gone (or exited). Read-only forever.
    case dead(reason: String)

    public var isOnline: Bool { if case .online = self { true } else { false } }
    public var isSuspended: Bool { self == .suspended }
    public var isDead: Bool { if case .dead = self { true } else { false } }
    public var acceptsInput: Bool { isOnline }

    public var label: String {
        switch self {
        case .connecting: "Connecting"
        case .online: "Online"
        case .waiting: "Waiting"
        case .suspended: "Suspended"
        case .dead: "Dead"
        }
    }
}

/// The concrete persistence backend negotiated with the remote host.
public enum ActivePersistence: String, Codable, Sendable {
    case tmux, screen, plain, unknown
}

/// Saved description of an open tab so it can be restored (and reattached) after relaunch.
public struct SessionDescriptor: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var target: ConnectionTarget
    public var title: String
    public var customTitle: Bool
    public var color: TagColor
    public var persistence: PersistenceMode
    /// Name of the tmux/screen session on the remote host.
    public var remoteSessionName: String
    /// Directory to start a new session in (e.g. "Open Terminal Here" from the file browser).
    public var initialDirectory: String?
    public var createdAt: Date
    /// Stored optional so sessions saved by older versions still decode.
    private var privateSession: Bool?
    /// A private session leaves nothing behind on this Mac: no recording, no archive entry, no
    /// command history.
    public var isPrivate: Bool {
        get { privateSession ?? false }
        set { privateSession = newValue ? true : nil }
    }

    public init(id: UUID = UUID(), target: ConnectionTarget, title: String? = nil, color: TagColor = .none,
                persistence: PersistenceMode, createdAt: Date = Date()) {
        self.id = id
        self.target = target
        self.title = title ?? target.displayName
        self.customTitle = title != nil
        self.color = color
        self.persistence = persistence
        self.remoteSessionName = "tether-" + id.uuidString.prefix(8).lowercased()
        self.createdAt = createdAt
    }
}

/// A finished session whose transcript is kept in the recordings directory.
public struct ArchivedSession: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var target: ConnectionTarget
    public var title: String
    public var startedAt: Date
    public var endedAt: Date
    public var reason: String
    public var recordingPath: String?
    /// Secrets masked in the recording when it was archived (nil: not done yet, see
    /// `SessionManager.redactArchive`).
    public var secretsRedacted: Int?

    public init(id: UUID, target: ConnectionTarget, title: String, startedAt: Date, endedAt: Date,
                reason: String, recordingPath: String?) {
        self.id = id
        self.target = target
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.reason = reason
        self.recordingPath = recordingPath
    }
}
