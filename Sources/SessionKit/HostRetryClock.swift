import Foundation

/// When the waiting tabs of one server try again: one schedule per server, not one per tab. The
/// first failure plans a round a moment later; further failures plan each round further away (up
/// to the longest wait in Settings), and a tab failing while a round is planned joins it instead
/// of adding attempts of its own. A server that cannot be reached is then tried once per round,
/// however many tabs wait for it.
///
/// Only automatic retries follow it: Reconnect and the network coming back try at once, and a
/// server answering again (any tab online) starts the schedule afresh.
@MainActor
public final class HostRetryClock {
    public static let shared = HostRetryClock()

    struct Round {
        var level: Int
        var at: Date
        var failedAt: Date
        var why: String?
    }

    private var rounds: [String: Round] = [:]

    public init() {}

    /// The time the tabs of `host` try again after a failed attempt, and whether this failure
    /// planned it (false: the tab joins a round another tab's failure planned).
    /// `why`: what the failed attempt said, for tabs that join the round without trying themselves.
    public func next(for host: String, base: Double, longest: Double, why: String? = nil, now: Date = Date()) -> (at: Date, planned: Bool) {
        if var r = rounds[host], r.at > now {
            r.failedAt = now
            if let why { r.why = why }
            rounds[host] = r
            return (r.at, false)
        }
        let base = max(base, 0.5), longest = max(longest, base)
        // Quiet for a long while since the last failure: a new outage starts again at the shortest wait.
        let previous = rounds[host].flatMap { now.timeIntervalSince($0.failedAt) < longest * 2 ? $0.level : nil } ?? 0
        let level = previous + 1
        let delay = min(base * pow(2, Double(min(level - 1, 16))), longest)
        let at = now.addingTimeInterval(delay)
        rounds[host] = Round(level: level, at: at, failedAt: now, why: why)
        return (at, true)
    }

    /// A round planned by a failure after `date` (another tab's attempt): an attempt this tab
    /// planned before would only fail the same way, so it waits for that round.
    public func failedSince(_ date: Date, host: String, now: Date = Date()) -> (at: Date, why: String?)? {
        guard let r = rounds[host], r.failedAt > date, r.at > now else { return nil }
        return (r.at, r.why)
    }

    /// The server answered (a tab came online): the next outage starts at the shortest wait.
    public func reached(_ host: String) { rounds[host] = nil }

    /// The network came back or the user asked: every server starts afresh.
    public func reset(_ host: String? = nil) {
        if let host { rounds[host] = nil } else { rounds.removeAll() }
    }
}
