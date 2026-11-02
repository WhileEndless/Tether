import Foundation

/// How long a connection attempt may go without progress before it is stopped and tried again —
/// one clock for every stage, so no stage of a tab's attempt can wait for ever (a connection that
/// went dead while signing in, starting the session or restoring it showed "Connecting" until
/// the user pressed Retry).
///
/// Progress is anything that shows the attempt is alive: a line from ssh while signing in, output
/// from the server, a step reached. The clock does not run while the user is involved (a question
/// in front of them, a prompt in the terminal, the server waiting for something typed), while the
/// network is away or the Mac asleep, and a tick that comes late (sleep, App Nap) starts the count
/// again: only time the attempt really had counts.
struct AttemptClock {
    enum Stage: Equatable {
        /// Getting the connection: the shared connection's sign-in, the jump host, the server's shell.
        /// Every step there has its own limit; this one only catches what slips past them.
        case preparing
        /// The terminal's ssh runs; Tether's start-up check has not answered.
        case starting
        /// The start-up check answered; the session (tmux, screen) is being restored.
        case restoring

        var budget: TimeInterval {
            switch self {
            case .preparing: 180
            case .starting: 90
            case .restoring: 60
            }
        }

        /// For the tab's message: "No answer from example.com while …".
        var activity: String {
            switch self {
            case .preparing: "signing in"
            case .starting: "starting the session"
            case .restoring: "restoring the session"
            }
        }
    }

    /// How often the clock is looked at.
    static let tick: TimeInterval = 2

    private(set) var lastProgress: TimeInterval
    private var lastTick: TimeInterval

    init(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastProgress = now
        lastTick = now
    }

    mutating func progressed(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastProgress = now
    }

    /// Seconds since the attempt last made progress.
    func idle(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval { now - lastProgress }

    /// Looks at the clock; true when the attempt made no progress for longer than `stage` allows
    /// (times `scale`: tests use less).
    mutating func expired(stage: Stage, paused: Bool, scale: Double = 1,
                          now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        defer { lastTick = now }
        if paused || now - lastTick > Self.tick * 2 + 3 {
            lastProgress = now
            return false
        }
        return now - lastProgress > stage.budget * scale
    }
}
