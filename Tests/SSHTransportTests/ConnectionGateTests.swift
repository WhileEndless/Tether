import Foundation
import Testing
@testable import SSHTransport

/// Background work for a host waits while a login to it is in progress — with or without a shared
/// connection — so its ssh does not ask the host-key question a second time.
@Suite struct ConnectionGateTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func backgroundWorkWaitsForTheLoginInProgress() async throws {
        let gate = ConnectionGate()
        let key = "user@gate-\(UUID()).example.com"
        await gate.acquire(key)                       // a tab is logging in
        let ran = Flag()
        let job = Task { await gate.waitForTurn(key); ran.set() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!ran.isSet)
        await gate.release(key)                       // the login finished
        await job.value
        #expect(ran.isSet)
        // Nothing in progress: no wait at all, and the gate is free afterwards.
        await gate.waitForTurn(key)
        await gate.acquire(key)
        await gate.release(key)
    }

    /// A login whose question is in front of the user holds the others back — they do not start a
    /// login (and a question) of their own — but only up to the cap.
    @Test func waitersWaitForAQuestionOnScreenUpToTheCap() async throws {
        let onScreen = Flag(); onScreen.set()
        let gate = ConnectionGate(userWaitCap: 0.6, waitsOnUser: { _ in onScreen.isSet })
        let key = "user@asking-\(UUID()).example.com"
        await gate.acquire(key)
        let started = Date()
        let owned = await gate.acquire(key, timeout: 0.1)
        let waited = Date().timeIntervalSince(started)
        #expect(!owned)
        #expect(waited >= 0.5 && waited < 8, "waited \(waited) s (the cap is 0.6 s; without it, for good)")
        // The holder still waits on the user: the waiter is told so, to wait for the user too.
        #expect(await gate.holderWaitsOnUser(key))
        await gate.release(key)
        #expect(await !gate.holderWaitsOnUser(key))
    }

    /// A question nobody can see (held back for a tab in the background, Tether locked) does not
    /// hold the queue: the waiter goes on after its timeout.
    @Test func aQuestionNobodySeesDoesNotHoldTheQueue() async throws {
        let gate = ConnectionGate(userWaitCap: 60, waitsOnUser: { _ in false })
        let key = "user@hidden-\(UUID()).example.com"
        await gate.acquire(key)
        let started = Date()
        let owned = await gate.acquire(key, timeout: 0.1)
        #expect(!owned)
        #expect(Date().timeIntervalSince(started) < 8, "the 60 s cap does not apply to a question nobody sees")
        #expect(await !gate.holderWaitsOnUser(key))
        await gate.release(key)
    }

    /// The question is answered while the waiter waits: the turn passes to it as usual.
    @Test func theTurnPassesOnOnceTheQuestionIsAnswered() async throws {
        let onScreen = Flag(); onScreen.set()
        let gate = ConnectionGate(userWaitCap: 60, waitsOnUser: { _ in onScreen.isSet })
        let key = "user@answered-\(UUID()).example.com"
        await gate.acquire(key)
        let waiter = Task { await gate.acquire(key, timeout: 0.1) }
        try await Task.sleep(for: .milliseconds(400))
        await gate.release(key)                       // signed in: the next one's turn
        #expect(await waiter.value)
        await gate.release(key)
    }
}
