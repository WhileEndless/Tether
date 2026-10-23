import Foundation
import Observation

public enum TerminalThemeChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Mirrors Terminal.app's "Basic" profile and follows the system appearance.
    case system
    case light
    case dark
    case solarizedDark
    case solarizedLight

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: "Terminal.app profile"
        case .light: "Light"
        case .dark: "Dark"
        case .solarizedDark: "Solarized Dark"
        case .solarizedLight: "Solarized Light"
        }
    }
}

public enum CursorShape: String, Codable, CaseIterable, Identifiable, Sendable {
    case block, underline, bar
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum BellMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, visual, sound
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum HostKeyPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Use whatever ssh config says (prompts for unknown keys).
    case ask
    /// Accept keys of new hosts automatically, still refuse changed keys.
    case acceptNew

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .ask: "Ask (ssh default)"
        case .acceptNew: "Accept new, reject changed"
        }
    }
}

/// A user-defined key binding that sends text to the terminal.
public struct KeyMapping: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// A single character (lowercased) or one of: left, right, up, down, delete, forwarddelete,
    /// home, end, pageup, pagedown, return, tab, escape, space.
    public var key: String
    public var command: Bool
    public var option: Bool
    public var control: Bool
    public var shift: Bool
    /// Text to send. Supports escapes: \e \n \r \t \\ \xHH \uHHHH.
    public var send: String
    public var enabled: Bool

    public init(id: UUID = UUID(), key: String, command: Bool = false, option: Bool = false,
                control: Bool = false, shift: Bool = false, send: String, enabled: Bool = true) {
        self.id = id
        self.key = key
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
        self.send = send
        self.enabled = enabled
    }

    public var shortcutDescription: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        let names: [String: String] = [
            "left": "←", "right": "→", "up": "↑", "down": "↓", "delete": "⌫", "forwarddelete": "⌦",
            "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟", "return": "↩", "tab": "⇥",
            "escape": "⎋", "space": "Space",
        ]
        return s + (names[key] ?? key.uppercased())
    }

    /// Decodes the escape notation in `send` into raw bytes.
    public var bytes: [UInt8] { KeyMapping.decodeEscapes(send) }

    public static func decodeEscapes(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        var chars = Array(text.unicodeScalars)[...]
        while let c = chars.popFirst() {
            guard c == "\\", let n = chars.popFirst() else {
                out.append(contentsOf: Array(String(c).utf8))
                continue
            }
            switch n {
            case "e", "E": out.append(0x1b)
            case "n": out.append(0x0a)
            case "r": out.append(0x0d)
            case "t": out.append(0x09)
            case "\\": out.append(0x5c)
            case "x":
                let hex = String(String.UnicodeScalarView(chars.prefix(2)))
                if let v = UInt8(hex, radix: 16) { out.append(v); chars = chars.dropFirst(2) }
            case "u":
                let hex = String(String.UnicodeScalarView(chars.prefix(4)))
                if let v = UInt32(hex, radix: 16), let s = Unicode.Scalar(v) {
                    out.append(contentsOf: Array(String(s).utf8)); chars = chars.dropFirst(4)
                }
            default:
                out.append(0x5c)
                out.append(contentsOf: Array(String(n).utf8))
            }
        }
        return out
    }

    /// Sensible macOS-style navigation shortcuts for shells (readline/zle).
    public static let macDefaults: [KeyMapping] = [
        KeyMapping(key: "left", command: true, send: "\\x01"),        // beginning of line
        KeyMapping(key: "right", command: true, send: "\\x05"),       // end of line
        KeyMapping(key: "left", option: true, send: "\\eb"),          // word back
        KeyMapping(key: "right", option: true, send: "\\ef"),         // word forward
        KeyMapping(key: "delete", command: true, send: "\\x15"),      // kill line
        KeyMapping(key: "delete", option: true, send: "\\e\\x7f"),    // delete word
    ]
}

/// Whether many files travel as one tar stream (packed here, unpacked on the other side).
public enum TransferArchiveMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Pack when a transfer has many files (see `transferArchiveThreshold`).
    case auto
    case always
    /// Always send files one by one (in parallel).
    case never

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "When there are many files"
        case .always: "Always"
        case .never: "Never (send files one by one)"
        }
    }
}

