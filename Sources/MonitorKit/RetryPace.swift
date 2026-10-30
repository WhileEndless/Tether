import Foundation

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
        return min(first * pow(2, Double(min(failures - 1, 12))), max(Self.longest, first))
    }

    mutating func reset() { failures = 0 }
}
