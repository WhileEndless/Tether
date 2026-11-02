import Testing
@testable import SSHTransport

/// One rule for every retry: twice as long each time, from the base, never past the longest wait.
@Suite struct BackoffTests {
    @Test func doublesUpToTheLongest() {
        #expect(Backoff.delay(base: 2, doublings: 0, longest: 120) == 2)
        #expect(Backoff.delay(base: 2, doublings: 3, longest: 120) == 16)
        #expect(Backoff.delay(base: 2, doublings: 10, longest: 120) == 120)
        #expect(Backoff.delay(base: 2, doublings: -1, longest: 120) == 2, "never shorter than the base")
        #expect(Backoff.delay(base: 1, doublings: 1_000, longest: .infinity, maxDoublings: 4) == 16, "finite however many failures")
    }
}