/// All user preferences. Persisted as JSON in UserDefaults.
public struct AppSettings: Codable, Equatable, Sendable {
    // General
    public var restoreSessionsOnLaunch = true
    public var confirmCloseOnlineSessions = true
    public var openNewSessionsInWindow = false
    public var showSidebarArchive = false

    // Terminal
    public var fontName: String = ""          // empty = system monospaced
    public var fontSize: Double = 12
    public var theme: TerminalThemeChoice = .system
    /// Terminal.app profile to mirror when `theme == .system`; empty = Terminal's default profile.
    public var terminalProfile: String = ""
    /// Use the Terminal.app profile's font and size.
    public var fontFromProfile = true
    public var cursorShape: CursorShape = .block
    public var cursorBlink = false            // Terminal.app default; blinking costs CPU in every tab
    public var scrollbackLines = 10_000
    public var bell: BellMode = .visual
    public var allowMouseReporting = true
    public var copyOnSelect = false

    // Keyboard
    public var optionAsMeta = true
    public var keyMappings: [KeyMapping] = KeyMapping.macDefaults

    // Sessions
    public var defaultPersistence: PersistenceMode = .auto
    public var autoReconnect = true
    public var maxReconnectAttempts = 0       // 0 = unlimited
    public var reconnectBaseDelay: Double = 2
    public var reconnectMaxDelay: Double = 30
    public var serverAliveInterval = 10
    public var serverAliveCountMax = 3
    public var historyLinesOnReattach = 5_000
    /// Seconds without any answer from the server before a session is considered disconnected.
    public var stallTimeout: Double = 6

    // Recordings
    public var recordingEnabled = true
    public var recordingQuotaMB = 1024
    public var recordingRetentionDays = 0     // 0 = keep until quota
    /// Compress recordings older than this many days (0 = never).
    public var compressRecordingsAfterDays = 7

    // Monitoring
    public var monitorRefreshInterval: Double = 5
    public var monitorAutoLoad = true
    /// Compact live CPU / memory / disk / GPU / latency bar above each terminal.
    public var showStatusStrip = true
    public var confirmKill = true
    public var logLines = 300

    // Transfers
    /// Files sent at the same time (each with its own scp).
    public var transferParallel = 3
    /// When several files are packed into one tar stream instead of being sent one by one.
    public var transferArchiveMode: TransferArchiveMode = .auto
    /// `.auto` packs transfers with at least this many files.
    public var transferArchiveThreshold = 20
    /// Compress packed transfers on the wire (ssh -C). Helps on slow links, costs CPU on fast ones.
    public var transferCompress = true

    // Updates
    /// At launch, ask GitHub once whether a newer release exists (one request to api.github.com).
    public var checkForUpdates = true

    // Passwords
    /// Ask for Touch ID (or the Mac's password) before a saved password is used.
    public var requireAuthForSavedPasswords = true
    /// After a successful check, saved passwords can be used without asking again for this long (seconds).
    public var authGraceSeconds = 300
    /// Notice password prompts in terminals (sudo, su, ssh, …) and offer to fill a saved password.
    public var detectPasswordPrompts = true

    // SSH
    public var sshConfigPath: String = ""     // empty = ~/.ssh/config
    public var sshBinary = "/usr/bin/ssh"
    public var scpBinary = "/usr/bin/scp"
    public var useControlMaster = true
    public var controlPersistSeconds = 600
    public var hostKeyPolicy: HostKeyPolicy = .ask

    /// Bumped when defaults change in a way existing users should get too (see `migrate`).
    public var version = AppSettings.currentVersion
    public static let currentVersion = 3

    public init() {}

    /// Applies changed defaults to settings saved by older versions.
    public mutating func migrate() {
        if version < 2 {
            cursorBlink = false
            if monitorRefreshInterval < 5 { monitorRefreshInterval = 5 }
        }
        if version < 3 {
            showSidebarArchive = false
        }
        version = Self.currentVersion
    }

