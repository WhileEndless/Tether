import Foundation
import Testing
import TerminalText

/// The text of a recording is what the terminal showed: no screens of full-screen programs, no
/// redraw frames, no repeated redraws, each line as it finally looked.
@Suite struct ScreenTextTests {
    func text(_ s: String, cols: Int = ScreenText.defaultCols) -> [String] {
        ScreenText.lines(from: Array(s.utf8), cols: cols)
    }

    @Test func fullScreenProgramsAddNothing() {
        var out = "before\r\n\u{1b}[?1049h\u{1b}[H\u{1b}[2J"
        for i in 1...200 { out += "\u{1b}[\((i % 40) + 1);1Hfile line \(i)\u{1b}[K" }   // vim scrolling a file
        out += "\u{1b}[50;1H-- INSERT --\u{1b}[?1049lafter\r\n"
        #expect(text(out) == ["before", "after"])
    }

    @Test func spinnerGivesItsLastState() {
        var out = ""
        for s in 1...30 { out += "\r\u{1b}[2K✻ Thinking… (\(s)s)" }
        out += "\r\u{1b}[2KDone\r\n"
        #expect(text(out) == ["Done"])
    }

    @Test func inPlaceEditsGiveTheFinalLine() {
        let out = "row1\r\nrow2\r\n\u{1b}[1A\u{1b}[2Krow2 fixed\r\n"
        #expect(text(out) == ["row1", "row2 fixed"])
    }

    /// Claude Code redraws the whole conversation after clearing everything: each line once.
    @Test func redrawAfterClearIsNotRepeated() {
        let conversation = (1...30).map { "message \($0)\r\n" }.joined()
        let out = conversation + "\u{1b}[2J\u{1b}[3J\u{1b}[H" + conversation + "new answer\r\n"
        #expect(text(out) == (1...30).map { "message \($0)" } + ["new answer"])
    }

    /// A short repeat after a clear (the same command run again) is kept.
    @Test func shortRepeatAfterClearIsKept() {
        let out = "$ ls\r\na b\r\n\u{1b}[H\u{1b}[2J$ ls\r\na b\r\n"
        #expect(text(out) == ["$ ls", "a b", "$ ls", "a b"])
    }

    @Test func clearKeepsWhatWasOnScreen() {
        let out = "one\r\ntwo\r\n\u{1b}[H\u{1b}[2Jthree\r\n"
        #expect(text(out) == ["one", "two", "three"])
    }

    @Test func wrappedRowsAreJoinedAtTheRecordedWidth() {
        let long = String(repeating: "x", count: 150)
        let marker = String(decoding: SizeMarker.bytes(cols: 80, rows: 24), as: UTF8.self)
        #expect(text(marker + long + "\r\nend\r\n") == [long, "end"])
        #expect(text(long + "\r\n") == [long])
    }

    @Test func longOutputLosesNothing() {
        let out = (0..<12_000).map { "line \($0)\r\n" }.joined()
        let lines = text(out)
        #expect(lines.count == 12_000)
        #expect(lines.first == "line 0" && lines.last == "line 11999")
    }

    @Test func chunksMayCutSequencesAnywhere() {
        let out = Array(("a\r\n\u{1b}[?1049hscreen\u{1b}[?1049lb\r\n" + String(decoding: SizeMarker.bytes(cols: 90, rows: 30), as: UTF8.self) + "c\r\n").utf8)
        for cut in 1..<out.count {
            let s = ScreenText()
            let lines = s.feed(out[..<cut]) + s.feed(out[cut...]) + s.finish()
            #expect(lines == ["a", "b", "c"], "cut at \(cut)")
        }
    }

    func marker(_ cols: Int, _ rows: Int) -> String { String(decoding: SizeMarker.bytes(cols: cols, rows: rows), as: UTF8.self) }

    /// Resizing while vim is open neither loses nor repeats the history before it.
    @Test func resizeInsideFullScreenProgram() {
        let history = (0..<100).map { "h\($0)\r\n" }.joined()
        let out = marker(80, 24) + history + "$ vim\r\n\u{1b}[?1049h\u{1b}[Hscreen" + marker(120, 40) + "\u{1b}[?1049l$ end\r\n"
        #expect(text(out) == (0..<100).map { "h\($0)" } + ["$ vim", "$ end"])
    }

