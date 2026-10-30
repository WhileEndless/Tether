import AppKit
import Testing
import SwiftTerm
import TetherCore
@testable import SessionKit
@testable import TerminalUI

/// Mouse tracking left on by a program that ended goes once the shell is seen at its prompt, so the
/// wheel scrolls the history again instead of typing `64;41;22M` at the prompt.
@MainActor
@Suite struct StaleMouseTrackingTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func ruleNeedsTheShellSeenAfterTheModeWentOn() {
        let on = start
        // Seen at the prompt well after the mode went on: the program has ended.
        #expect(StaleMouseTracking.isStale(trackingSince: on, shellSeenAt: on.addingTimeInterval(3), alternateScreen: false, userChoice: nil))
        // Seen before, or just as it went on (an answer on its way while the program started): kept.
        #expect(!StaleMouseTracking.isStale(trackingSince: on, shellSeenAt: on.addingTimeInterval(-5), alternateScreen: false, userChoice: nil))
        #expect(!StaleMouseTracking.isStale(trackingSince: on, shellSeenAt: on.addingTimeInterval(0.5), alternateScreen: false, userChoice: nil))
        // A program runs, or nobody can tell: kept (fzf --height uses the mouse in the normal screen).
        #expect(!StaleMouseTracking.isStale(trackingSince: on, shellSeenAt: nil, alternateScreen: false, userChoice: nil))
        // Off already.
        #expect(!StaleMouseTracking.isStale(trackingSince: nil, shellSeenAt: on, alternateScreen: false, userChoice: nil))
        // A full-screen program's screen is never touched.
        #expect(!StaleMouseTracking.isStale(trackingSince: on, shellSeenAt: on.addingTimeInterval(3), alternateScreen: true, userChoice: nil))
        // ⌘R turned reporting on for this terminal: the user's choice wins; turned off, it is moot but harmless.
        #expect(!StaleMouseTracking.isStale(trackingSince: on, shellSeenAt: on.addingTimeInterval(3), alternateScreen: false, userChoice: true))
        #expect(StaleMouseTracking.isStale(trackingSince: on, shellSeenAt: on.addingTimeInterval(3), alternateScreen: false, userChoice: false))
    }

    func makeView() -> TetherTerminalView {
        _ = NSApplication.shared
        let descriptor = SessionDescriptor(target: .local, persistence: .off)
        let session = TerminalSession(descriptor: descriptor) { SessionConfiguration(settings: AppSettings()) }
        let view = TetherTerminalView(session: session, settings: AppSettings())
        view.getTerminal().resize(cols: 40, rows: 10)
        return view
    }

    @Test func viewDropsTrackingLeftAtThePrompt() {
        let view = makeView()
        view.feed(Array("\u{1b}[?1000h\u{1b}[?1006h$ ".utf8)[...])
        #expect(view.getTerminal().mouseMode != .off)
        #expect(view.allowMouseReporting)

        // Nothing known about the shell: the program keeps the mouse.
        view.dropStaleMouseTracking()
        #expect(view.getTerminal().mouseMode != .off)

        // The shell was seen at its prompt later: tracking goes, the wheel scrolls the history again.
        view.shellSeenAt = { Date().addingTimeInterval(5) }
        view.dropStaleMouseTracking()
        #expect(view.getTerminal().mouseMode == .off)
        #expect(!view.allowMouseReporting)

        // A program that turns it on again gets it (it was not seen ending yet).
        view.shellSeenAt = { Date().addingTimeInterval(-5) }
        view.feed(Array("\u{1b}[?1002h".utf8)[...])
        view.dropStaleMouseTracking()
        #expect(view.getTerminal().mouseMode != .off)
    }

    @Test func viewKeepsTrackingOnTheAlternateScreenAndByChoice() {
        let view = makeView()
        view.feed(Array("\u{1b}[?1049h\u{1b}[?1000h".utf8)[...])
        view.shellSeenAt = { Date().addingTimeInterval(5) }
        view.dropStaleMouseTracking()
        #expect(view.getTerminal().mouseMode != .off)

        let other = makeView()
        other.feed(Array("\u{1b}[?1000h".utf8)[...])
        other.mouseReportingChoice = true
        other.shellSeenAt = { Date().addingTimeInterval(5) }
        other.dropStaleMouseTracking()
        #expect(other.getTerminal().mouseMode != .off)
    }
}
