import Foundation

/// Central place for every on-disk location Tether uses.
/// Nothing here is user specific at compile time; all paths are resolved at runtime.
public enum AppPaths {
    public static let appName = "Tether"

    /// ~/Library/Application Support/Tether (overridable with TETHER_SUPPORT_DIR for tests).
    public static var supportDirectory: URL {
        if let custom = debugOverride("TETHER_SUPPORT_DIR") {
            return ensure(URL(fileURLWithPath: custom, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent(appName, isDirectory: true))
    }

    /// Terminal recordings (session backups).
    public static var recordingsDirectory: URL {
        ensure(supportDirectory.appendingPathComponent("Recordings", isDirectory: true))
    }

    /// The command history (one file per host, see MonitorKit's `CommandHistoryStore`).
    public static var commandHistoryDirectory: URL {
        ensure(supportDirectory.appendingPathComponent("Command History", isDirectory: true))
    }

    /// Remote files downloaded by "Copy" in the file manager, for pasting in Finder (removed after a day).
    public static var clipboardDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TetherClipboard", isDirectory: true)
    }

    /// Temporary downloads used for previews.
    public static var previewDirectory: URL {
        ensure(FileManager.default.temporaryDirectory.appendingPathComponent("TetherPreview", isDirectory: true))
    }

    /// Short directory for ControlMaster sockets and the askpass socket. Unix socket paths are
    /// limited to ~104 bytes, so this lives under /tmp rather than Application Support.
    ///
    /// /tmp is shared by every user of the Mac, so `/tmp/tether-<uid>` is only used when it is a real
    /// directory (not a link) owned by this user and closed to everyone else. If another account
    /// created that name first, a private directory with a random name is used instead — sockets in
    /// a directory someone else controls could be replaced to take over connections.
    public static var controlSocketDirectory: URL { socketDirectory }

    private static let socketDirectory: URL = {
        // Test and demo runs get their own folder: they must never replace the askpass socket of a
        // Tether that is running at the same time, nor reuse its shared connections.
        if debugOverride("TETHER_SUPPORT_DIR") != nil {
            var template = Array("/tmp/tether-\(getuid())-dbg-XXXXXX".utf8CString)
            if let made = mkdtemp(&template) { return URL(fileURLWithPath: String(cString: made), isDirectory: true) }
        }
        let preferred = "/tmp/tether-\(getuid())"
        if isPrivateDirectory(preferred) || (mkdir(preferred, 0o700) == 0 && isPrivateDirectory(preferred)) {
            return URL(fileURLWithPath: preferred, isDirectory: true)
        }
        var template = Array("\(preferred)-XXXXXX".utf8CString)
        if let made = mkdtemp(&template) {
            return URL(fileURLWithPath: String(cString: made), isDirectory: true)
        }
        // The per-user temporary folder is private already (its path is longer, but still fits).
        return ensure(FileManager.default.temporaryDirectory.appendingPathComponent("tether", isDirectory: true), permissions: 0o700)
    }()

    /// Removes what earlier runs left behind, once it is a day old: ssh connection logs (a crash
    /// while connecting leaves them), copies of remote files made for Quick Look and dragging, and
    /// the socket folders of test and demo runs and of their tmux servers. Only this user's own
    /// folders are touched.
    public static func removeLeftovers(now: Date = Date()) {
        let fm = FileManager.default
        let dayAgo = now.addingTimeInterval(-86_400)
        func old(_ path: String) -> Bool {
            ((try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date).map { $0 < dayAgo } ?? false
        }
        let dir = socketDirectory.path
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix("connect-") && name.hasSuffix(".log") {
            let path = dir + "/" + name
            if old(path) { try? fm.removeItem(atPath: path) }
        }
        // Copies of remote files made for Quick Look and dragging: one folder each.
        let previews = previewDirectory.path
        for name in (try? fm.contentsOfDirectory(atPath: previews)) ?? [] {
            let path = previews + "/" + name
            if old(path) { try? fm.removeItem(atPath: path) }
        }
        // Remote files downloaded for "Copy" so Finder can paste them: one folder each.
        let clipboard = clipboardDirectory.path
        for name in (try? fm.contentsOfDirectory(atPath: clipboard)) ?? [] {
            let path = clipboard + "/" + name
            if old(path) { try? fm.removeItem(atPath: path) }
        }
        // Socket folders of test and demo runs, and the private tmux servers of self-tests.
        let prefixes = ["tether-\(getuid())-dbg-", "tether-\(getuid())-tmux-"]
        for name in (try? fm.contentsOfDirectory(atPath: "/tmp")) ?? [] where prefixes.contains(where: name.hasPrefix) {
            let path = "/tmp/" + name
            guard path != dir, isPrivateDirectory(path), old(path) else { continue }
            try? fm.removeItem(atPath: path)
        }
    }

    /// A real directory owned by this user with no access for others (tightened if only the mode is off).
    static func isPrivateDirectory(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { return false }
        if st.st_mode & 0o077 != 0 { return chmod(path, 0o700) == 0 }
        return true
    }

    /// Socket used by the askpass helper to talk to the app.
    public static var askPassSocket: URL {
        controlSocketDirectory.appendingPathComponent("askpass.sock")
    }

    public static var userSSHDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
    }

    /// ~/.ssh/config (overridable with TETHER_SSH_CONFIG for tests and the demo).
    public static var defaultSSHConfig: URL {
        if let custom = debugOverride("TETHER_SSH_CONFIG") {
            return URL(fileURLWithPath: custom)
        }
        return userSSHDirectory.appendingPathComponent("config")
    }

    /// Running inside a test runner (XCTest or Swift Testing). Debug builds only.
    public static let isRunningTests: Bool = {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
            || Bundle.main.bundlePath.hasSuffix(".xctest")
            || ProcessInfo.processInfo.processName.contains("xctest")
            || ProcessInfo.processInfo.processName.contains("swiftpm-testing-helper")
            || CommandLine.arguments.contains { $0.hasSuffix(".xctest") || $0.contains("--testing-library") }
        #else
        return false
        #endif
    }()

    /// A TETHER_* environment override for tests and the demo. Debug builds only: in a release build
    /// nothing set from outside (e.g. with `launchctl setenv`) can point Tether at other settings, ssh
    /// configuration or data folders.
    /// The app's preferences: a separate suite for tests, self-tests and the demo
    /// (TETHER_DEFAULTS_SUITE), otherwise the app's own defaults. Everything Tether keeps in
    /// preferences goes through this (SwiftUI's `@AppStorage` too, via `defaultAppStorage`).
    public static let defaults: UserDefaults = debugOverride("TETHER_DEFAULTS_SUITE")
        .flatMap(UserDefaults.init(suiteName:)) ?? .standard

    public static func debugOverride(_ name: String) -> String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment[name]
        #else
        return nil
        #endif
    }

    @discardableResult
    public static func ensure(_ url: URL, permissions: Int? = nil) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            var attrs: [FileAttributeKey: Any] = [:]
            if let permissions { attrs[.posixPermissions] = permissions }
            try? fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: attrs)
        } else if let permissions {
            try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        }
        return url
    }
}