    public var resolvedSSHConfigURL: URL {
        if sshConfigPath.isEmpty { return AppPaths.defaultSSHConfig }
        return URL(fileURLWithPath: (sshConfigPath as NSString).expandingTildeInPath)
    }

    // Decode tolerantly so that new settings never wipe old ones.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ key: CodingKeys, _ into: inout T) {
            if let v = try? c.decode(T.self, forKey: key) { into = v }
        }
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        d(.restoreSessionsOnLaunch, &restoreSessionsOnLaunch)
        d(.confirmCloseOnlineSessions, &confirmCloseOnlineSessions)
        d(.openNewSessionsInWindow, &openNewSessionsInWindow)
        d(.showSidebarArchive, &showSidebarArchive)
        d(.fontName, &fontName)
        d(.fontSize, &fontSize)
        d(.theme, &theme)
        d(.terminalProfile, &terminalProfile)
        d(.fontFromProfile, &fontFromProfile)
        d(.cursorShape, &cursorShape)
        d(.cursorBlink, &cursorBlink)
        d(.scrollbackLines, &scrollbackLines)
        d(.bell, &bell)
        d(.allowMouseReporting, &allowMouseReporting)
        d(.copyOnSelect, &copyOnSelect)
        d(.optionAsMeta, &optionAsMeta)
        d(.keyMappings, &keyMappings)
        d(.defaultPersistence, &defaultPersistence)
        d(.autoReconnect, &autoReconnect)
        d(.maxReconnectAttempts, &maxReconnectAttempts)
        d(.reconnectBaseDelay, &reconnectBaseDelay)
        d(.reconnectMaxDelay, &reconnectMaxDelay)
        d(.serverAliveInterval, &serverAliveInterval)
        d(.serverAliveCountMax, &serverAliveCountMax)
        d(.historyLinesOnReattach, &historyLinesOnReattach)
        d(.stallTimeout, &stallTimeout)
        d(.recordingEnabled, &recordingEnabled)
        d(.recordingQuotaMB, &recordingQuotaMB)
        d(.recordingRetentionDays, &recordingRetentionDays)
        d(.compressRecordingsAfterDays, &compressRecordingsAfterDays)
        d(.monitorRefreshInterval, &monitorRefreshInterval)
        d(.monitorAutoLoad, &monitorAutoLoad)
        d(.showStatusStrip, &showStatusStrip)
        d(.confirmKill, &confirmKill)
        d(.logLines, &logLines)
        d(.transferParallel, &transferParallel)
        d(.transferArchiveMode, &transferArchiveMode)
        d(.transferArchiveThreshold, &transferArchiveThreshold)
        d(.transferCompress, &transferCompress)
        d(.checkForUpdates, &checkForUpdates)
        d(.requireAuthForSavedPasswords, &requireAuthForSavedPasswords)
        d(.authGraceSeconds, &authGraceSeconds)
        d(.detectPasswordPrompts, &detectPasswordPrompts)
        d(.sshConfigPath, &sshConfigPath)
        d(.sshBinary, &sshBinary)
        d(.scpBinary, &scpBinary)
        d(.useControlMaster, &useControlMaster)
        d(.controlPersistSeconds, &controlPersistSeconds)
        d(.hostKeyPolicy, &hostKeyPolicy)
    }
}

/// Observable wrapper that persists `AppSettings` on every change.
@MainActor
@Observable
public final class SettingsStore {
    public static let shared = SettingsStore()
    private static let defaultsKey = "TetherSettings.v1"

    public var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            if let data = try? JSONEncoder().encode(settings) {
                defaults.set(data, forKey: Self.defaultsKey)
            }
        }
    }

    /// Separate defaults suite for tests (TETHER_DEFAULTS_SUITE), otherwise the app's own defaults.
    private let defaults: UserDefaults = ProcessInfo.processInfo.environment["TETHER_DEFAULTS_SUITE"]
        .flatMap(UserDefaults.init(suiteName:)) ?? .standard

    public init() {
        if let data = defaults.data(forKey: Self.defaultsKey),
           var decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            decoded.migrate()
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    public func resetToDefaults() {
        settings = AppSettings()
    }
}
