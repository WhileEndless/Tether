import Foundation
import Testing
import SwiftTerm
import TerminalText

/// The history view draws what a stretch of the recording left instead of replaying it: the rows
/// must be the very same — text, colours, styles, wrapping — and the positions asked about must be
/// on the rows they were on.
@Suite struct ReplayCompactorTests {
    final class Sink: TerminalDelegate { func send(source: Terminal, data: ArraySlice<UInt8>) {} }

    func terminal(cols: Int, rows: Int, scrollback: Int) -> (Terminal, Sink) {
        let sink = Sink()
        var o = TerminalOptions.default
        o.cols = cols
        o.rows = rows
        o.scrollback = scrollback
        let t = Terminal(delegate: sink, options: o)
        t.registerOscHandler(code: 7771) { _ in }
        return (t, sink)
    }

    /// Every row from the first kept to the cursor's, as text and attributes per cell.
    func cells(_ t: Terminal) -> [String] {
        var out: [String] = []
        var lo = t.buffer.totalLinesTrimmed, hi = lo + 1_000_000
        while lo < hi { let mid = (lo + hi) / 2; if t.getScrollInvariantLine(row: mid) != nil { lo = mid + 1 } else { hi = mid } }
        let last = lo - t.rows + t.getCursorLocation().y
        for r in t.buffer.totalLinesTrimmed...max(last, t.buffer.totalLinesTrimmed) {
            guard let line = t.getScrollInvariantLine(row: r) else { continue }
            var s = line.isWrapped ? "↩" : ""
            var cellsText: [String] = []
            for c in 0..<min(line.count, t.cols) {
                let cell = line[c]
                let ch = t.getCharacter(for: cell)
                cellsText.append("\(ch == "\0" ? " " : ch)|\(cell.attribute.fg)|\(cell.attribute.bg)|\(cell.attribute.style.rawValue)|\(cell.width)")
            }
            // Blank cells with no colour at the end are not part of what was printed.
            while let l = cellsText.last, l.hasPrefix(" |defaultColor|defaultInvertedColor|0|") || l.hasPrefix(" |defaultColor|defaultColor|0|") {
                cellsText.removeLast()
            }
            s += cellsText.joined(separator: ",")
            // As copying and finding read it.
            s += "#" + line.translateToString(trimRight: true)
            out.append(s)
        }
        return out
    }

    func sample() -> [UInt8] {
        var s = ""
        for i in 0..<60 {
            s += "\u{1b}[1;32mok\u{1b}[0m line \(i) \u{1b}[38;5;208mamber\u{1b}[0m \u{1b}[48;2;10;20;30mbg\u{1b}[0m \u{1b}[3;4mstyled\u{1b}[0m\r\n"
            if i % 10 == 3 { s += String(repeating: "long-", count: 30) + "end\r\n" }        // wraps
            if i % 10 == 5 { s += "wide: 日本語テキスト 😀 done\r\n" }
            if i % 10 == 7 {
                // A status block redrawn in place.
                for f in 0..<5 {
                    s += f == 0 ? "" : "\u{1b}[2A"
                    s += "\r\u{1b}[2K\u{1b}[35m✻ frame \(f)\u{1b}[0m\r\n\r\u{1b}[2K│ status \(f)\r\n"
                }
            }
            if i == 40 { s += "\u{1b}[?1049h\u{1b}[H\u{1b}[2Jfull screen\u{1b}[?1049l" }
            if i == 50 { s += "\u{1b}[2J\u{1b}[Hcleared screen\r\n" }
        }
        s += "$ "
        return Array(s.utf8)
    }

