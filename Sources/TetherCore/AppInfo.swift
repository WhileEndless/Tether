import Foundation

/// Static facts about the app shown in About, Settings and the Help menu.
public enum AppInfo {
    public static let name = "Tether"
    /// Marketing version; keep in sync with the VERSION file used by scripts/build-app.sh.
    public static let version = "0.1.0"
    public static let repository = URL(string: "https://github.com/WhileEndless/tether")!
    public static let issues = URL(string: "https://github.com/WhileEndless/tether/issues")!
    public static let releases = URL(string: "https://github.com/WhileEndless/tether/releases")!

    /// The version of the running bundle (falls back to `version` when run unbundled).
    public static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? version
    }
}
