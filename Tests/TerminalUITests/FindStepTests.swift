import AppKit
import Testing
import TetherCore
import SwiftTerm
import TerminalText
@testable import SessionKit
@testable import TerminalUI

/// ↩ / ⌘G in the find bar always moves to a match and brings it into sight.
@MainActor
@Suite(.serialized) struct FindStepTests {
    func onScreen() -> (TetherTerminalView, NSWindow) {
        _ = NSApplication.shared
        var settings = AppSettings()
        settings.scrollbackLines = 5_000
        let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) { SessionConfiguration(settings: settings) }
        let view = TetherTerminalView(session: session, settings: settings)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        window.contentView = view
        window.alphaValue = 0
        window.orderFrontRegardless()
        return (view, window)
    }

    func feed(_ view: TetherTerminalView, _ lines: [String]) {
        view.feed(Array(lines.map { $0 + "\r\n" }.joined().utf8)[...])
    }

    /// A long scrollback makes a changed term wait for typing to pause: a step taken meanwhile is
    /// on the new term's matches and is not undone when that look is made.
    @Test func aStepWhileTheTermWaitsIsKept() async throws {
        let (view, window) = onScreen()
        defer { window.orderOut(nil) }
        var lines = (1...400).map { "line \($0)" }
        for n in [100, 200, 300] { lines[n] = "apple \(n)" }
        for n in [50, 150, 250, 350] { lines[n] = "pear \(n)" }
        feed(view, lines)
        var status = TerminalFindStatus()
        view.onFindStatus = { status = $0 }
        view.setFind(TerminalFindQuery(term: "apple"))
        view.findSession?.fullScanDuration = 1      // as a long scrollback takes
        view.setFind(TerminalFindQuery(term: "pear"))
        view.findStep(forward: true)
        let after = status.current
        #expect(status.total == 4, "the new term's matches (\(status.total))")
        try await Task.sleep(for: .milliseconds(300))
        #expect(status.current == after, "the step stays (\(after) → \(status.current))")
        #expect(view.currentFindMatchText == "pear")
    }

    /// The same term again (typed and taken back before the search ran): nothing changes, so the
    /// caller steps instead.
    @Test func theSameTermAgainSaysNothingChanged() {
        let (view, window) = onScreen()
        defer { window.orderOut(nil) }
        feed(view, ["apple 1", "apple 2"])
        #expect(view.setFind(TerminalFindQuery(term: "apple")))
        #expect(!view.setFind(TerminalFindQuery(term: "apple")))
    }

    /// A match on the rows the find bar covers is scrolled down into sight; one below them is not
    /// moved.
    @Test func aMatchUnderTheFindBarIsBroughtIntoSight() async throws {
        let (view, window) = onScreen()
        defer { window.orderOut(nil) }
        let t = view.getTerminal()
        feed(view, (1...300).map { "line \($0)" })
        view.findBarHeight = 40
        // Scrolled so that "needle" ends up on the top row.
        feed(view, ["needle top"] + (1...(t.rows - 2)).map { "after \($0)" })
        view.setFind(TerminalFindQuery(term: "needle"))
        let covered = view.findBarCoveredRows
        #expect(covered >= 2)
        let top = t.buffer.totalLinesTrimmed + t.getTopVisibleRow()
        let row = try #require(view.findSession?.current.flatMap { view.findSession?.matches[$0].row })
        #expect(row - top >= covered, "below the bar: row \(row - top) of the screen, bar covers \(covered)")
        #expect(TetherTerminalView.inSight(row...row, top: top, rows: t.rows, coveredAtTop: covered))
    }
}
