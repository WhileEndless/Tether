import Foundation
import RecordingKit

/// Compresses recordings while the Mac is idle (`IdleCompression`). macOS's background scheduler
/// picks the moments (about every 10 minutes, when it suits the system's load and power); each pass
/// also waits for the keyboard and mouse to have been left alone, and stops between files as soon
/// as someone uses the Mac or macOS asks it to.
@MainActor
final class IdleMaintenance {
    static let shared = IdleMaintenance()
    private let scheduler = NSBackgroundActivityScheduler(identifier: "io.github.whileendless.tether.compress-recordings")
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        scheduler.repeats = true
        scheduler.interval = 10 * 60
        scheduler.tolerance = 5 * 60
        scheduler.qualityOfService = .background
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                let finished = await self?.pass(manual: false) ?? true
                completion(finished ? .finished : .deferred)
            }
        }
        Task { await IdleCompression.countWaiting() }
    }

    /// Settings ▸ Recordings ▸ Compress Now: at once, while Tether is unlocked.
    func compressNow() {
        Task { await pass(manual: true) }
    }

    /// One pass; true when nothing waits any more.
    @discardableResult
    private func pass(manual: Bool) async -> Bool {
        // Encrypted recordings need their key, which is not there while Tether is locked.
        guard !AppLock.shared.isLocked else { IdleCompression.skipped("Tether is locked"); return false }
        guard !IdleCompression.status.running else { return false }
        if !manual {
            let now = IdleCompression.goodTime()
            guard now.ok else { IdleCompression.skipped(now.reason ?? "the Mac is in use"); return false }
        }
        // `shouldDefer` may be asked from any thread.
        nonisolated(unsafe) let scheduler = self.scheduler
        return await IdleCompression.run {
            manual || (!scheduler.shouldDefer && IdleCompression.goodTime().ok)
        }
    }
}
