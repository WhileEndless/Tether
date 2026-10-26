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

/// Where a new tab appears in the tab bar.
public enum NewTabPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case afterCurrent
    case end

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .afterCurrent: "Next to the Current Tab"
        case .end: "At the End"
        }
    }
}

/// Where a new tab to the same host starts (⌘T).
public enum NewTabDirectory: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The folder the current tab's shell is in, like Terminal.app.
    case current
    case home

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .current: "Same Folder as the Current Tab"
        case .home: "Home Folder"
        }
    }
}

/// How the open sessions under a host are ordered in the sidebar.
public enum SessionSortOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Online first, then connecting, suspended; each in the manual order.
    case status
    case name
    case newest
    case oldest
    /// Exactly the order the user dragged them into.
    case manual

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .status: "Active First"
        case .name: "Name"
        case .newest: "Newest First"
        case .oldest: "Oldest First"
        case .manual: "Manual (Drag to Reorder)"
        }
    }
}

/// How Tether is unlocked when it opens.
public enum AppLockMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    /// Touch ID, an Apple Watch or the Mac's login password (whatever macOS offers).
    case system
    /// A password only for Tether. It also protects the key of encrypted recordings.
    case password

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .off: "Off"
        case .system: "Touch ID or Mac Password"
        case .password: "Tether Password"
        }
    }
}

/// All user preferences. Persisted as JSON in UserDefaults.
public struct AppSettings: Codable, Equatable, Sendable {
    // General
    public var restoreSessionsOnLaunch = true
    public var confirmCloseOnlineSessions = true
    public var openNewSessionsInWindow = false
    public var newTabDirectory: NewTabDirectory = .current
    public var newTabPosition: NewTabPosition = .afterCurrent
    public var showSidebarArchive = false
    public var sessionSortOrder: SessionSortOrder = .status
    /// Closing the last window keeps Tether (and every session) running in the menu bar.
    public var keepRunningInMenuBar = true

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
    /// Programs may erase the scrollback (`clear`, `ESC[3J`) as in other terminals. Off: output never
    /// erases the history on screen (the recording keeps everything either way).
    public var programsMayClearScrollback = false
    /// "Browse" in a terminal of this Mac opens its folder in Finder (off: Tether's file manager).
    public var browseLocalInFinder = true
    /// Tabs not renamed by hand are named after the coding agent session in them (Claude Code,
    /// Codex, opencode).
    public var tabTitleFromAgent = true
    /// New keys with a passphrase: Tether keeps the passphrase in its keychain (askpass answers ssh
    /// with it, after Touch ID when that is on).
    public var rememberKeyPassphrases = true
    /// New keys are also added to the macOS ssh-agent (passphrase in the macOS keychain, the host's
    /// config gets `AddKeysToAgent` and `UseKeychain`), for Terminal, git and other programs.
    public var addNewKeysToAgent = false
    public var bell: BellMode = .visual
    /// Notifications programs send (OSC 9/777/99 — Claude Code when it finishes or asks).
    public var notifyFromPrograms = true
    /// The bell in a tab that is not being looked at notifies too.
    public var notifyOnBell = true
    public var allowMouseReporting = true
    public var copyOnSelect = false

    // Keyboard
    /// Off by default, like Terminal.app: Option types the characters of the keyboard layout
    /// (⌥Q is @ on Turkish and other layouts, ⌥5/⌥6 are [ ] on German, …).
    public var optionAsMeta = false
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
    /// Scrollback the server keeps for Tether's tmux/screen sessions, so output printed while
    /// disconnected can be fetched on reconnect.
    public var serverHistoryLines = 100_000
    /// Seconds without any answer from the server before a session is considered disconnected.
    public var stallTimeout: Double = 6

    // Recordings
    public var recordingEnabled = true
    public var recordingQuotaMB = 1024
    public var recordingRetentionDays = 0     // 0 = keep until quota
    /// Compress recordings older than this many days (0 = never).
    public var compressRecordingsAfterDays = 7
    /// A session's recording moves its earlier output aside as a compressed part every this many MB
    /// while the session runs (0 = never). The latest output stays uncompressed for scrolling back.
    public var recordingPartMB = 16
    /// When the storage limit is reached, a session holding more than half of it loses its oldest
    /// output first, before any other recording is removed.
    public var recordingShortenLargestFirst = true

