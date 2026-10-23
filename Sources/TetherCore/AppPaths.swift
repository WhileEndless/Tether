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
