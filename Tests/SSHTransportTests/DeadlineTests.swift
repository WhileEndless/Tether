import Foundation
import Testing
@testable import SSHTransport

/// The limit on getting a connection: kept even by work that does not stop when cancelled, and
/// not counting the time the user is being asked something.
@Suite struct DeadlineTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ v: Bool) { lock.withLock { value = v } }
        var isSet: Bool { lock.withLock { value } }
    }

    @Test func aResultInTimeIsReturned() async {
        let value = await Deadline.run(seconds: 2) { () -> Int in
            try? await Task.sleep(for: .milliseconds(50))
            return 7
        }
        #expect(value == 7)
    }

    /// Work that ignores cancellation (a process waited for without a way to stop it) does not
    /// hold the caller past the limit.
    @Test func theLimitHoldsForWorkThatDoesNotStop() async {
        let began = Date()
        // On a thread of its own (as a process waited for would be): it ignores cancellation, and
        // holds none of the threads other tests run on.
        let value = await Deadline.run(seconds: 0.5) { () -> Int in
            await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
                Thread.detachNewThread {
                    Thread.sleep(forTimeInterval: 10)
                    c.resume(returning: 1)
                }
            }
        }
        #expect(value == nil)
        // Well before the 10 s the work takes (with room for a busy test run).
        #expect(Date().timeIntervalSince(began) < 5)
    }

    /// The user being asked something does not use up the time.
    @Test func timeWhileTheUserIsAskedDoesNotCount() async {
        let asking = Flag(); asking.set(true)
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            asking.set(false)
        }
        let value = await Deadline.run(seconds: 0.6, paused: { asking.isSet }) { () -> Int in
            try? await Task.sleep(for: .milliseconds(1400))
            return 3
        }
        #expect(value == 3, "the 1.2 s of asking did not count against the 0.6 s")
    }

    /// The caller is cancelled (a tab closed): the wait ends at once.
    @Test func cancellingTheCallerEndsTheWait() async {
        let began = Date()
        let task = Task {
            await Deadline.run(seconds: 30) { () -> Int in
                try? await Task.sleep(for: .seconds(20))
                return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let value = await task.value
        #expect(value == nil)
        #expect(Date().timeIntervalSince(began) < 5, "well before the 20 s of the work or the 30 s limit")
    }
}

/// A command cannot make Tether hold more of its output than its caller allows.
@Suite struct OutputLimitTests {
    @Test func outputPastTheLimitStopsTheCommand() async {
        let began = Date()
        // `yes` prints for ever: it is stopped once past the limit, and the run fails.
        let r = await ProcessRunner.run("/usr/bin/yes", arguments: [], timeout: 20, maxOutput: 64 << 10)
        #expect(r.status == -1)
        #expect(r.stdout.count <= 64 << 10)
        #expect(r.errorOutput.contains("more than Tether reads"))
        #expect(Date().timeIntervalSince(began) < 10)
    }

    @Test func outputWithinTheLimitIsKept() async {
        let r = await ProcessRunner.run("/bin/sh", arguments: ["-c", "printf 'abc'"], timeout: 10, maxOutput: 3)
        #expect(r.succeeded)
        #expect(r.output == "abc")
    }
}
