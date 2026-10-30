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
        let resume = HistoryCatchUp.resume(captured: plain, anchor: tail.lines)!
        let out = HistoryCatchUp.output(captured: capture.lines, from: resume.index, anchorRow: tail.lastRow,
                                        cursorRow: local.screenCursorRow(), height: rows,
                                        cursor: capture.cursor, replacingAnchorRow: resume.replacesLastRow)
        local.feed(out.stream[...])
        local.feed(out.redraw[...])
        let live = makeView()
        live.feed(Array((before + during).utf8)[...])
        #expect(local.getTerminal().getCursorLocation().y == live.getTerminal().getCursorLocation().y)
        return (allText(local), allText(live))
    }

    /// As `tmuxCapture`, with wrapped rows joined (`capture-pane -J`).
    func tmuxCaptureJoined(_ stream: String) -> [[UInt8]] {
        let reference = makeView()
        reference.feed(Array(stream.utf8)[...])
        let t = reference.getTerminal()
        var lines: [[UInt8]] = []
        var r = t.buffer.totalLinesTrimmed
        while let line = t.getScrollInvariantLine(row: r) {
            let text = line.translateToString(trimRight: !(t.getScrollInvariantLine(row: r + 1)?.isWrapped ?? false))
            if line.isWrapped, !lines.isEmpty { lines[lines.count - 1] += Array(text.utf8) } else { lines.append(Array(text.utf8)) }
            r += 1
        }
        return lines
    }

    /// Long lines printed while away come back as the lines they were: made wider afterwards, the
    /// terminal shows each on one row, as if it had streamed in live (not cut at tmux's width).
    @Test func longLinesPrintedWhileAwayStayWhole() {
        let before = (1...12).map { "log \($0)\r\n" }.joined()
        let during = (13...30).map { "long \($0) " + String(repeating: "word ", count: 14) + "end\r\n" }.joined() + "$ "
        let local = makeView()
        local.feed(Array(before.utf8)[...])
        let capture = tmuxCapture(before + during)
        let tail = local.screenTail(maxRows: 12)!
        let plain = capture.lines.map(HistoryCatchUp.plainText)
        let resume = HistoryCatchUp.resume(captured: plain, anchor: tail.lines)!
        let joined = HistoryCatchUp.joinedLines(rows: plain, joined: tmuxCaptureJoined(before + during), from: resume.index)
        #expect(joined != nil, "the joined capture lines up with the rows")
        let out = HistoryCatchUp.output(captured: joined ?? capture.lines, from: joined == nil ? resume.index : 0, anchorRow: tail.lastRow,
                                        height: rows, cursor: capture.cursor, replacingAnchorRow: resume.replacesLastRow,
                                        screen: capture.lines)
        local.feed(out.stream[...])
        local.feed(out.redraw[...])
        let live = makeView()
        live.feed(Array((before + during).utf8)[...])
        #expect(allText(local) == allText(live), "as if it had streamed in")
        local.getTerminal().resize(cols: 120, rows: rows)
        live.getTerminal().resize(cols: 120, rows: rows)
        #expect(allText(local) == allText(live), "and made wider, the same rows")
        #expect(allText(local).contains { $0.hasPrefix("long 20 ") && $0.hasSuffix("end") }, "each long line on one row")
    }

    /// The joined lines are used only when they line up with the rows; otherwise nil (the rows are).
    @Test func joinedLinesLineUpOrAreNotUsed() {
        let rows = ["a", "bbbb", "bb", "c"].map { $0 }
        let joined = [Array("a".utf8), Array("bbbbbb".utf8), Array("c".utf8)]
        #expect(HistoryCatchUp.joinedLines(rows: rows, joined: joined, from: 1)?.map { String(decoding: $0, as: UTF8.self) } == ["bbbbbb", "c"])
        #expect(HistoryCatchUp.joinedLines(rows: rows, joined: joined, from: 3)?.map { String(decoding: $0, as: UTF8.self) } == ["c"])
        #expect(HistoryCatchUp.joinedLines(rows: rows, joined: joined, from: 2) == nil, "inside a wrapped line")
        #expect(HistoryCatchUp.joinedLines(rows: rows, joined: [Array("a".utf8), Array("zz".utf8)], from: 1) == nil, "output came between")
        #expect(HistoryCatchUp.joinedLines(rows: rows, joined: joined, from: 4) == [], "nothing after")
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

    /// The connection dropped in the middle of a line (a prompt, output without its line end yet):
    /// the rest of that line arrives on it, not as a second copy below.
    @Test func lineCutOffMidwayIsCompleted() {
        let before = (1...15).map { "log \($0)\r\n" }.joined() + "building target"
        let during = " … done\r\n" + (16...40).map { "log \($0)\r\n" }.joined() + "$ "
        let (local, live) = catchUp(before: before, during: during)
        #expect(local == live)
        #expect(local.filter { $0.hasPrefix("building target") } == ["building target … done"])
    }

    /// A progress line redrawn in place (carriage return) while disconnected: found by the rows
    /// above it, and shown once in its final form.
    @Test func progressLineRedrawnMeanwhile() {
        let before = (1...15).map { "log \($0)\r\n" }.joined() + "downloading  45%"
        let during = "\rdownloading 100%\r\n" + (16...30).map { "log \($0)\r\n" }.joined() + "$ "
        let (local, live) = catchUp(before: before, during: during)
        #expect(local == live)
        #expect(local.filter { $0.hasPrefix("downloading") } == ["downloading 100%"])
    }

    /// A restored tab draws its recording at the width it has now: zsh's `%` for output without a
    /// final line break (printed with as many spaces as the terminal was wide, then taken back)
    /// stays on a row of its own, and long lines wrap elsewhere. The place is still found — the
    /// server's whole history printed again (and its commands without their marks) is what it was.
    @Test func anchorDrawnAtAnotherWidthIsFound() {
        let promptSP = "\u{1b}[1m\u{1b}[7m%\u{1b}[27m\u{1b}[1m\u{1b}[0m" + String(repeating: " ", count: cols - 1) + "\r \r"
        let long = String(repeating: "abcdefghij", count: 6)
        let before = (1...20).map { "log \($0)\r\n" }.joined() + long + "\r\n" + "\(promptSP)$ ls\r\n" + "file\r\n" + "\(promptSP)$ "
        let during = "\r\n" + (21...30).map { "log \($0)\r\n" }.joined() + "\(promptSP)$ "
        let narrow = makeView()
        narrow.getTerminal().resize(cols: 30, rows: rows)
        narrow.showEarlierOutput(Array(before.utf8)[...])
        let tail = narrow.screenTail(maxRows: 12)!
        #expect(tail.lines.contains("%"), "drawn at another width: \(tail.lines)")
        let capture = tmuxCapture(before + during)
        let plain = capture.lines.map(HistoryCatchUp.plainText)
        let resume = HistoryCatchUp.resume(captured: plain, anchor: tail.lines)
        // Right after the prompt shown then: the rest is what was printed while away.
        #expect(resume.map { Array(plain[$0.index...]).filter { !$0.isEmpty }.first } == "log 21", "\(String(describing: resume))")
        // Seen at the server's width, nothing new: nothing to add.
        let same = tmuxCapture(before)
        let samePlain = same.lines.map(HistoryCatchUp.plainText)
        let none = HistoryCatchUp.resume(captured: samePlain, anchor: tail.lines)
        #expect(none.map { samePlain[$0.index...].allSatisfy(\.isEmpty) } == true, "\(String(describing: none))")
    }

    /// What a catch-up adds is recorded, and a recording is shown again at other heights: a tab
    /// restored after a relaunch first draws at a guessed size (the anchor's row is on that screen),
    /// the history view at the window's, tmux's pane has its own. Replayed taller, the recording
    /// must still hold every line once, and a command typed next must be on the prompt's line —
    /// rows counted from the top of the screen it was written for put both elsewhere.
    @Test func recordedCatchUpReplaysAtAnotherHeight() {
        func view(rows: Int) -> TetherTerminalView {
            let v = makeView()
            v.getTerminal().resize(cols: cols, rows: rows)
            return v
        }
        let before = (1...40).map { "out \($0)\r\n" }.joined() + "$ make"
        let during = "\r\n" + (1...5).map { "built \($0)\r\n" }.joined() + "$ "
        let local = view(rows: rows)                       // the guessed size
        local.showEarlierOutput(Array(before.utf8)[...])
        let server = view(rows: 20)                        // tmux's pane
        server.feed(Array((before + during).utf8)[...])
        let t = server.getTerminal()
        var lines: [[UInt8]] = []
        var r = t.buffer.totalLinesTrimmed
        while let line = t.getScrollInvariantLine(row: r) {
            lines.append(Array(line.translateToString(trimRight: true).utf8))
            r += 1
        }
        let cursor = (x: t.getCursorLocation().x, y: t.getCursorLocation().y)
        let tail = local.screenTail(maxRows: 12)!
        let resume = HistoryCatchUp.resume(captured: lines.map(HistoryCatchUp.plainText), anchor: tail.lines)!
        let out = HistoryCatchUp.output(captured: lines, from: resume.index, anchorRow: tail.lastRow,
                                        cursorRow: local.screenCursorRow(), height: 20, cursor: cursor,
                                        replacingAnchorRow: resume.replacesLastRow)
        // The recording: what came before, the catch-up's stream, then the next command echoed.
        let recorded = Array(before.utf8) + out.stream + Array("ls".utf8)
        for height in [rows, 20, 30] {
            let replay = view(rows: height)
            replay.feed(recorded[...])
            let expected = view(rows: height)
            expected.feed(Array((before + during + "ls").utf8)[...])
            #expect(allText(replay) == allText(expected), "replayed with \(height) rows")
        }
    }

    @Test func resumeNeedsEnoughToBeSure() {
        // A changed single row alone is not enough to place it.
        #expect(HistoryCatchUp.resume(captured: ["a", "b", "y"], anchor: ["x"]) == nil)
        #expect(HistoryCatchUp.resume(captured: ["", "b", "y"], anchor: ["", "x"]) == nil)
        #expect(HistoryCatchUp.resume(captured: ["a", "b", "y", "z"], anchor: ["a", "b", "x"])
                == HistoryCatchUp.Resume(index: 2, replacesLastRow: true))
        // An exact place, even an older one, comes before a guess from the rows above.
        #expect(HistoryCatchUp.resume(captured: ["a", "b", "c", "a", "b", "x"], anchor: ["a", "b", "c"])
                == HistoryCatchUp.Resume(index: 3, replacesLastRow: false))
    }

    @Test func plainTextDropsEscapes() {
        #expect(HistoryCatchUp.plainText(Array("\u{1b}[1;31mred\u{1b}[0m  ".utf8)) == "red")
        #expect(HistoryCatchUp.plainText(Array("\u{1b}]0;title\u{07}x".utf8)) == "x")
        #expect(HistoryCatchUp.resumeIndex(captured: ["a", "b", "c"], anchor: ["x"]) == nil)
        #expect(HistoryCatchUp.resumeIndex(captured: ["a", "b", "a", "b", "c"], anchor: ["a", "b"]) == 4)
    }
}
