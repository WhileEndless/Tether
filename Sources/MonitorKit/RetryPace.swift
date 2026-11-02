import Foundation
import SSHTransport

/// How long a host panel's stream waits before it starts again after ending without data: a
/// server that does not answer is asked less and less often (twice as long each time, up to
/// `longest`, the longest wait between retries in Settings), and at once again when it answers.
public struct RetryPace: Sendable {
    /// Settings ▸ Sessions ▸ Longest wait between retries.
    @MainActor public static var longest: Double = 120

    private(set) var failures = 0

    public init() {}

    /// The wait after one more stream that ended without data.
    @MainActor mutating func next(first: Double) -> Double {
        failures += 1
        return Backoff.delay(base: first, doublings: failures - 1, longest: max(Self.longest, first), maxDoublings: 12)
    }

    mutating func reset() { failures = 0 }
}
