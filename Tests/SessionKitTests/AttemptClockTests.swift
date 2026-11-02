import Foundation
import Testing
@testable import SessionKit

/// No stage of a connection attempt waits for ever, and no attempt is stopped while the user is
/// involved, while the Mac slept, or while it still makes progress.
@Suite struct AttemptClockTests {
    @Test func eachStageHasItsLimit() {
        for stage in [AttemptClock.Stage.preparing, .starting, .restoring] {
            var clock = AttemptClock(now: 0)
            var now: TimeInterval = 0
            var stopped = false
            while now < stage.budget + 10, !stopped {
                now += AttemptClock.tick
                stopped = clock.expired(stage: stage, paused: false, now: now)
            }
            #expect(stopped, "\(stage) never stopped")
            #expect(now > stage.budget && now <= stage.budget + AttemptClock.tick, "\(stage) stopped after \(now) s")
        }
    }

    /// A slow restore over a slow link keeps sending: never stopped.
    @Test func progressKeepsItGoing() {
        var clock = AttemptClock(now: 0)
        var now: TimeInterval = 0
        while now < 600 {
            now += AttemptClock.tick
            if Int(now) % 30 == 0 { clock.progressed(now: now) }
            let expired = clock.expired(stage: .restoring, paused: false, now: now)
            #expect(!expired)
        }
    }

    /// A question in front of the user (or a prompt in the terminal) may take minutes.
    @Test func theUserBeingAskedStopsTheClock() {
        var clock = AttemptClock(now: 0)
        var now: TimeInterval = 0
        while now < 600 {
            now += AttemptClock.tick
            let expired = clock.expired(stage: .starting, paused: true, now: now)
            #expect(!expired)
        }
        // Answered: the stage gets its whole limit from then on.
        now += AttemptClock.tick
        let afterAnswer = clock.expired(stage: .starting, paused: false, now: now)
        #expect(!afterAnswer)
        #expect(clock.idle(now: now) <= AttemptClock.tick)
    }

    /// The Mac slept (or macOS held Tether back): the time away does not count.
    @Test func aLateLookStartsTheCountAgain() {
        var clock = AttemptClock(now: 0)
        _ = clock.expired(stage: .starting, paused: false, now: 2)
        let late = clock.expired(stage: .starting, paused: false, now: 3_600)
        #expect(!late)
        let next = clock.expired(stage: .starting, paused: false, now: 3_602)
        #expect(!next)
        var now: TimeInterval = 3_602
        var stopped = false
        while !stopped, now < 3_800 {
            now += AttemptClock.tick
            stopped = clock.expired(stage: .starting, paused: false, now: now)
        }
        #expect(stopped && now - 3_600 > AttemptClock.Stage.starting.budget)
    }

    /// Stopping a sign-in is the last resort: its own limits (ssh's ConnectTimeout, the sign-in's
    /// watchdog) come first. Starting allows for slow, silent login scripts.
    @Test func signingInGetsTheLongestLimit() {
        #expect(AttemptClock.Stage.preparing.budget > AttemptClock.Stage.starting.budget)
        #expect(AttemptClock.Stage.preparing.budget > AttemptClock.Stage.restoring.budget)
        #expect(AttemptClock.Stage.starting.budget > 20, "longer than the start-up check's guess of a plain session")
        #expect(AttemptClock.Stage.restoring.budget >= 60, "a slow re-attach keeps sending; a silent minute is not one")
    }
}
