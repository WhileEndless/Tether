import Foundation
import Testing
@testable import SessionKit

/// A tab restored in the background has no real size yet: its screen is drawn again from tmux once
/// the size is known, so a full-screen program (Claude Code) fits without resizing the window by
/// hand — also when tmux already had that size and sends the program no SIGWINCH.
@MainActor
@Suite struct TmuxRedrawTests {
    @Test func screenRestoredWithoutSizeIsDrawnAgain() {
        let driver = TmuxDriver(version: "3.4", isReattach: true, terminalIsEmpty: true, historyLines: 10, ownSession: false)
        var written: [String] = []
        var refreshed: [String] = []
        var size: (cols: Int, rows: Int)? = nil
        driver.write = { written.append($0) }
        driver.refresh = { refreshed.append(String(decoding: $0, as: UTF8.self)) }
        driver.size = { size }
        driver.receive(Array("\u{1b}P1000p".utf8))
        driver.receive(Array("%begin 1 0 0\n%end 1 0 0\n".utf8))                       // the attach command
        driver.receive(Array("%begin 1 1 0\n%1 0 0 2 120 3 0\n%end 1 1 0\n".utf8))    // pane info
        driver.receive(Array("%begin 1 2 0\nold 1\nold 2\n%end 1 2 0\n".utf8))          // capture (restored)
        #expect(driver.ready)
        #expect(!written.joined().contains("refresh-client"))                          // no guessed size sent

        size = (120, 3)
        written = []
        driver.resize(cols: 120, rows: 3)
        #expect(written.joined().contains("refresh-client -C 120x3"))
        driver.receive(Array("%begin 1 3 0\n%end 1 3 0\n".utf8))                       // resize
        driver.receive(Array("%begin 1 4 0\n%1 0 0 2 120 3 0\n%end 1 4 0\n".utf8))    // pane info again
        driver.receive(Array("%begin 1 5 0\n> prompt\n│ box │\n╰─────╯\n%end 1 5 0\n".utf8))
        let redraw = refreshed.joined()
        #expect(redraw.contains("> prompt") && redraw.contains("╰─────╯"))
        #expect(!redraw.contains("\u{1b}[2J"))                                         // no clear: no old frame kept

        // Only once: a later resize does not capture again.
        written = []
        driver.resize(cols: 100, rows: 3)
        #expect(!written.joined().contains("capture-pane"))
    }
}
