import AppKit
import Testing
import SwiftTerm
import TetherCore
@testable import SessionKit
@testable import TerminalUI

/// Text can be selected and copied from the history while a command keeps printing; a program
/// that tracks the mouse still gets it.
@MainActor
@Suite struct SelectionWhileStreamingTests {
    func makeView() -> TetherTerminalView {
        _ = NSApplication.shared
        let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) { SessionConfiguration(settings: AppSettings()) }
        let view = TetherTerminalView(session: session, settings: AppSettings())
        view.getTerminal().resize(cols: 40, rows: 10)
        return view
    }

    @Test func selectionStaysWhileOutputStreams() {
        let view = makeView()
        view.feed(Array((1...30).map { "probe \($0) id=\(1000 + $0)\r\n" }.joined().utf8)[...])
        let row = view.getTerminal().getTopVisibleRow() + 3          // a line on screen, soon in the history
        view.selection.setSelection(start: Position(col: 0, row: row), end: Position(col: 40, row: row))
        let picked = view.getSelection() ?? ""
        #expect(picked.hasPrefix("probe"))
        // More output arrives, line after line.
        for i in 31...60 { view.feed(Array("probe \(i) id=\(1000 + i)\r\n".utf8)[...]) }
        #expect(view.selection.active)
        #expect(view.getSelection() == picked)
        #expect(view.allowMouseReporting == false)                  // no program asked for the mouse
    }

    @Test func mouseTrackingProgramsStillGetTheMouse() {
        let view = makeView()
        view.feed(Array("\u{1b}[?1000h".utf8)[...])                // e.g. htop, vim with mouse=a
        #expect(view.allowMouseReporting)
        view.feed(Array("\u{1b}[?1000l".utf8)[...])
        #expect(!view.allowMouseReporting)
        // View ▸ Allow Mouse Reporting (⌘R) in this terminal: off, then back to the setting.
        view.feed(Array("\u{1b}[?1000h".utf8)[...])
        view.mouseReportingChoice = false
        #expect(!view.allowMouseReporting && !view.mouseReportingAllowed)
        view.mouseReportingChoice = nil
        #expect(view.allowMouseReporting)
        view.feed(Array("\u{1b}[?1000l".utf8)[...])
        // Settings ▸ Terminal: programs may not use the mouse at all.
        var s = AppSettings()
        s.allowMouseReporting = false
        view.apply(settings: s)
        view.feed(Array("\u{1b}[?1000h".utf8)[...])
        #expect(!view.allowMouseReporting)
    }
}
