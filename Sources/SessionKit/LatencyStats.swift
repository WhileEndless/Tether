import Foundation

/// Rolling round-trip-time statistics for a connection.
public struct LatencyStats: Equatable, Sendable {
    public enum Quality: String, Sendable {
        case unknown = "Measuring…", excellent = "Excellent", good = "Good", fair = "Fair", poor = "Poor", lost = "Lost"
    }

    /// Recent samples in seconds (newest last).
    public private(set) var samples: [Double] = []
    public private(set) var lost = false
    private let capacity = 60

    public init() {}

    public mutating func record(_ rtt: TimeInterval) {
        lost = false
        samples.append(rtt)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    public mutating func markLost() { lost = true }

    public var last: Double? { samples.last }

    /// Median of recent samples (robust against single spikes).
    public var median: Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.suffix(15).sorted()
        return sorted[sorted.count / 2]
    }

    /// Mean absolute difference between consecutive samples.
    public var jitter: Double? {
        let recent = Array(samples.suffix(15))
        guard recent.count >= 3 else { return nil }
        let diffs = zip(recent.dropFirst(), recent).map { abs($0 - $1) }
        return diffs.reduce(0, +) / Double(diffs.count)
    }

    public var quality: Quality {
        if lost { return .lost }
        guard let m = median else { return .unknown }
        let j = jitter ?? 0
        switch (m, j) {
        case (..<0.05, ..<0.02): return .excellent
        case (..<0.15, ..<0.05): return .good
        case (..<0.40, _): return .fair
        default: return .poor
        }
    }

    public static func format(_ seconds: Double?) -> String {
        guard let s = seconds else { return "—" }
        return s < 1 ? "\(Int((s * 1000).rounded())) ms" : String(format: "%.1f s", s)
    }
}
