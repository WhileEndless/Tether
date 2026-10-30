import Foundation
import Testing
@testable import SessionKit

/// One retry schedule per server: its tabs try together, further apart after each failure.
@MainActor
@Suite struct HostRetryClockTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    /// A hundred tabs failing for one server plan one round; the next failure doubles the wait.
    @Test func tabsOfOneServerShareOneRound() {
        let clock = HostRetryClock()
        let first = clock.next(for: "web", base: 2, longest: 120, now: t0)
        #expect(first.planned && first.at == t0.addingTimeInterval(2))
        for i in 1..<100 {
            let joined = clock.next(for: "web", base: 2, longest: 120, now: t0.addingTimeInterval(Double(i) / 100))
            #expect(!joined.planned && joined.at == first.at)
        }
        let second = clock.next(for: "web", base: 2, longest: 120, now: t0.addingTimeInterval(3))
        #expect(second.planned && second.at == t0.addingTimeInterval(3 + 4))
    }

    /// The wait grows to the longest one and stays there; another server has its own schedule.
    @Test func waitsGrowToTheLongestAndServersAreSeparate() {
        let clock = HostRetryClock()
        var now = t0, waits: [Double] = []
        for _ in 0..<10 {
            let r = clock.next(for: "web", base: 2, longest: 60, now: now)
            waits.append(r.at.timeIntervalSince(now))
            now = r.at.addingTimeInterval(20)    // the round's attempt waited out the timeout
        }
        #expect(waits == [2, 4, 8, 16, 32, 60, 60, 60, 60, 60])
        #expect(clock.next(for: "db", base: 2, longest: 60, now: now).at == now.addingTimeInterval(2))
    }

    /// A server that answered, or a network that came back, starts again at the shortest wait;
    /// so does a new outage long after the last failure.
    @Test func answeringResetsTheSchedule() {
        let clock = HostRetryClock()
        _ = clock.next(for: "web", base: 2, longest: 60, now: t0)
        _ = clock.next(for: "web", base: 2, longest: 60, now: t0.addingTimeInterval(5))
        clock.reached("web")
        #expect(clock.next(for: "web", base: 2, longest: 60, now: t0.addingTimeInterval(6)).at == t0.addingTimeInterval(8))
        clock.reset()
        #expect(clock.next(for: "web", base: 2, longest: 60, now: t0.addingTimeInterval(9)).at == t0.addingTimeInterval(11))
        _ = clock.next(for: "web", base: 2, longest: 60, now: t0.addingTimeInterval(12))
        #expect(clock.next(for: "web", base: 2, longest: 60, now: t0.addingTimeInterval(1_000)).at == t0.addingTimeInterval(1_002))
    }

    /// A tab that waited its turn behind another tab's attempt learns that attempt failed meanwhile.
    @Test func aTabQueuedBehindAFailedAttemptJoinsTheRound() {
        let clock = HostRetryClock()
        #expect(clock.failedSince(t0, host: "web", now: t0) == nil)
        let round = clock.next(for: "web", base: 2, longest: 60, why: "Connection timed out", now: t0.addingTimeInterval(20))
        let joined = clock.failedSince(t0, host: "web", now: t0.addingTimeInterval(20))
        #expect(joined?.at == round.at && joined?.why == "Connection timed out")
        // Queued after that failure (Reconnect pressed later): it goes ahead.
        #expect(clock.failedSince(t0.addingTimeInterval(21), host: "web", now: t0.addingTimeInterval(21)) == nil)
        // The round is due: nothing to wait for.
        #expect(clock.failedSince(t0, host: "web", now: round.at) == nil)
    }
}
