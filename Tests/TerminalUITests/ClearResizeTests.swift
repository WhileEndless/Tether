import AppKit
import Testing
import SwiftTerm
import TetherCore
@testable import SessionKit
@testable import TerminalUI

/// After a clear the prompt is at the top; the terminal getting taller (the window's real size
/// arriving, a resize) must not pull the cleared screen back down and leave it mid-screen.
@MainActor
@Suite struct ClearResizeTests {
    func makeView(rows: Int = 10) -> TetherTerminalView {
        _ = NSApplication.shared
        let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) { SessionConfiguration(settings: AppSettings()) }
        let view = TetherTerminalView(session: session, settings: AppSettings())
        view.getTerminal().resize(cols: 40, rows: rows)
        return view
    }

    func row(_ view: TetherTerminalView, _ r: Int) -> String {
        (view.getTerminal().getLine(row: r)?.translateToString(trimRight: true) ?? "").trimmingCharacters(in: .whitespaces)
    }

    @Test func clearThenTallerKeepsThePromptAtTheTop() {
        let view = makeView()
        view.feed(Array((1...8).map { "old \($0)\r\n" }.joined().utf8)[...])
        view.feed(Array("$ clear\r\n\u{1b}[H\u{1b}[2J$ ".utf8)[...])
        #expect(row(view, 0) == "$")
        view.resizeKeepingPrompt(cols: 40, rows: 20)
        #expect(row(view, 0) == "$")
        #expect(view.getTerminal().getCursorLocation().y == 0)
        // The cleared lines are still in the history.
        #expect(view.scrollbackText().lines.contains("old 3"))
    }

    @Test func tallerWithoutAClearStillShowsEarlierLines() {
        // Normal behaviour stays: with output on screen, growing shows more of the history.
        let view = makeView()
        view.feed(Array((1...30).map { "line \($0)\r\n" }.joined().utf8)[...])
        view.feed(Array("$ ".utf8)[...])
        view.resizeKeepingPrompt(cols: 40, rows: 20)
        #expect(row(view, 19) == "$")
    }
}