    // Monitoring
    public var monitorRefreshInterval: Double = 5
    public var monitorAutoLoad = true
    /// Compact live CPU / memory / disk / GPU / latency bar above each terminal.
    public var showStatusStrip = true
    public var confirmKill = true
    public var logLines = 300
    /// The command running in a terminal (PID, time, CPU, memory, network) in the bar below it.
    public var showCommandStats = true
    /// Remember the commands run in Tether's terminals with their duration and usage (on this Mac only).
    public var keepCommandHistory = true
    /// Also keep the processes each command ran (name, PID, CPU and memory of each).
    public var keepCommandProcesses = true
    /// Also keep the connections each command had (remote addresses, bytes moved).
    public var keepCommandConnections = true
    /// A tiny watcher on each host notices commands the moment they start or end (also short ones),
    /// so nothing is looked at while shells wait. Off: terminals are looked at every few seconds.
    public var commandWatchEnabled = true
    /// How often the watcher checks the shells, in seconds.
    public var commandWatchInterval: Double = 0.5
    /// How often a running command is measured, in seconds.
    public var commandLookInterval: Double = 3
    /// How often traffic by process is sampled, in seconds.
    public var trafficInterval: Double = 2
    /// Days the command history is kept (0 = until the per-host limit).
    public var commandHistoryDays = 90
    /// Disk space the command history may take; the oldest commands go first.
    public var commandHistoryMaxMB = 50

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
    // Security
    public var appLockMode: AppLockMode = .off
    /// Lock again when the Mac sleeps or its screen locks.
    public var lockOnSleep = true
    /// With a Tether password: Touch ID (or the Mac password) unlocks too. The key of encrypted
    /// recordings is then also kept in the login keychain.
    public var unlockWithTouchID = false
    /// New recordings are encrypted (AES-256-GCM, key in the keychain or behind the Tether password).
    public var encryptRecordings = false
    /// macOS Secure Keyboard Entry while a terminal waits for a password, so no other app can read the keys.
    public var secureKeyboardAtPasswordPrompts = true

    public var requireAuthForSavedPasswords = true
    /// After a successful check, saved passwords can be used without asking again for this long (seconds).
    public var authGraceSeconds = 300
    /// Notice password prompts in terminals (sudo, su, ssh, …) and offer to fill a saved password.
    public var detectPasswordPrompts = true
    /// Fill a saved password into a terminal prompt as soon as it appears (after Touch ID, if required).
    public var autoFillPasswordPrompts = true

    // SSH
    public var sshConfigPath: String = ""     // empty = ~/.ssh/config
    public var sshBinary = "/usr/bin/ssh"
    public var scpBinary = "/usr/bin/scp"
    public var useControlMaster = true
    public var controlPersistSeconds = 600
    public var hostKeyPolicy: HostKeyPolicy = .ask

