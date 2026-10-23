import Foundation

/// Central place for every on-disk location Tether uses.
/// Nothing here is user specific at compile time; all paths are resolved at runtime.
public enum AppPaths {
    public static let appName = "Tether"

    /// ~/Library/Application Support/Tether (overridable with TETHER_SUPPORT_DIR for tests).
    public static var supportDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["TETHER_SUPPORT_DIR"] {
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

    /// Short directory for ControlMaster sockets. Unix socket paths are limited to ~104 bytes,
    /// so this deliberately lives under /tmp rather than Application Support.
    public static var controlSocketDirectory: URL {
        let url = URL(fileURLWithPath: "/tmp/tether-\(getuid())", isDirectory: true)
        ensure(url, permissions: 0o700)
        return url
    }

    /// Socket used by the askpass helper to talk to the app.
    public static var askPassSocket: URL {
        controlSocketDirectory.appendingPathComponent("askpass.sock")
    }

    public static var userSSHDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
    }

    public static var defaultSSHConfig: URL {
        userSSHDirectory.appendingPathComponent("config")
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
