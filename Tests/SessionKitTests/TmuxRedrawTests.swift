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

    /// Another client of the session (another computer) used last: tmux sizes the window for it.
    /// The pane is drawn again with the rows below it cleared (no old frame left under the live
    /// one), and typing here sizes the window for this terminal again — once, not on every key.
    @Test func windowSizedForAnotherClient() async throws {
        let driver = TmuxDriver(version: "3.4", isReattach: false, terminalIsEmpty: true, historyLines: 10, ownSession: false)
        var written: [String] = []
        var refreshed: [String] = []
        driver.write = { written.append($0) }
        driver.refresh = { refreshed.append(String(decoding: $0, as: UTF8.self)) }
        driver.size = { (120, 6) }
        /// The window's size is asked once the layout settled (a moment later, also under load: other
        /// suites on the main actor can hold it for seconds while they wait for tmux).
        func waitForSizeQuestion() async throws {
            let deadline = ContinuousClock.now + .seconds(60)
            while !written.joined().contains("#{window_width} #{window_height}"), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(written.joined().contains("#{window_width} #{window_height}"))
        }
        driver.receive(Array("\u{1b}P1000p".utf8))
        driver.receive(Array("%begin 1 0 0\n%end 1 0 0\n".utf8))                       // the attach command
        driver.receive(Array("%begin 1 1 0\n%1 0 0 2 120 6 0\n%end 1 1 0\n".utf8))    // pane info
        driver.receive(Array("%begin 1 2 0\n%end 1 2 0\n".utf8))                       // our size
        #expect(driver.ready)

        // Our own size coming back: nothing to do.
        written = []
        driver.receive(Array("%layout-change @0 aafd,120x6,0,0,0 aafd,120x6,0,0,0 *\n".utf8))
        try await waitForSizeQuestion()
        #expect(written.joined().contains("#{window_width} #{window_height}"))
        driver.receive(Array("%begin 1 3 0\n120 6\n%end 1 3 0\n".utf8))
        #expect(driver.otherClientSize == nil)
        written = []
        driver.sendInput(Array("a".utf8), byUser: true)
        #expect(!written.joined().contains("select-window"))
        driver.receive(Array("%begin 1 31 0\n%end 1 31 0\n".utf8))                     // send-keys

        // Another client's smaller size.
        written = []
        driver.receive(Array("%layout-change @0 a25d,80x4,0,0,0 a25d,80x4,0,0,0 *\n".utf8))
        try await waitForSizeQuestion()
        driver.receive(Array("%begin 1 4 0\n80 4\n%end 1 4 0\n".utf8))
        #expect(driver.otherClientSize?.cols == 80 && driver.otherClientSize?.rows == 4)
        #expect(written.joined().contains("display-message -p '#{pane_id}"))           // the screen again
        driver.receive(Array("%begin 1 5 0\n%1 0 0 1 80 4 0\n%end 1 5 0\n".utf8))
        driver.receive(Array("%begin 1 6 0\nlive 1\nlive 2\n\n\n%end 1 6 0\n".utf8))
        let redraw = refreshed.joined()
        #expect(redraw.contains("live 1") && redraw.contains("\u{1b}[5;1H\u{1b}[0m\u{1b}[J")) // rows 5–6 cleared

        // Output or reports do not take the window back; typing does, once.
        written = []
        driver.sendInput(Array("\u{1b}[I".utf8))
        #expect(!written.joined().contains("select-window"))
        driver.sendInput(Array("x".utf8), byUser: true)
        driver.sendInput(Array("y".utf8), byUser: true)
        let sent = written.joined()
        #expect(sent.components(separatedBy: "select-window -t %1").count == 2)
        #expect(sent.contains("refresh-client -C 120x6"))
        let claim = try #require(sent.range(of: "select-window")), typed = try #require(sent.range(of: "send-keys -t %1 -H 78"))
        #expect(claim.lowerBound < typed.lowerBound)

        // The window is ours again: noted, drawn once more.
        written = []
        driver.receive(Array("%layout-change @0 aafd,120x6,0,0,0 aafd,120x6,0,0,0 *\n".utf8))
        try await waitForSizeQuestion()
        written = []
        for n in 0..<5 { driver.receive(Array("%begin 1 \(40 + n) 0\n%end 1 \(40 + n) 0\n".utf8)) } // keys, select, size
        driver.receive(Array("%begin 1 10 0\n120 6\n%end 1 10 0\n".utf8))
        #expect(driver.otherClientSize == nil)
        #expect(written.joined().contains("display-message -p '#{pane_id}"))
    }
}
