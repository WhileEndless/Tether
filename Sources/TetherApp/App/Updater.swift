import AppKit
import Observation
import TetherCore

/// Keeps Tether up to date from its GitHub releases.
///
/// - At launch (and once a day while it runs) it asks GitHub whether a newer release exists; *Check
///   for Updates* asks now. Nothing about the user is sent; without GitHub the check is skipped.
/// - With "Download and install updates" on (the default), a newer release's source is downloaded
///   into a private temporary folder (with its progress) and built there in the background
///   (`UpdateScripts.fetchAndBuild`, at background priority; the build's progress is read from its
///   log). Building needs Apple's command line tools; without them the update stays a link to the
///   release page.
/// - Once built, it is installed with `make install` over the copy that runs — after Tether quits
///   (*Restart to Update*, or simply the next time you quit). Sessions in tmux or screen re-attach
///   after the restart as after any relaunch, and the release's notes are shown once ("What's New").
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    struct Release: Equatable, Codable {
        var version: String
        var tag: String
        var page: URL
        /// The release's notes as GitHub has them (Markdown).
        var notes: String
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate(Date)
        /// Newer release found; not being prepared (automatic install off, no build tools, or stopped).
        case available(Release, reason: String?)
        /// `total` is nil when GitHub does not say the size.
        case downloading(Release, received: Int64, total: Int64?)
        /// `progress` 0…1 once the build says how far it is.
        case building(Release, progress: Double?, step: String)
        /// Built and waiting for Tether to quit.
        case ready(Release)
        case failed(Release?, String)
    }

    private(set) var state: State = .idle
    /// A request to show the Software Update window (the window opens itself when this changes).
    private(set) var windowRequest = 0
    /// What the update window shows after an update was installed: the version now running and its notes.
    private(set) var installed: Release?

    /// A newer release, if one is known (for the sidebar's badge).
    var available: Release? {
        switch state {
        case .available(let r, _), .downloading(let r, _, _), .building(let r, _, _), .ready(let r): r
        case .failed(let r, _): r
        default: nil
        }
    }

    var isReady: Bool { if case .ready = state { true } else { false } }
    var isPreparing: Bool {
        switch state {
        case .downloading, .building: true
        default: false
        }
    }
    var isBusy: Bool { if case .checking = state { true } else { isPreparing } }

    @ObservationIgnored private var started = false
    @ObservationIgnored private var build: Process?
    @ObservationIgnored private var download: ReleaseDownload?
    @ObservationIgnored private var daily: Task<Void, Never>?

    /// Where updates are downloaded and built: a folder of Tether's own in the user's temporary folder.
    var workFolder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("tether-update-work") }
    var logFile: URL { workFolder.appendingPathComponent("update.log") }

    private var settings: AppSettings { AppModel.shared.settings }

    private static var disabledHere: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TETHER_SUPPORT_DIR"] != nil { return true }   // tests and demo
        #endif
        return false
    }

    func showWindow() { windowRequest += 1 }

    // MARK: Checking

    func checkAtLaunch() {
        guard !started, !Self.disabledHere else { return }
        started = true
        showWhatIsNewIfUpdated()
        if settings.checkForUpdates { check(userAsked: false) }
        daily = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(24 * 3600))
                guard let self, self.settings.checkForUpdates, !self.isBusy, !self.isReady else { continue }
                self.check(userAsked: false)
            }
        }
    }

    /// *Check for Updates*: asks now, and with automatic install on, starts on a newer release.
    func check(userAsked: Bool) {
        if userAsked { showWindow() }
        guard !isBusy, !isReady else { return }
        state = .checking
        Task {
            guard let release = await Self.latestRelease() else {
                state = .failed(nil, "GitHub could not be reached. Check the network and try again.")
                return
            }
            guard AppVersion.isNewer(release.version, than: AppInfo.bundleVersion) else {
                state = .upToDate(Date())
                return
            }
            if settings.installUpdatesAutomatically, !Self.disabledHere {
                prepare(release)
            } else {
                state = .available(release, reason: nil)
                // Said once per version, not every day.
                if !userAsked, AppPaths.defaults.string(forKey: "update.announced") != release.version {
                    AppPaths.defaults.set(release.version, forKey: "update.announced")
                    Notifier.shared.updateAvailable(release.version, ready: false)
                }
            }
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
              !tag.isEmpty, tag.allSatisfy({ $0.isLetter || $0.isNumber || ".-_".contains($0) }),
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              page.scheme == "https", page.host == "github.com" else { return nil }   // only ever a GitHub page
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), tag: tag, page: page,
                       notes: json["body"] as? String ?? "")
    }

    // MARK: Downloading and building

    /// Downloads and builds `release` in the background.
    func prepare(_ release: Release) {
        guard !isPreparing else { return }
        guard installFolder != nil else {
            state = .available(release, reason: "Tether cannot replace itself where it is installed (the folder is not writable). Install it from the release page.")
            return
        }
        let fm = FileManager.default
        try? fm.removeItem(at: workFolder)
        try? fm.createDirectory(at: workFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fm.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        state = .downloading(release, received: 0, total: nil)
        let url = AppInfo.repository.appendingPathComponent("archive/refs/tags/\(release.tag).tar.gz")
        let tarball = workFolder.appendingPathComponent("source.tar.gz")
        download = ReleaseDownload(url: url, to: tarball, progress: { [weak self] received, total in
            Task { @MainActor in
                guard let self, case .downloading(let r, _, _) = self.state else { return }
                self.state = .downloading(r, received: received, total: total)
            }
        }, done: { [weak self] error in
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                self.download = nil
                if let error { self.state = .failed(release, "The download did not finish: \(error)"); return }
                self.startBuild(release, tarball: tarball)
            }
        })
    }

    private func startBuild(_ release: Release, tarball: URL) {
        guard let log = try? FileHandle(forWritingTo: logFile) else {
            state = .failed(release, "The update's work folder could not be written.")
            return
        }
        log.seekToEndOfFile()
        state = .building(release, progress: nil, step: "Preparing the build…")
        let p = Process()
        // Background priority: building takes a few minutes of CPU, never ahead of what you do.
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
        p.arguments = ["-b", "/bin/sh", "-c", UpdateScripts.fetchAndBuild, "tether-update",
                       release.tag, workFolder.path, AppInfo.repository.absoluteString, release.version, tarball.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        env["TMUX"] = nil
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { process in
            let status = process.terminationStatus
            Task { @MainActor in self.buildEnded(release, status: status) }
        }
        do {
            try p.run()
            build = p
            followBuild(release)
        } catch {
            state = .failed(release, "The build could not be started.")
        }
    }

    /// The build's progress, read from its log every second.
    private func followBuild(_ release: Release) {
        Task { [weak self] in
            var reader = UpdateBuildProgress()
            var offset: UInt64 = 0
            while let self, self.build != nil {
                if let h = try? FileHandle(forReadingFrom: self.logFile) {
                    try? h.seek(toOffset: offset)
                    if let data = try? h.readToEnd(), !data.isEmpty {
                        offset += UInt64(data.count)
                        reader.read(String(decoding: data, as: UTF8.self))
                    }
                    try? h.close()
                }
                if case .building(let r, _, _) = self.state {
                    let next = State.building(r, progress: reader.progress, step: reader.step)
                    if self.state != next { self.state = next }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func buildEnded(_ release: Release, status: Int32) {
        build = nil
        guard case .building = state else { return }   // stopped meanwhile
        if status == 0 {
            state = .ready(release)
            Notifier.shared.updateAvailable(release.version, ready: true)
            return
        }
        let last = (try? String(contentsOf: logFile, encoding: .utf8))?
            .split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init)
        if status == 3 {
            // No build tools: the release page instead.
            state = .available(release, reason: last ?? "Building needs Apple's command line tools (xcode-select --install).")
        } else {
            state = .failed(release, last ?? "The update could not be built (exit \(status)).")
        }
    }

    /// *Cancel*, automatic install turned off, or Tether quitting while an update is prepared.
    func stop() {
        guard isPreparing, let release = available else { return }
        download?.cancel()
        download = nil
        if let p = build {
            build = nil
            p.terminate()
        }
        state = .available(release, reason: "Stopped. Install starts it again.")
    }

    // MARK: Installing

    /// The folder Tether.app is installed in, when Tether may replace itself there.
    var installFolder: URL? {
        // The install replaces Tether.app: a copy renamed (or not an app) is left to the user.
        let bundle = Bundle.main.bundleURL
        guard bundle.lastPathComponent == "Tether.app" else { return nil }
        let folder = bundle.deletingLastPathComponent()
        let fm = FileManager.default
        return fm.isWritableFile(atPath: folder.path) && fm.isWritableFile(atPath: bundle.path) ? folder : nil
    }

    /// *Restart to Update*: Tether quits, the update is installed, and Tether opens again.
    func restartToUpdate() {
        guard case .ready(let release) = state else { return }
        // Shells nothing keeps running end with Tether: said first.
        let plain = AppModel.shared.sessions.sessions.filter {
            $0.phase.isOnline && ($0.persistence == .plain || $0.persistence == .unknown)
        }.count
        let alert = NSAlert()
        alert.messageText = "Restart Tether to install \(release.version)?"
        alert.informativeText = "Tabs in tmux or screen come back after the restart."
            + (plain > 0 ? " \(plain) tab\(plain == 1 ? "" : "s") without tmux or screen will end." : "")
        alert.addButton(withTitle: "Restart to Update")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        launchInstaller(reopen: true)
        NSApp.terminate(nil)
    }

    /// Tether is quitting with an update built: it is installed once Tether has ended.
    func installOnQuit() {
        guard isReady, settings.installUpdatesAutomatically else { return }
        launchInstaller(reopen: false)
    }

    @ObservationIgnored private var installerLaunched = false
    private static let whatIsNewKey = "update.whatIsNew"

    private func launchInstaller(reopen: Bool) {
        guard !installerLaunched, case .ready(let release) = state, let dest = installFolder else { return }
        // Temporary files can be cleaned up by macOS while an update waits: built again next time.
        guard FileManager.default.fileExists(atPath: workFolder.appendingPathComponent("src/dist/Tether.app").path) else {
            state = .available(release, reason: "The prepared update was removed meanwhile. Install prepares it again.")
            return
        }
        installerLaunched = true
        // Shown once by the new version ("What's New").
        if let data = try? JSONEncoder().encode(release) { AppPaths.defaults.set(data, forKey: Self.whatIsNewKey) }
        let p = Process()
        // nohup: it outlives this Tether (the script also ignores the signals a closing terminal sends).
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        p.arguments = ["/bin/sh", "-c", UpdateScripts.install, "tether-install", String(ProcessInfo.processInfo.processIdentifier),
                       workFolder.appendingPathComponent("src").path, dest.path, reopen ? "1" : "0",
                       workFolder.path, logFile.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        env["TMUX"] = nil
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()   // it outlives Tether: it waits for this process to end
    }

    /// The first launch of the version an update installed: its notes, once.
    private func showWhatIsNewIfUpdated() {
        guard let data = AppPaths.defaults.data(forKey: Self.whatIsNewKey) else { return }
        AppPaths.defaults.removeObject(forKey: Self.whatIsNewKey)
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              release.version == AppInfo.bundleVersion else { return }   // the install did not happen
        installed = release
        showWindow()
    }

    func dismissWhatIsNew() { installed = nil }

    func showLog() {
        guard FileManager.default.fileExists(atPath: logFile.path) else { return }
        NSWorkspace.shared.open(logFile)
    }
}

/// Downloads a release's source with its progress (bytes so far, and the size when GitHub says it).
final class ReleaseDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64, Int64?) -> Void
    private let done: @Sendable (String?) -> Void
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private var lastReport: TimeInterval = 0

    init(url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void,
         done: @escaping @Sendable (String?) -> Void) {
        self.destination = destination
        self.progress = progress
        self.done = done
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 900
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue("Tether", forHTTPHeaderField: "User-Agent")
        task = session.downloadTask(with: request)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReport > 0.1 else { return }
        lastReport = now
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            done("GitHub answered \(status).")
            session.finishTasksAndInvalidate()
            return
        }
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            done(nil)
        } catch {
            done(error.localizedDescription)
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        done(error.localizedDescription)
        session.finishTasksAndInvalidate()
    }
}
