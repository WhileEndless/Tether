import Foundation
import CoreGraphics
import TetherCore

/// Compressing recordings while nobody uses the Mac: the parts long sessions moved aside, and
/// recordings older than the set number of days (Settings ▸ Recordings). Compressing reads and
/// rewrites every byte, so it waits until the keyboard and mouse have been left alone for a while,
/// Low Power Mode is off and the Mac is not hot — and stops between files as soon as that changes.
/// Only when the storage limit would otherwise remove recordings is it done at once
/// (`RecordingStore.enforceQuota`). The app runs `run` from macOS's background scheduler.
public enum IdleCompression {
    public struct Status: Equatable, Sendable {
        /// Files waiting to be compressed (as last counted).
        public var waiting = 0
        /// A pass is compressing now.
        public var running = false
        /// Files compressed in the current (or last) pass, and the bytes that saved.
        public var done = 0
        public var saved: Int64 = 0
        public var lastRun: Date?
        /// Why the last chance was let pass (the Mac in use, Low Power Mode, …); nil when it ran.
        public var waitingBecause: String?
    }

    private static let state = Locked(Status())
    public static var status: Status { state.withLock { $0 } }
    /// Posted (on any thread) when `status` changed.
    public static let statusChanged = Notification.Name("io.github.whileendless.tether.compression-status")

    private static func update(_ change: (inout Status) -> Void) {
        let changed = state.withLock { s -> Bool in
            let before = s
            change(&s)
            return s != before
        }
        if changed { NotificationCenter.default.post(name: statusChanged, object: nil) }
    }

    /// How long the keyboard and mouse must have been left alone.
    public static let idleAfter: TimeInterval = 120

    /// Whether now is a good time; when not, why.
    public static func goodTime(idleAfter: TimeInterval = idleAfter) -> (ok: Bool, reason: String?) {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return (false, "Low Power Mode is on") }
        if info.thermalState == .serious || info.thermalState == .critical { return (false, "the Mac is hot") }
        if let any = CGEventType(rawValue: ~0),
           CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any) < idleAfter {
            return (false, "the Mac is in use")
        }
        return (true, nil)
    }

    /// The files a pass would compress: parts not compressed yet (never written to again), then
    /// recordings no session writes that are older than the set number of days.
    static func candidates(in directory: URL, now: Date, olderThanDays days: Int) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        if let e = fm.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let url as URL in e
            where RecordingParts.isPart(url) && !RecordingCompression.isCompressed(url) && url.pathExtension != "tmp" {
                out.append(url)
            }
        }
        if days > 0 {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            out += RecordingStore.all(in: directory)
                .filter { !$0.isActive && !$0.isCompressed && $0.modified < cutoff }
                .map(\.url)
        }
        return out
    }

    /// Counts what waits (for the settings, before a pass ran).
    public static func countWaiting(in directory: URL = AppPaths.recordingsDirectory, now: Date = Date()) async {
        let days = RecordingStore.compressionDays
        let count = await RecordingStore.perform { candidates(in: directory, now: now, olderThanDays: days).count }
        update { $0.waiting = count }
    }

    /// The pass was let go by (`reason`); nothing was done.
    public static func skipped(_ reason: String) {
        update { $0.waitingBecause = reason }
    }

    /// Compresses what waits, one file at a time on the maintenance queue (in order with the other
    /// passes), as long as `goOn` says so between files. True when nothing is left.
    @discardableResult
    public static func run(in directory: URL = AppPaths.recordingsDirectory, now: Date = Date(),
                           goOn: @escaping @Sendable () -> Bool) async -> Bool {
        let days = RecordingStore.compressionDays
        let todo = await RecordingStore.perform { candidates(in: directory, now: now, olderThanDays: days) }
        update {
            $0.waiting = todo.count
            $0.waitingBecause = nil
            guard !todo.isEmpty else { return }
            $0.running = true
            $0.done = 0
            $0.saved = 0
        }
        guard !todo.isEmpty else { return true }
        var left = todo.count
        for url in todo {
            guard goOn() else { break }
            let saved: Int64? = await RecordingStore.perform {
                // Gone or compressed meanwhile (a quota pass, a session that reopened it): skipped.
                guard FileManager.default.fileExists(atPath: url.path), !RecordingStore.isActive(url) else { return 0 }
                let before = size(url)
                guard let out = try? RecordingCompression.compress(url) else { return nil }
                return before - size(out)
            }
            left -= 1
            update {
                $0.waiting = left
                if let saved { $0.done += 1; $0.saved += max(saved, 0) }
            }
        }
        update {
            $0.running = false
            $0.lastRun = Date()
        }
        return left == 0
    }

    private static func size(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
