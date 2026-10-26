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
}
