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
