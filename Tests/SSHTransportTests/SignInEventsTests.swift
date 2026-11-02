import Foundation
import Testing
@testable import SSHTransport

/// Sign-ins are told about in order, to observers that are not kept alive by being told; the gate
/// holds a sign-in until it may start; a cancel or a "wanted again" is taken once.
@Suite struct SignInEventsTests {
    final class Recorder: SignInObserver, @unchecked Sendable {
        let lock = NSLock()
        var seen: [SignInEvent] = []
        func signIn(_ event: SignInEvent) { lock.withLock { seen.append(event) } }
    }

    final class Gate: SignInGatekeeper, @unchecked Sendable {
        let lock = NSLock()
        var waiting: [CheckedContinuation<Void, Never>] = []
        func mayStart() async { await withCheckedContinuation { c in lock.withLock { waiting.append(c) } } }
        func open() { lock.withLock { waiting.forEach { $0.resume() }; waiting = [] } }
        var count: Int { lock.withLock { waiting.count } }
    }

    @Test func toldInOrderAndHeldWeakly() {
        let events = SignInEvents()
        var recorder: Recorder? = Recorder()
        events.add(recorder!)
        events.post(.started(token: "t1", connection: "c"))
        events.post(.ended(token: "t1", end: .succeeded))
        #expect(recorder?.seen == [.started(token: "t1", connection: "c"), .ended(token: "t1", end: .succeeded)])
        weak let gone = recorder
        recorder = nil
        #expect(gone == nil, "being an observer does not keep it alive")
        events.post(.ended(token: "t2", end: .failed))      // nobody there: nothing happens
    }

    @Test func theGateHoldsUntilOpened() async throws {
        let events = SignInEvents()
        await events.mayStart()                              // no gatekeeper: at once
        let gate = Gate()
        events.gatekeeper = gate
        let started = Task { await events.mayStart(); return true }
        while gate.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        gate.open()
        #expect(await started.value)
    }

    @Test func aCancelIsTakenOnce() {
        let events = SignInEvents()
        events.userCancelled(token: "t")
        #expect(events.takeCancelled(token: "t"))
        #expect(!events.takeCancelled(token: "t"))
    }
}
