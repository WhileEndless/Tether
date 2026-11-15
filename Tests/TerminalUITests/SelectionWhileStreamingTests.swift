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

    @Test func coalescedVisibleOutputDrainsBeforeTheScreenIsRead() {
        let view = makeView()
        // Registry-backed terminals have a window as soon as they are placed in a tab, even if
        // AppKit has not displayed it yet. Keep the window alive to exercise that output path.
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.batchesWhileHidden = true

        view.feed(Array("coalesced line\r\n".utf8)[...])
        let terminal = view.getTerminal()
        let firstLine = terminal.getScrollInvariantLine(row: terminal.buffer.totalLinesTrimmed)?.translateToString(trimRight: true)
        #expect(firstLine != "coalesced line")

        // Operations that need the terminal's current state drain the queued bytes in order.
        view.flushHiddenOutput()
        #expect(view.scrollbackText().lines.contains("coalesced line"))
        _ = window
    }

    @Test func coalescedOutputCanOpenAnAlternateScreen() {
        let view = makeView()
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.batchesWhileHidden = true

        // This enters a full-screen TUI while queued output is drained. It must not re-enter the
        // drain through the reflow bookkeeping used to preserve the normal screen.
        view.feed(Array("\u{1b}[?1049h".utf8)[...])
        view.flushHiddenOutput()
        #expect(view.getTerminal().isCurrentBufferAlternate)
        _ = window
    }

    @Test func terminalGetsFocusAfterAnInitiallySmallHostIsLaidOut() async throws {
        _ = NSApplication.shared
        let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) { SessionConfiguration(settings: AppSettings()) }
        let terminal = TerminalRegistry.shared.view(for: session)
        defer { TerminalRegistry.shared.remove(session.id) }

        // SwiftUI can attach a representable before its final size is known. The terminal is
        // claimed only on the later layout pass and must then receive the keyboard.
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1, height: 1),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let host = TerminalHost.Container(frame: .zero)
        host.session = session
        window.contentView = host
        host.setFrameSize(.init(width: 500, height: 300))
        try await Task.sleep(for: .milliseconds(30))

        #expect(window.firstResponder === terminal)
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
