import Foundation
import Testing
import SwiftTerm
import TerminalText
import TetherCore

/// Find in the terminal: matches are found by the cells they cover, so they can be drawn where
/// the terminal shows them.
@Suite struct BufferSearchTests {
    final class Sink: TerminalDelegate { func send(source: Terminal, data: ArraySlice<UInt8>) {} }

    func terminal(_ text: String, cols: Int = 20, rows: Int = 5) -> (Terminal, Sink) {
        let sink = Sink()
        var options = TerminalOptions.default
        options.cols = cols
        options.rows = rows
        options.scrollback = 100
        let t = Terminal(delegate: sink, options: options)
        t.feed(text: text)
        return (t, sink)
    }

    func find(_ term: String, in t: Terminal, regex: Bool = false, caseSensitive: Bool = false, wholeWord: Bool = false) throws -> [BufferMatch] {
        BufferSearch.matches(in: t, regex: try BufferSearch.regex(term, isRegex: regex, caseSensitive: caseSensitive, wholeWord: wholeWord))
    }

    @Test func findsEveryMatchWithItsCells() throws {
        let (t, _) = terminal("one two one\r\nnone\r\n")
        let m = try find("one", in: t)
        #expect(m.map(\.segments) == [[.init(row: 0, columns: 0..<3)], [.init(row: 0, columns: 8..<11)],
                                      [.init(row: 1, columns: 1..<4)]])
        #expect(try find("one", in: t, wholeWord: true).count == 2)
        #expect(try find("ONE", in: t, caseSensitive: true).isEmpty)
        #expect(try find("o.e", in: t, regex: true).count == 3)
    }

    @Test func matchOnWrappedLineHasOneSegmentPerRow() throws {
        // 20 columns: "needle" starts at column 17 and wraps onto the next row.
        let (t, _) = terminal(String(repeating: "x", count: 17) + "needle\r\n")
        let m = try find("needle", in: t)
        #expect(m.count == 1)
        #expect(m[0].segments == [.init(row: 0, columns: 17..<20), .init(row: 1, columns: 0..<3)])
        #expect(m[0].rows == 0...1)
    }

    @Test func wideCharactersTakeTwoCells() throws {
        let (t, _) = terminal("日本 abc\r\n")
        let m = try find("abc", in: t)
        #expect(m.map(\.segments) == [[.init(row: 0, columns: 5..<8)]])
        #expect(try find("本", in: t).map(\.segments) == [[.init(row: 0, columns: 2..<4)]])
    }

    @Test func paddingIsNotText() throws {
        let (t, _) = terminal("a b\r\n")
        #expect(try find(" ", in: t).count == 1)
        #expect(try find("b$", in: t, regex: true).count == 1)
    }

    @Test func rowsStayValidWhenScrollbackIsTrimmed() throws {
        var out = ""
        for i in 0..<300 { out += "line \(i)\r\n" }
        let (t, _) = terminal(out + "needle\r\n")
        let trimmed = t.buffer.totalLinesTrimmed
        #expect(trimmed > 0)
        let m = try find("needle", in: t)
        #expect(m.count == 1)
        #expect(t.getScrollInvariantLine(row: m[0].row)?.translateToString(trimRight: true) == "needle")
    }

    @Test func limitStopsTheScan() throws {
        let (t, _) = terminal(String(repeating: "ab ", count: 6) + "\r\n")
        #expect(BufferSearch.matches(in: t, regex: try BufferSearch.regex("ab", isRegex: false, caseSensitive: false, wholeWord: false), limit: 4).count == 4)
    }

    @Test func styleDecodesTolerantly() throws {
        let style = try JSONDecoder().decode(FindHighlightStyle.self, from: Data(#"{"matchColor":"green","jumpEffect":"nope"}"#.utf8))
        #expect(style.matchColor == .green)
        #expect(style.jumpEffect == FindHighlightStyle().jumpEffect)
        #expect(style.highlightLine)
    }

    /// A look from a row on finds what a whole look finds there, also for a line that wraps across
    /// that row (it is read from its start).
    @Test func aLookFromARowFindsTheSameAsAWholeLook() throws {
        let long = String(repeating: "y", count: 15) + "needle" + String(repeating: "z", count: 30)
        let (t, _) = terminal("needle 1\r\nfoo\r\n" + long + "\r\nneedle 2\r\nneedle 3\r\n", cols: 20, rows: 10)
        let regex = try BufferSearch.regex("needle", isRegex: false, caseSensitive: false, wholeWord: false)
        let all = BufferSearch.matches(in: t, regex: regex)
        #expect(all.count == 4)
        // Row 3 is the long line's second row: its match starts on row 2.
        #expect(BufferSearch.lineStart(in: t, row: 3) == 2)
        let rest = BufferSearch.matches(in: t, regex: regex, from: 3)
        #expect(rest == Array(all.dropFirst()))
        #expect(BufferSearch.matches(in: t, regex: regex, limit: 2, from: 3).count == 2)
        #expect(BufferSearch.lineText(in: t, row: 2).hasPrefix(long))
    }

    /// Blank cells at the end of a line are not text; inside a wrapped line they are.
    @Test func blanksEndALineButNotAWrappedRow() throws {
        let (t, _) = terminal("ab\r\n" + String(repeating: "c", count: 18) + "  dd\r\n", cols: 20)
        #expect(try find("b ", in: t).isEmpty)
        #expect(try find("c  d", in: t).count == 1)
    }
}
