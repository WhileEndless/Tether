import AppKit
import Observation
import TetherCore

/// At launch, asks GitHub once whether a newer Tether release exists and, if so, says so and
/// links to the release page. Nothing is downloaded or installed, nothing about the user is sent,
/// and when GitHub cannot be reached the check is silently skipped.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    struct Release: Equatable {
        var version: String
        var page: URL
    }

    /// A newer release, if one was found at launch.
    private(set) var available: Release?
    @ObservationIgnored private var checked = false

    func checkAtLaunch() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TETHER_SUPPORT_DIR"] != nil { return }   // tests and demo
        #endif
        guard !checked, AppModel.shared.settings.checkForUpdates else { return }
        checked = true
        Task {
            guard let release = await Self.latestRelease(),
                  AppVersion.isNewer(release.version, than: AppInfo.bundleVersion) else { return }
            available = release
            announce(release)
        }
    }

    /// The newest published release, or nil when GitHub cannot be reached or answers unexpectedly.
    static func latestRelease() async -> Release? {
        var request = URLRequest(url: AppInfo.latestReleaseAPI, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Tether", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), page: page)
    }

    private func announce(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Tether \(release.version) is available"
        alert.informativeText = "You have \(AppInfo.bundleVersion). The release page has the download and what is new."
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
    }
}