    /// Bumped when defaults change in a way existing users should get too (see `migrate`).
    public var version = AppSettings.currentVersion
    public static let currentVersion = 4

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
        if version < 4 {
            // Option as Meta swallowed characters typed with Option (⌥Q → @ on Turkish keyboards).
            optionAsMeta = false
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
        d(.newTabDirectory, &newTabDirectory)
        d(.newTabPosition, &newTabPosition)
        d(.showSidebarArchive, &showSidebarArchive)
        d(.sessionSortOrder, &sessionSortOrder)
        d(.keepRunningInMenuBar, &keepRunningInMenuBar)
        d(.fontName, &fontName)
        d(.fontSize, &fontSize)
        d(.theme, &theme)
        d(.terminalProfile, &terminalProfile)
        d(.fontFromProfile, &fontFromProfile)
        d(.cursorShape, &cursorShape)
        d(.cursorBlink, &cursorBlink)
        d(.scrollbackLines, &scrollbackLines)
        d(.programsMayClearScrollback, &programsMayClearScrollback)
        d(.browseLocalInFinder, &browseLocalInFinder)
        d(.tabTitleFromAgent, &tabTitleFromAgent)
        d(.rememberKeyPassphrases, &rememberKeyPassphrases)
        d(.addNewKeysToAgent, &addNewKeysToAgent)
        d(.bell, &bell)
        d(.notifyFromPrograms, &notifyFromPrograms)
        d(.notifyOnBell, &notifyOnBell)
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
        d(.serverHistoryLines, &serverHistoryLines)
        d(.stallTimeout, &stallTimeout)
        d(.recordingEnabled, &recordingEnabled)
        d(.recordingQuotaMB, &recordingQuotaMB)
        d(.recordingRetentionDays, &recordingRetentionDays)
        d(.compressRecordingsAfterDays, &compressRecordingsAfterDays)
        d(.recordingPartMB, &recordingPartMB)
        d(.recordingShortenLargestFirst, &recordingShortenLargestFirst)
        d(.monitorRefreshInterval, &monitorRefreshInterval)
        d(.monitorAutoLoad, &monitorAutoLoad)
        d(.showStatusStrip, &showStatusStrip)
        d(.confirmKill, &confirmKill)
        d(.logLines, &logLines)
        d(.showCommandStats, &showCommandStats)
        d(.keepCommandHistory, &keepCommandHistory)
        d(.commandHistoryDays, &commandHistoryDays)
        d(.commandHistoryMaxMB, &commandHistoryMaxMB)
        d(.keepCommandProcesses, &keepCommandProcesses)
        d(.commandWatchEnabled, &commandWatchEnabled)
        d(.commandWatchInterval, &commandWatchInterval)
        d(.commandLookInterval, &commandLookInterval)
        d(.trafficInterval, &trafficInterval)
        d(.keepCommandConnections, &keepCommandConnections)
        d(.transferParallel, &transferParallel)
        d(.transferArchiveMode, &transferArchiveMode)
        d(.transferArchiveThreshold, &transferArchiveThreshold)
        d(.transferCompress, &transferCompress)
        d(.checkForUpdates, &checkForUpdates)
        d(.appLockMode, &appLockMode)
        d(.lockOnSleep, &lockOnSleep)
        d(.unlockWithTouchID, &unlockWithTouchID)
        d(.encryptRecordings, &encryptRecordings)
        d(.secureKeyboardAtPasswordPrompts, &secureKeyboardAtPasswordPrompts)
        d(.requireAuthForSavedPasswords, &requireAuthForSavedPasswords)
        d(.authGraceSeconds, &authGraceSeconds)
        d(.detectPasswordPrompts, &detectPasswordPrompts)
        d(.autoFillPasswordPrompts, &autoFillPasswordPrompts)
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
            let pinned = SecuritySettings(settings)
            if pinned != SecuritySettings(oldValue) { SecuritySettings.pin(pinned) }
        }
    }

    /// Security settings found changed outside Tether (and put back) at launch, if any.
    public private(set) var tamperedSecuritySettings: [String] = []

    /// Separate defaults suite for tests (TETHER_DEFAULTS_SUITE), otherwise the app's own defaults.
    private let defaults: UserDefaults = AppPaths.debugOverride("TETHER_DEFAULTS_SUITE")
        .flatMap(UserDefaults.init(suiteName:)) ?? .standard

    public init() {
        if let data = defaults.data(forKey: Self.defaultsKey),
           var decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            decoded.migrate()
            settings = decoded
        } else {
            settings = AppSettings()
        }
        // Never run an ssh/scp that is missing, not executable or in a temporary folder.
        let defaults = AppSettings()
        settings.sshBinary = SecuritySettings.usableProgram(settings.sshBinary, fallback: defaults.sshBinary)
        settings.scpBinary = SecuritySettings.usableProgram(settings.scpBinary, fallback: defaults.scpBinary)
        // The keychain copy of the security settings wins over the preferences file.
        switch SecuritySettings.pinned() {
        case .pinned(var pinned):
            pinned.sshBinary = SecuritySettings.usableProgram(pinned.sshBinary, fallback: defaults.sshBinary)
            pinned.scpBinary = SecuritySettings.usableProgram(pinned.scpBinary, fallback: defaults.scpBinary)
            tamperedSecuritySettings = pinned.differences(from: SecuritySettings(settings))
            if !tamperedSecuritySettings.isEmpty { pinned.apply(to: &settings) }
        case .missing:
            // No keychain copy yet (first launch of this version, or it was removed): keep what the
            // preferences say, but list what differs from the defaults so the user can check it.
            unpinnedNonDefaults = SecuritySettings(AppSettings()).differences(from: SecuritySettings(settings))
            SecuritySettings.pin(SecuritySettings(settings))
        case .unreadable:
            // The user declined the keychain prompt for an old-style copy: they know what they set,
            // so keep the preferences without a warning and store a copy that never asks again.
            SecuritySettings.pin(SecuritySettings(settings))
        }
    }

    /// Security settings that differed from the defaults when no keychain copy existed (to review).
    public private(set) var unpinnedNonDefaults: [String] = []

    /// Everything back to defaults except the security settings (App Lock, encryption, where
    /// passwords go …): those change only in their own places, with confirmation.
    public func resetToDefaults() {
        var fresh = AppSettings()
        SecuritySettings(settings).apply(to: &fresh)
        settings = fresh
    }
}