    /// A recording that ends while a full-screen program is up keeps what was before it.
    @Test func recordingEndingInsideFullScreenProgram() {
        let out = "one\r\ntwo\r\n$ less file\r\n\u{1b}[?1049h\u{1b}[Hpage 1"
        #expect(text(out) == ["one", "two", "$ less file"])
    }

    @Test func wideCharactersHaveNoGaps() {
        #expect(text("中文测试 ok 🙂\r\n") == ["中文测试 ok 🙂"])
    }

    /// A clear that falls on the boundary of the pieces fed to the emulator still keeps the screen.
    @Test func clearAcrossSliceBoundary() {
        let filler = String(repeating: "\u{1b}[32m" + String(repeating: "c", count: 90) + "\u{1b}[0m\r\n", count: 300)
        for shift in 0..<6 {
            let pad = String(repeating: "x", count: shift)
            let out = pad + filler + "KEEP1\r\nKEEP2\r\n\u{1b}[H\u{1b}[2Jafter\r\n"
            #expect(text(out).suffix(3) == ["KEEP1", "KEEP2", "after"], "shift \(shift)")
        }
    }

    /// A resize at the prompt does not repeat the prompt.
    @Test func resizeAtPrompt() {
        let out = marker(80, 24) + "$ " + marker(100, 30) + "ls\r\nfile\r\n"
        #expect(text(out) == ["$ ls", "file"])
    }

    /// A redraw whose first line (a box border) appears many times is still found.
    @Test func redrawWithCommonFirstLine() {
        let frame = { (n: Int) in "╭────╮\r\n│ \(n) │\r\n╰────╯\r\n" }
        let conversation = (1...6).map(frame).joined()
        let out = conversation + "\u{1b}[2J\u{1b}[3J\u{1b}[H" + conversation + "done\r\n"
        #expect(text(out).count == 6 * 3 + 1)
    }

    /// The same command run again after a clear, later on, is kept (only a redraw of everything up
    /// to the clear is taken once).
    @Test func repeatedCommandAfterClearIsKept() {
        let cat = "$ cat cfg\r\n" + (1...15).map { "key\($0) = value\r\n" }.joined()
        let between = (0..<20).map { "$ y\($0)\r\n" }.joined()
        let out = cat + between + "\u{1b}[H\u{1b}[2J\u{1b}[3J" + cat + "$ done\r\n"
        let lines = text(out)
        #expect(lines.filter { $0 == "$ cat cfg" }.count == 2)
        #expect(lines.filter { $0 == "key7 = value" }.count == 2)
    }

    @Test func combinedPrivateModesCountAsFullScreen() {
        let out = "before\r\n\u{1b}[?1049;1006h\u{1b}[Hjunk\r\njunk\u{1b}[?1049;1006lafter\r\n"
        #expect(text(out) == ["before", "after"])
    }

    @Test func escapeStateKnowsWhereSequencesEnd() {
        var e = EscapeState()
        e.feed(Array("text\u{1b}[".utf8)); #expect(e.isInside)
        e.feed(Array("2J".utf8)); #expect(!e.isInside)
        e.feed(Array("\u{1b}]0;title".utf8)); #expect(e.isInside)
        e.feed([0x07]); #expect(!e.isInside)
        e.feed(Array("\u{1b}(B".utf8)); #expect(!e.isInside)
    }

    @Test func sizeMarkersAreFound() {
        let bytes = Array("x".utf8) + SizeMarker.bytes(cols: 120, rows: 40) + Array("y".utf8) + SizeMarker.bytes(cols: 90, rows: 20)
        #expect(SizeMarker.last(in: bytes[...])?.cols == 90)
        #expect(SizeMarker.find(in: bytes[...])?.1.rows == 40)
    }
}

@Suite struct ScreenTextSpeedTests {
    /// Large recordings are read at a usable speed (search and export go through this). Kept small
    /// (5 MB) so the test suite stays light on memory.
    @Test func fiveMegabytes() {
        let line = Array((String(repeating: "abcdefghij", count: 9) + "\r\n").utf8)
        var data: [UInt8] = []
        data.reserveCapacity(line.count * 50_000)
        for _ in 0..<50_000 { data += line }
        let start = Date()
        let s = ScreenText()
        var count = 0
        var i = 0
        while i < data.count {
            count += s.feed(data[i..<min(i + 4 << 20, data.count)]).count
            i += 4 << 20
        }
        count += s.finish().count
        let seconds = Date().timeIntervalSince(start)
        #expect(count == 50_000)
        #expect(seconds < 10, "took \(seconds) s")
    }
}
