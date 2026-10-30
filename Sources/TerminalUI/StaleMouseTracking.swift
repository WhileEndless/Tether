import Foundation

/// Mouse tracking a program left on after it ended (it crashed, was killed, or never turned it
/// off): at the shell prompt the wheel then typed `64;41;22M` into the command line instead of
/// scrolling, and clicks could not select. Tether drops it only when it is sure nothing that could
/// want the mouse runs any more: the shell itself was seen in front after the mode was turned on.
/// A program in front, or not knowing, keeps the mode (fzf --height uses the mouse in the normal
/// screen), and so does a full-screen program's alternate screen.
public enum StaleMouseTracking {
    /// How much later than the mode the shell must have been seen: an answer about the foreground
    /// that was on its way while the program started is not taken for the program having ended.
    public static let margin: TimeInterval = 1

    /// - Parameters:
    ///   - trackingSince: when the program turned mouse tracking on (nil: it is off).
    ///   - shellSeenAt: when the shell was last seen waiting at its prompt (nil: a program runs,
    ///     or it cannot be told).
    ///   - alternateScreen: the terminal shows the alternate (full-screen) screen.
    ///   - userChoice: the terminal's own Allow Mouse Reporting choice (⌘R); `true` means the user
    ///     wants programs to have the mouse here, whatever Tether thinks.
    public static func isStale(trackingSince: Date?, shellSeenAt: Date?, alternateScreen: Bool, userChoice: Bool?) -> Bool {
        guard let trackingSince, let shellSeenAt, !alternateScreen, userChoice != true else { return false }
        return shellSeenAt.timeIntervalSince(trackingSince) >= margin
    }

    /// Turns every mouse tracking mode and encoding off (fed to the terminal on this Mac only).
    public static let reset = Array("\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1005l\u{1b}[?1006l\u{1b}[?1015l".utf8)
}
