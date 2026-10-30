import Foundation
import os

/// What happened to connections — sign-ins, checks, connections closed, tabs re-attaching, sleep
/// and network events — so a problem can be followed afterwards.
///
/// - In Tether (Help ▸ Connection Log): the last events, in memory only, to read or copy into a
///   bug report. Never written to a file.
/// - In macOS's own log (Console.app, subsystem `io.github.whileendless.tether`, category
///   `connections`): host names and paths are marked private, so macOS shows them only on this
///   Mac's own request.
///
/// Never passwords, passphrases, one-time codes or anything typed: only what happened, to which
/// host, and why.
public final class ConnectionLog: @unchecked Sendable {
    public static let shared = ConnectionLog()

    public enum Level: String, Sendable, CaseIterable, Comparable {
        case info, notice, problem
        public static func < (a: Level, b: Level) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    /// What an event is about, to narrow the list down.
    public enum Category: String, Sendable, CaseIterable {
        /// Shared connections: opened, reused, checked, ended.
        case connection
        /// Signing in and the questions it asks.
        case signIn
        /// A terminal tab: connecting, ready, letting go, re-attaching, ending.
        case tab
        /// The network and sleep.
        case network
        case forward
        /// Tether itself: started, locked, unlocked.
        case app

        public var title: String {
            switch self {
            case .connection: "Connections"
            case .signIn: "Sign-ins"
            case .tab: "Tabs"
            case .network: "Network and sleep"
            case .forward: "Port forwards"
            case .app: "Tether"
            }
        }
    }

    public struct Entry: Identifiable, Sendable {
        public let id = UUID()
        public let date: Date
        public let level: Level
        public let category: Category
        public let host: String?
        /// The tab it happened in (its title, and the tmux or screen session it shows).
        public let tab: String?
        public let message: String
        /// Text from ssh or the server (may name hosts and addresses: private in macOS's log).
        public let detail: String?
    }

    public static let limit = 3_000
    private let logger = Logger(subsystem: "io.github.whileendless.tether", category: "connections")
    private let lock = NSLock()
    private var entries: [Entry] = []
    /// Called on the main queue after something was added (the log window refreshes).
    public var onChange: (@Sendable () -> Void)? {
        get { lock.withLock { _onChange } }
        set { lock.withLock { _onChange = newValue } }
    }
    private var _onChange: (@Sendable () -> Void)?

    /// `message` is Tether's own fixed wording (public in macOS's log); anything from ssh, a server
    /// or a host's name goes in `host` / `detail` (private there).
    public func info(_ message: String, _ category: Category = .connection, host: String? = nil, tab: String? = nil,
                     detail: String? = nil) { add(.info, category, message, host, tab, detail) }
    public func notice(_ message: String, _ category: Category = .connection, host: String? = nil, tab: String? = nil,
                       detail: String? = nil) { add(.notice, category, message, host, tab, detail) }
    public func problem(_ message: String, _ category: Category = .connection, host: String? = nil, tab: String? = nil,
                        detail: String? = nil) { add(.problem, category, message, host, tab, detail) }

    private func add(_ level: Level, _ category: Category, _ message: String, _ host: String?, _ tab: String?, _ detail: String?) {
        let detail = detail.map { DiagnosticText.detail($0) }.flatMap { $0.isEmpty ? nil : $0 }
        let entry = Entry(date: Date(), level: level, category: category, host: host, tab: tab, message: message, detail: detail)
        lock.withLock {
            entries.append(entry)
            if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        }
        let where_ = [host, tab].compactMap { $0 }.joined(separator: " · "), more = detail ?? ""
        switch level {
        case .info: logger.info("\(message, privacy: .public) [\(where_, privacy: .private)] \(more, privacy: .private)")
        case .notice: logger.notice("\(message, privacy: .public) [\(where_, privacy: .private)] \(more, privacy: .private)")
        case .problem: logger.error("\(message, privacy: .public) [\(where_, privacy: .private)] \(more, privacy: .private)")
        }
        if let onChange { DispatchQueue.main.async { onChange() } }
    }

