import AppKit
import Testing
import SwiftTerm
import TetherCore
@testable import SessionKit
@testable import TerminalUI

/// Ctrl+L and `clear` must not lose history (Terminal.app behaviour).
@MainActor
@Suite struct ClearScreenTests {
    func makeView() -> TetherTerminalView {
        _ = NSApplication.shared
        let descriptor = SessionDescriptor(target: .local, persistence: .off)
        let session = TerminalSession(descriptor: descriptor) { SessionConfiguration(settings: AppSettings()) }
        let view = TetherTerminalView(session: session, settings: AppSettings())
        view.getTerminal().resize(cols: 40, rows: 10)
        return view
    }

    func feed(_ view: TetherTerminalView, _ text: String) {
        view.feed(Array(text.utf8)[...])
    }

    func screenRow(_ view: TetherTerminalView, _ row: Int) -> String {
        (view.getTerminal().getLine(row: row)?.translateToString(trimRight: true) ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// A program's notification (OSC 9/777) or the bell marks the session; seeing it clears it.
    @Test func notificationsAndBellMarkTheSession() {
        _ = NSApplication.shared
        let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) { SessionConfiguration(settings: AppSettings()) }
        let view = TetherTerminalView(session: session, settings: AppSettings())
        view.getTerminal().resize(cols: 40, rows: 10)
        var raised: [TerminalSession.Attention] = []
        session.onAttention = { _, a in raised.append(a) }
        feed(view, "work\u{1b}]9;Claude is done\u{7}more")
        #expect(session.attention == .message(TerminalNotification(body: "Claude is done")))
        feed(view, "\u{7}")
        // The message stays on the tab; the bell after it is still reported.
        #expect(session.attention == .message(TerminalNotification(body: "Claude is done")))
        #expect(raised.count == 2 && raised.last == .bell)
        session.clearAttention()
        feed(view, "\u{1b}]777;notify;Build;finished\u{1b}\\")
        #expect(session.attention == .message(TerminalNotification(title: "Build", body: "finished")))
        // Not shown as text on the screen.
        #expect(screenRow(view, 0) == "workmore")
    }

    /// Saving a session (⌘S) writes lines as the program wrote them: wrapped rows are joined.
    @Test func logicalTextJoinsWrappedRows() {
        let view = makeView()
        let long = String(repeating: "abcdefghij", count: 9)   // 90 columns: three rows at 40
        feed(view, "first\r\n" + long + "\r\nend   \r\n")
        let (trimmed, lines, logical) = view.logicalText()
        #expect(!trimmed)
        #expect(lines == ["first", long, "end"])
        #expect(logical >= 3)
    }

    @Test func ctrlLKeepsScreenInScrollbackAndPromptGoesToTop() {
        let view = makeView()
        feed(view, "line one\r\nline two\r\nline three\r\n$ ")
        // What a shell prints for Ctrl+L: home, erase screen, then the prompt again.
        feed(view, "\u{1b}[H\u{1b}[2J$ ")
        let text = view.scrollbackText().lines
        #expect(text.contains("line one") && text.contains("line three"))
        #expect(screenRow(view, 0) == "$")
        #expect(view.getTerminal().getCursorLocation().y == 0)
    }

    /// Inside tmux and screen, shells clear with "home, erase below" (ESC[H ESC[J): kept the same way.
    @Test func tmuxStyleClearKeepsScreenInScrollback() {
        let view = makeView()
        feed(view, "line one\r\nline two\r\n$ ")
        feed(view, "\u{1b}[H\u{1b}[J$ ")
        let text = view.scrollbackText().lines
        #expect(text.contains("line one") && text.contains("line two"))
        #expect(screenRow(view, 0) == "$")
        // Erasing below the cursor elsewhere on the screen is ordinary output, not a clear.
        let other = makeView()
        feed(other, "a\r\nb\r\nc\u{1b}[2;1H\u{1b}[J")
        #expect(!other.scrollbackText().lines.contains("a") || screenRow(other, 0) == "a")
        #expect(screenRow(other, 0) == "a" && screenRow(other, 1).isEmpty)
    }

    @Test func clearCommandCannotEraseScrollback() {
        let view = makeView()
        for i in 1...30 { feed(view, "output \(i)\r\n") }
        feed(view, "$ clear\r\n\u{1b}[H\u{1b}[2J\u{1b}[3J$ ")
        let text = view.scrollbackText().lines
        #expect(text.contains("output 1") && text.contains("output 30"))
        #expect(screenRow(view, 0) == "$")
    }

    @Test func commandKStillClearsEverything() {
        let view = makeView()
        for i in 1...30 { feed(view, "output \(i)\r\n") }
        view.clearBuffer()
        #expect(!view.scrollbackText().lines.contains("output 1"))
    }

    @Test func emptyScreenAddsNoBlankLines() {
        let view = makeView()
        feed(view, "\u{1b}[H\u{1b}[2J\u{1b}[H\u{1b}[2J$ ")
        #expect(view.scrollbackText().lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } == ["$"])
    }
}
