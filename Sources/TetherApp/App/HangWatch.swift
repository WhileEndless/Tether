import AppKit
import os

/// Notices when Tether stops answering (the main thread busy for seconds) and keeps a record of
/// where it was: macOS's own `sample` of this process, saved under ~/Library/Logs/Tether (on this
/// Mac only; it holds function names, nothing of what terminals show). At most one a ten minutes,
/// the last five kept. Quitting that takes long is sampled too (`TetherApp.endIfQuittingHangs`).
final class HangWatch: @unchecked Sendable {
    static let shared = HangWatch()

    private let lock = NSLock()
    private var answered = ProcessInfo.processInfo.systemUptime
    private var lastSample: TimeInterval = -.infinity
    private var started = false
    private let log = Logger(subsystem: "io.github.whileendless.tether", category: "app")

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Tether", isDirectory: true)
    }

    func start() {
        guard lock.withLock({ let was = started; started = true; return !was }) else { return }
        let thread = Thread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 0.5)
                DispatchQueue.main.async { [self] in lock.withLock { answered = ProcessInfo.processInfo.systemUptime } }
                let silent = ProcessInfo.processInfo.systemUptime - lock.withLock { answered }
                if silent > 2.5 { sample(reason: "not answering for \(Int(silent)) s") }
            }
        }
        thread.name = "hang watch"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Saves a sample of this process now (off the main thread; at most one a ten minutes).
    func sample(reason: String, force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard lock.withLock({
            guard force || now - lastSample > 600 else { return false }
            lastSample = now
            return true
        }) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = Self.folder.appendingPathComponent("hang-\(stamp).txt")
        log.error("Tether is \(reason, privacy: .public); sampling to \(file.lastPathComponent, privacy: .public)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = [String(getpid()), "2", "-mayDie", "-file", file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let deadline = Date().addingTimeInterval(8)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning { p.terminate() }
        // The last five are kept.
        let old = ((try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("hang-") && $0.pathExtension == "txt" }
            .sorted { ($0.lastPathComponent) > ($1.lastPathComponent) }
        for url in old.dropFirst(5) { try? fm.removeItem(at: url) }
    }
}