    public var all: [Entry] { lock.withLock { entries } }

    public func clear() { lock.withLock { entries.removeAll() } }

    /// Everything as plain text, to copy into a bug report (host names included: the user decides).
    public var text: String { Self.text(all) }

    /// `entries` as plain text, oldest first: one line each, ssh's and the server's words indented
    /// below it.
    public static func text(_ entries: [Entry]) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return entries.map { e in
            let place = [e.host, e.tab].compactMap { $0 }.joined(separator: " · ")
            var line = "\(f.string(from: e.date)) \(e.level.rawValue.uppercased()) \(e.category.rawValue)"
                + (place.isEmpty ? "" : " [\(place)]") + " \(e.message)"
            if let detail = e.detail {
                line += "\n" + detail.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n")
            }
            return line
        }.joined(separator: "\n")
    }
}

/// Short forms of program output for the log.
enum DiagnosticText {
    /// What an entry keeps of ssh's or a server's words: the last lines that say something (ssh's
    /// steps through connecting and signing in, its errors), the home folder written `~`.
    static func detail(_ text: String, lines: Int = 16) -> String {
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
            .filter { !$0.hasPrefix("debug") || isMilestone($0) }
            .suffix(lines)
            .map { withoutSecrets(homeAbbreviated($0)) }
            .joined(separator: "\n")
    }

    /// The home folder written `~` — only where it is the whole folder (not `/home/user` in `/home/user2`).
    static func homeAbbreviated(_ line: String, home: String = NSHomeDirectory()) -> String {
        guard home.count > 1 else { return line }
        var out = "", rest = Substring(line)
        while let r = rest.range(of: home) {
            let next = rest[r.upperBound...].first
            out += rest[..<r.lowerBound]
            out += next == nil || next == "/" || next == " " || next == "'" || next == "\"" || next == ":" ? "~" : home
            rest = rest[r.upperBound...]
        }
        return out + rest
    }

    /// A proxy command can hold a secret (`sshpass -p …`): ssh's line naming it is kept without it.
    static func withoutSecrets(_ line: String) -> String {
        for marker in ["Executing proxy command:", "proxy command:"] {
            if let r = line.range(of: marker, options: .caseInsensitive) { return line[..<r.upperBound] + " (not shown)" }
        }
        return line
    }

    /// ssh `-v` lines worth keeping: where it connected, the server's software, the host key, which
    /// ways of signing in the server offered and which one worked — not the protocol chatter.
    static func isMilestone(_ line: String) -> Bool {
        guard line.hasPrefix("debug") else { return true }
        let wanted = ["Connecting to ", "Connection established", "remote software version", "Authenticating to ",
                      "Server host key:", "is known and matches", "Authentications that can continue",
                      "Next authentication method", "Offering public key", "Server accepts key", "Authenticated to ",
                      "Authentication succeeded", "Will attempt key", "setting up multiplex master", "ControlPersist",
                      "connect to address", "proxy", "Proxy", "Executing proxy", "channel_connect_stdio_fwd",
                      "Remote: ", "No more authentication methods", "Permission denied", "timed out", "refused",
                      "Killed by signal", "Exit status", "client_input_channel_req: channel", "Transferred: "]
        return wanted.contains { line.contains($0) }
    }

    /// How ssh signed in (`password`, `publickey`, `keyboard-interactive`), from its `-v` lines.
    static func signInMethod(_ lines: [String]) -> String? {
        for l in lines.reversed() {
            if let r = l.range(of: "Authenticated to "), let u = l.range(of: " using \"", range: r.upperBound..<l.endIndex) {
                return l[u.upperBound...].prefix { $0 != "\"" }.description
            }
            if let r = l.range(of: "Authentication succeeded (") {
                return l[r.upperBound...].prefix { $0 != ")" }.description
            }
        }
        return nil
    }
}