    @Test func theRowsAreTheSameAsAReplayAndPositionsKeepTheirRows() {
        let data = sample()
        let (cols, rows, scrollback) = (40, 12, 2_000)
        // Positions: the starts of a few lines.
        var cuts: [Int] = []
        var i = 0, n = 0
        while i < data.count { if data[i] == 0x0a { n += 1; if n % 17 == 0 { cuts.append(i + 1) } }; i += 1 }

        let (replayed, _) = terminal(cols: cols, rows: rows, scrollback: scrollback)
        var expectedRows: [Int: Int] = [:]
        var from = 0
        for cut in cuts {
            ScrollbackRule.feed(data[from..<cut], terminal: replayed) { replayed.feed(buffer: $0) }
            var lo = 0, hi = 1_000_000
            while lo < hi { let mid = (lo + hi) / 2; if replayed.getScrollInvariantLine(row: mid) != nil { lo = mid + 1 } else { hi = mid } }
            expectedRows[cut] = lo - replayed.rows + replayed.getCursorLocation().y
            from = cut
        }
        ScrollbackRule.feed(data[from...], terminal: replayed) { replayed.feed(buffer: $0) }

        let r = ReplayCompactor.compact(data, start: 0, cuts: cuts, cols: cols, rows: rows, scrollback: scrollback,
                                        startsInAlternate: false, programsMayClear: false)
        let (drawn, _) = terminal(cols: cols, rows: rows, scrollback: scrollback)
        drawn.feed(byteArray: r.bytes)
        let a = cells(drawn), b = cells(replayed)
        if let k = a.indices.first(where: { $0 < b.count && a[$0] != b[$0] }) {
            print("DIFF row \(k)\nDRAWN \(a[k].suffix(300))\nREPLY \(b[k].suffix(300))")
        }
        #expect(a.count == b.count)
        #expect(a == b)
        for (cut, row) in expectedRows { #expect(r.rows[cut] == row, "position \(cut)") }
    }

    /// Kept rows only: what scrolled out of the scrollback while replaying is not drawn, and
    /// positions on those rows are left out.
    @Test func rowsLostToTheScrollbackAreLeftOut() {
        let data = Array((0..<500).map { "row \($0)\r\n" }.joined().utf8)
        let early = Array("row 0\r\n".utf8).count * 3
        let r = ReplayCompactor.compact(data, start: 0, cuts: [early], cols: 20, rows: 10, scrollback: 100,
                                        startsInAlternate: false, programsMayClear: false)
        #expect(r.rows[early] == nil)
        #expect(r.rowCount == 110, "100 rows of scrollback and the screen's 10")
        let (t, _) = terminal(cols: 20, rows: 10, scrollback: 100)
        t.feed(byteArray: r.bytes)
        #expect(t.getScrollInvariantLine(row: 0)?.translateToString(trimRight: true).trimmingCharacters(in: .whitespaces) == "row 391")
    }

    /// Read back from a recording, a program clearing on its own leaves its last screen too (the
    /// recording's command markers say when the user typed); a recording without markers clears as
    /// it always did.
    @Test func aRecordingLeavesWhatTheTerminalShowed() {
        let mark = "\u{1b}]7771;mark=1700000000000\u{07}"
        let withMarks = Array(("$ docker stats" + mark + "\r\n" + (0..<5).map { "\u{1b}[2J\u{1b}[Hweb \($0)%\r\n" }.joined()).utf8)
        let r = ReplayCompactor.compact(withMarks, start: 0, cuts: [], cols: 40, rows: 6, scrollback: 100,
                                        startsInAlternate: false, programsMayClear: false)
        let (t, _) = terminal(cols: 40, rows: 6, scrollback: 100)
        t.feed(byteArray: r.bytes)
        let text = cells(t).map { $0.components(separatedBy: "#").last ?? "" }
        #expect(text.contains { $0.hasPrefix("$ docker stats") })
        #expect(!text.contains { $0.hasPrefix("web 2%") })
        #expect(text.contains { $0.hasPrefix("web 4%") })

        let noMarks = Array(("$ old\r\n" + (0..<3).map { "\u{1b}[2J\u{1b}[Hold \($0)\r\n" }.joined()).utf8)
        let o = ReplayCompactor.compact(noMarks, start: 0, cuts: [], cols: 40, rows: 6, scrollback: 100,
                                        startsInAlternate: false, programsMayClear: false)
        let (u, _) = terminal(cols: 40, rows: 6, scrollback: 100)
        u.feed(byteArray: o.bytes)
        #expect(cells(u).contains { $0.hasSuffix("#old 1") }, "kept as before")
    }

    /// Shown again, a recording keeps the screens the terminal kept: commands run earlier do not add
    /// up, and each Return of a paste (noted as typed) lets one clear keep the screen.
    @Test func aRecordingKeepsTheScreensTheTerminalKept() {
        let mark = { (n: Int) in "\u{1b}]7771;mark=\(1_700_000_000_000 + n)\u{07}" }
        let typed = String(decoding: ScrollbackRule.typedMarker, as: UTF8.self)
        var out = (0..<20).map { "$ echo \($0)" + mark($0) + "\r\n\($0)\r\n" }.joined()
        out += "$ watch df" + mark(99) + "\r\n" + (0..<5).map { "\u{1b}[2J\u{1b}[Hused \($0)%\r\n" }.joined()
        out += "$ clear" + mark(100) + typed + typed + "\u{1b}[H\u{1b}[2J$ ls\r\nfile-a\r\n$ \u{1b}[H\u{1b}[2J$ "
        let r = ReplayCompactor.compact(Array(out.utf8), start: 0, cuts: [], cols: 40, rows: 6, scrollback: 200,
                                        startsInAlternate: false, programsMayClear: false)
        let (t, _) = terminal(cols: 40, rows: 6, scrollback: 200)
        t.feed(byteArray: r.bytes)
        let text = cells(t).map { $0.components(separatedBy: "#").last ?? "" }
        #expect(!text.contains { $0.hasPrefix("used 2%") }, "no screen on the way")
        #expect(text.contains { $0.hasPrefix("used 4%") })
        #expect(text.contains { $0.hasPrefix("file-a") }, "each clear of the paste kept its screen")
    }
}
