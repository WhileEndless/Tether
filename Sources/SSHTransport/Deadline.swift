import Foundation

/// A limit on how long something may take, for the steps before a command runs (getting the
/// connection, asking the server's shell) — each has limits of its own, but together nothing else
/// bounded them, and a file listing could spin for as long as the slowest of them.
///
/// Only time that counts runs the clock: not while `paused` holds (the user is being asked
/// something), and not across a sleep of the Mac (a look that comes late starts nothing).
public enum Deadline {
    /// The result of `operation`, or nil when it took longer than `seconds`; it is cancelled then
    /// (and its result, should it come later, is dropped). Never waits for an operation that does
    /// not stop when cancelled.
    public static func run<T: Sendable>(seconds: TimeInterval, paused: @escaping @Sendable () -> Bool = { false },
                                        _ operation: @escaping @Sendable () async -> T) async -> T? {
        let race = Race<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                race.start(continuation)
                let work = Task { race.finish(await operation()) }
                race.onTimeout = { work.cancel() }
                // Cancelled (or out of time) before the work could be told: it is told now.
                if race.timedOutEarly { work.cancel() }
                Task {
                    var used: TimeInterval = 0
                    var last = ProcessInfo.processInfo.systemUptime
                    while used < seconds, !race.isDone {
                        try? await Task.sleep(for: .milliseconds(200))
                        let now = ProcessInfo.processInfo.systemUptime
                        let step = now - last
                        last = now
                        if step < 5, !paused() { used += step }
                    }
                    race.timeOut()
                }
            }
        } onCancel: {
            race.timeOut()
        }
    }

    /// Whoever comes first answers; the other is ignored.
    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        private var done = false
        var onTimeout: (@Sendable () -> Void)? {
            get { lock.withLock { _onTimeout } }
            set { lock.withLock { _onTimeout = newValue } }
        }
        private var _onTimeout: (@Sendable () -> Void)?

        var isDone: Bool { lock.withLock { done } }
        /// Ended by the clock or a cancel before `onTimeout` was set.
        var timedOutEarly: Bool { lock.withLock { done && endedByTimeout } }
        private var endedByTimeout = false

        func start(_ c: CheckedContinuation<T?, Never>) {
            lock.withLock { if done { c.resume(returning: nil) } else { continuation = c } }
        }

        func finish(_ value: T) { resume(value, timedOut: false) }
        func timeOut() { resume(nil, timedOut: true) }

        private func resume(_ value: T?, timedOut: Bool) {
            let (c, cancel): (CheckedContinuation<T?, Never>?, (@Sendable () -> Void)?) = lock.withLock {
                guard !done else { return (nil, nil) }
                done = true
                endedByTimeout = timedOut
                defer { continuation = nil }
                return (continuation, timedOut ? _onTimeout : nil)
            }
            cancel?()
            c?.resume(returning: value)
        }
    }
}
