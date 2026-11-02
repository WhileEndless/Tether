import Foundation

/// How long to wait before trying again: twice as long after each failure, from `base`, up to
/// `longest` — the one rule for every retry in Tether (a server's tabs, a host panel's stream, a
/// running-command sampler). `maxDoublings` keeps the arithmetic finite long before `longest` caps it.
public enum Backoff {
    /// The wait after `doublings` doublings of `base` (0: `base` itself), never longer than `longest`.
    public static func delay(base: Double, doublings: Int, longest: Double, maxDoublings: Int = 16) -> Double {
        min(base * pow(2, Double(min(max(doublings, 0), maxDoublings))), longest)
    }
}
