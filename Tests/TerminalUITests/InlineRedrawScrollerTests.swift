import AppKit
import Testing
import TetherCore
@testable import RecordingKit
@testable import SessionKit
@testable import TerminalUI

/// A program that draws in place on the normal screen (a coding agent's prompt box, redrawn on
/// every key) writes line breaks without adding lines: the scroller must not shrink, and
/// scrolling up must not open the recording while memory holds everything.
@MainActor
@Suite(.serialized) struct InlineRedrawScrollerTests {
    /// The box an agent keeps redrawing, as it looks after `typed` keys.
    static func frame(_ typed: String) -> [String] {
        ["╭──────────────────────────────╮", "│ > \(typed)", "╰──────────────────────────────╯", "  ? for shortcuts", ""]
    }

    enum Redraw: CaseIterable { case cursorUp, fullScreen }

    /// One redraw of the box: up over the old one and over it again (as Ink does), or the whole
    /// screen cleared and drawn again (a frame taller than the screen).
    static func redraw(_ typed: String, previous: Int, style: Redraw) -> [UInt8] {
        let body = frame(typed).joined(separator: "\r\n")
        switch style {
        case .cursorUp:
            let erase = String(repeating: "\u{1b}[2K\u{1b}[1A", count: max(previous - 1, 0)) + "\u{1b}[2K\r"
            return Array((erase + body).utf8)
        case .fullScreen:
            return Array(("\u{1b}[2J\u{1b}[3J\u{1b}[H" + body).utf8)
        }
    }

    @Test(arguments: Redraw.allCases)
    func typingIntoAnInlineAgentKeepsTheScrollerOnMemory(_ style: Redraw) async throws {
        let f = try HistoryBrowsingTests.Fixture(lines: (1...60).map { "\($0) output" }, scrollback: 2000)
        func send(_ bytes: [UInt8]) { f.view.feed(bytes[...]); f.recorder.append(bytes) }
        send(Array(Self.frame("").joined(separator: "\r\n").utf8))
        f.view.updateHistoryScroller()
        let before = f.view.historyScroller.total
        var typed = ""
        for key in String(repeating: "hello world ", count: 25) {
            typed = String((typed + String(key)).suffix(30))      // one row: the box keeps its height
            send(Self.redraw(typed, previous: Self.frame("").count, style: style))
        }
        f.recorder.flush()
        #expect(f.recorder.index.lines > 1000, "the recording took in many line breaks (\(f.recorder.index.lines))")
        #expect(!f.view.hasOlderOutput, "memory holds everything")
        f.view.updateHistoryScroller()
        #expect(f.view.historyScroller.total == f.view.bufferLineCount, "the scroller stands for memory")
        #expect(f.view.historyScroller.total <= before + f.view.getTerminal().rows, "it did not grow with every key")

        // Up to the top with the scroller: memory's top, not the recording.
        f.view.scrollHistory(toLine: 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!f.view.isBrowsingHistory, "no Back to Live")
        #expect(f.view.getTerminal().buffer.yDisp == 0, "memory's first row at the top")
        #expect(f.top() == 1, "the first line shown (\(f.top()))")
    }

    /// Once lines have gone from memory, the scroller stands for the whole session again and
    /// takes the user into the recording, as before.
    @Test func afterLinesDropTheScrollerReachesTheRecordingAgain() async throws {
        let f = try HistoryBrowsingTests.Fixture(lines: (1...4000).map { "line \($0)" })
        #expect(f.view.hasOlderOutput)
        f.view.updateHistoryScroller()
        #expect(f.view.historyScroller.total > f.view.bufferLineCount)
        f.view.scrollHistory(toLine: 50)
        for _ in 0..<300 where !f.view.isBrowsingHistory || f.view.history?.loading == true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.view.isBrowsingHistory)
    }

    /// A tab restored after a relaunch shows its recording's end again: whether more is before it
    /// is told by bytes, not by line breaks (an agent's redraws write thousands of them).
    @Test func aRestoredTailIsPartialOnlyWhenTheRecordingHoldsMore() {
        #expect(!TerminalSession.tailIsPartial(tailBytes: 5000, recordingLength: 5000))
        #expect(TerminalSession.tailIsPartial(tailBytes: 4000, recordingLength: 5000))
        #expect(!TerminalSession.tailIsPartial(tailBytes: 0, recordingLength: 0))
    }

    @Test func aRestoredTabWhoseTailIsTheWholeRecordingHasNothingOlder() async throws {
        let f = try HistoryBrowsingTests.Fixture(lines: [], scrollback: 2000)
        var bytes = Array((1...50).map { "\($0) output" }.joined(separator: "\r\n").utf8) + [0x0d, 0x0a]
        for n in 0..<400 { bytes += Self.redraw("key \(n)", previous: Self.frame("").count, style: .cursorUp) }
        f.recorder.append(bytes)
        f.view.showEarlierOutput(bytes[...])
        f.recorder.flush()
        #expect(f.recorder.index.lines > 1500)
        #expect(!f.view.hasOlderOutput, "not partial: nothing older than memory")
        f.view.earlierOutputIsPartial()
        #expect(f.view.hasOlderOutput, "partial: the rest is in the recording")
    }
}
