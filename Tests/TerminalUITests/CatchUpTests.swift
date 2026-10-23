import AppKit
import Testing
import SwiftTerm
import TetherCore
@testable import SessionKit
@testable import TerminalUI

/// After a reconnect, output the server printed meanwhile must end up in the local terminal exactly
/// as if it had streamed in live: nothing missing, nothing twice, the screen as tmux has it.
@MainActor
@Suite struct CatchUpTests {
    let cols = 40, rows = 10

    func makeView() -> TetherTerminalView {
        _ = NSApplication.shared
        let descriptor = SessionDescriptor(target: .local, persistence: .off)
        let session = TerminalSession(descriptor: descriptor) { SessionConfiguration(settings: AppSettings()) }
        let view = TetherTerminalView(session: session, settings: AppSettings())
        view.getTerminal().resize(cols: cols, rows: rows)
        return view
    }

    func allText(_ view: TetherTerminalView) -> [String] {
        let t = view.getTerminal()
        var lines: [String] = []
        var r = t.buffer.totalLinesTrimmed
        while let line = t.getScrollInvariantLine(row: r) {
            lines.append(line.translateToString(trimRight: true))
            r += 1
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// What tmux would capture for a pane that received `stream`: history + the full screen.
    func tmuxCapture(_ stream: String) -> (lines: [[UInt8]], cursor: (x: Int, y: Int)) {
        let reference = makeView()
        reference.feed(Array(stream.utf8)[...])
        let t = reference.getTerminal()
        var lines: [[UInt8]] = []
        var r = t.buffer.totalLinesTrimmed
        while let line = t.getScrollInvariantLine(row: r) {
            lines.append(Array(line.translateToString(trimRight: true).utf8))
            r += 1
        }
        let c = t.getCursorLocation()
        return (lines, (c.x, c.y))
    }

    func catchUp(before: String, during: String, file: String = #fileID) -> (local: [String], live: [String]) {
        let local = makeView()
        local.feed(Array(before.utf8)[...])                               // live until the connection drops
        let capture = tmuxCapture(before + during)                         // the server kept going
        let tail = local.screenTail(maxRows: 12)!
        let plain = capture.lines.map(HistoryCatchUp.plainText)
        let start = HistoryCatchUp.resumeIndex(captured: plain, anchor: tail.lines)!
        let out = HistoryCatchUp.output(captured: capture.lines, from: start, anchorRow: tail.lastRow, height: rows, cursor: capture.cursor)
        local.feed(out.stream[...])
        local.feed(out.redraw[...])
        let live = makeView()
        live.feed(Array((before + during).utf8)[...])
        #expect(local.getTerminal().getCursorLocation().y == live.getTerminal().getCursorLocation().y)
        return (allText(local), allText(live))
    }

    @Test func logsWhileDisconnectedArriveInOrder() {
        let before = (1...25).map { "log \($0)\r\n" }.joined()
        let during = (26...80).map { "log \($0)\r\n" }.joined() + "$ "
        let (local, live) = catchUp(before: before, during: during)
        #expect(local == live)
        #expect(local.contains("log 26") && local.contains("log 80"))
    }

    @Test func fewNewLinesWithoutScrolling() {
        let (local, live) = catchUp(before: "a\r\nb\r\n", during: "c\r\nd\r\n$ ")
        #expect(local == live)
    }

    @Test func repeatedLinesAreNotDropped() {
        let before = (1...12).map { _ in "same\r\n" }.joined() + "marker\r\n"
        let during = (1...30).map { _ in "same\r\n" }.joined()
        let (local, live) = catchUp(before: before, during: during)
        #expect(local == live)
    }

    @Test func plainTextDropsEscapes() {
        #expect(HistoryCatchUp.plainText(Array("\u{1b}[1;31mred\u{1b}[0m  ".utf8)) == "red")
        #expect(HistoryCatchUp.plainText(Array("\u{1b}]0;title\u{07}x".utf8)) == "x")
        #expect(HistoryCatchUp.resumeIndex(captured: ["a", "b", "c"], anchor: ["x"]) == nil)
        #expect(HistoryCatchUp.resumeIndex(captured: ["a", "b", "a", "b", "c"], anchor: ["a", "b"]) == 4)
    }
}
