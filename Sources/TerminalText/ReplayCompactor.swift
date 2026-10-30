import Foundation
import SwiftTerm

/// Turns a stretch of recorded output into the lines it left — with their colours and styles — as
/// a short stream that draws exactly those rows, and says on which row each position of interest
/// (a command, the line kept in view, the live terminal's first line) ended up.
///
/// A coding agent redraws its status many times a second; its recording is mostly those redraws.
/// Replaying it as it came costs the terminal a second or more per few megabytes, on the main
/// thread. This does that work on a terminal of its own, off the main thread, so the history view
/// only has to draw the result. Links and images in the output are not kept (text, colours and
/// styles are).
public enum ReplayCompactor {
    public struct Result: Sendable {
        /// What draws the rows (from the top left of an empty terminal of the same size).
        public var bytes: [UInt8]
        /// For each position asked about: the row (0 = the first row drawn) it is on, or the first
        /// row after the full-screen program it was in; positions whose rows went are left out.
        public var rows: [Int: Int]
        /// Rows drawn.
        public var rowCount: Int
        /// Positions asked about whose rows went from the top (more rows than the scrollback
        /// holds), not cleared away.
        public var trimmedAway: Set<Int> = []
        /// For each position asked about that was on the normal screen: the cursor's column there
        /// (0 where nothing was before it on its row: no prompt, nothing typed).
        public var columns: [Int: Int] = [:]
    }

    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    /// `cuts`: positions (as `data` is placed at `start`) whose rows are wanted; `scrollback`: the
    /// rows the history view keeps above its screen; `knowsTyping`: the recording notes where the
    /// user typed (command marks), also when `data` starts after the last one.
    public static func compact(_ data: [UInt8], start: Int, cuts: [Int], cols: Int, rows screenRows: Int,
                               scrollback: Int, startsInAlternate: Bool, programsMayClear: Bool,
                               keepRedraws: Bool = false, knowsTyping: Bool = false) -> Result {
        let data = ImageSequenceFilter.filtered(data)   // the same length: `cuts` still match
        let sink = Sink()
        var options = TerminalOptions.default
        options.cols = max(cols, 2)
        options.rows = max(screenRows, 1)
        options.scrollback = max(scrollback, 0)
        let t = Terminal(delegate: sink, options: options)
        t.registerOscHandler(code: 7771) { _ in }
        var found: [Int: Int] = [start: 0]
        var columns: [Int: Int] = [:]
        var context = ScrollbackRule.Context(keepRedraws: keepRedraws, knowsTyping: knowsTyping, readsMarkers: true)
        func feed(_ bytes: ArraySlice<UInt8>) {
            ScrollbackRule.feed(bytes, terminal: t, programsMayClear: programsMayClear, context: &context) { piece in
                let before = t.buffer.totalLinesTrimmed
                let lines = lineCount()
                let wasAlternate = t.isCurrentBufferAlternate
                t.feed(buffer: piece)
                // The scrollback was cleared (ESC[3J, a reset): rows noted so far are gone. (A
                // full-screen program's screen has rows of its own: going to or from it is not that.)
                if !wasAlternate, !t.isCurrentBufferAlternate,
                   t.buffer.totalLinesTrimmed < before || lineCount() < lines - t.rows { found.removeAll() }
            }
        }
        func lineCount() -> Int {
            var lo = t.buffer.totalLinesTrimmed, hi = lo + 4_000_000
            while lo < hi {
                let mid = (lo + hi) / 2
                if t.getScrollInvariantLine(row: mid) != nil { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
        func cursorRow() -> Int { lineCount() - t.rows + t.getCursorLocation().y }

        if startsInAlternate { t.feed(text: "\u{1b}[?1049h") }
        let sorted = Set(cuts).filter { $0 > start && $0 < start + data.count }.sorted()
        var from = 0
        var waiting: [Int] = []
        func feedPiece(to: Int) {
            var begin = from
            if !waiting.isEmpty {
                for leave in leaveSequences(in: data, from: from, to: to) {
                    feed(data[begin..<leave])
                    begin = leave
                    if !t.isCurrentBufferAlternate {
                        for w in waiting { found[w] = cursorRow() }
                        waiting = []
                        break
                    }
                }
            }
            feed(data[begin..<to])
            from = to
        }
        for cut in sorted {
            feedPiece(to: cut - start)
            if t.isCurrentBufferAlternate {
                waiting.append(cut)
            } else {
                for w in waiting { found[w] = cursorRow() }
                waiting = []
                found[cut] = cursorRow()
                columns[cut] = t.getCursorLocation().x
            }
        }
        feedPiece(to: data.count)
        if t.isCurrentBufferAlternate { t.feed(text: "\u{1b}[?1049l\u{1b}[?1047l\u{1b}[?47l") }
        for w in waiting { found[w] = cursorRow() }

        let first = t.buffer.totalLinesTrimmed
        // Down to the cursor, and to what a program keeps below it (an agent's footer).
        var lastUsed = lineCount() - 1
        while lastUsed > cursorRow(), let line = t.getScrollInvariantLine(row: lastUsed),
              line.translateToString(trimRight: true).allSatisfy({ $0 == " " }) { lastUsed -= 1 }
        let last = max(cursorRow(), lastUsed, first)
        var rows: [Int: Int] = [:]
        for (k, r) in found where r >= first { rows[k] = r - first }
        return Result(bytes: draw(t, from: first, through: last), rows: rows, rowCount: last - first + 1,
                      trimmedAway: Set(found.filter { $0.value < first }.keys), columns: columns.filter { rows[$0.key] != nil })
    }

    /// The rows `from…through` (scroll-invariant) as text and SGR sequences.
    static func draw(_ t: Terminal, from: Int, through: Int) -> [UInt8] {
        var out = ""
        out.reserveCapacity((through - from + 1) * (t.cols + 16))
        var current = Attribute.empty
        // A cell nothing was written to, or one erased with the default colours, shows nothing.
        let blankBackground: (Attribute) -> Bool = { a in
            (a.bg == .defaultInvertedColor || a.bg == .defaultColor) && !a.style.contains(.inverse) && a.underlineStyle == .none
                && !a.style.contains(.underline)
        }
        var row = from
        while row <= through, let line = t.getScrollInvariantLine(row: row) {
            let next = row < through ? t.getScrollInvariantLine(row: row + 1) : nil
            let continues = next?.isWrapped == true
            let width = min(line.count, t.cols)
            // A row the next one continues is drawn in full (so the terminal wraps there too);
            // otherwise up to its last cell that shows something.
            var end = width
            if !continues {
                while end > 0 {
                    let cell = line[end - 1]
                    let ch = t.getCharacter(for: cell)
                    // Only cells nothing was written to: a space a program printed is kept (copying
                    // and finding see it, as in the terminal).
                    if ch != "\0" || !blankBackground(cell.attribute) || cell.width == 0 { break }
                    end -= 1
                }
            }
            for col in 0..<end {
                let cell = line[col]
                if cell.width == 0 { continue }
                if cell.attribute != current {
                    out += sgr(cell.attribute)
                    current = cell.attribute
                }
                let ch = t.getCharacter(for: cell)
                out.append(ch == "\0" ? " " : ch)
            }
            if row < through, !continues {
                if current != .empty { out += "\u{1b}[0m"; current = .empty }
                out += "\r\n"
            }
            row += 1
        }
        out += "\u{1b}[0m"
        return Array(out.utf8)
    }

    /// The SGR sequence that sets exactly `a` (from a reset).
    static func sgr(_ a: Attribute) -> String {
        var p = ["0"]
        let s = a.style
        if s.contains(.bold) { p.append("1") }
        if s.contains(.dim) { p.append("2") }
        if s.contains(.italic) { p.append("3") }
        if s.contains(.underline) || a.underlineStyle != .none {
            p.append(a.underlineStyle == .none || a.underlineStyle == .single ? "4" : "4:\(a.underlineStyle.rawValue)")
        }
        if s.contains(.blink) { p.append("5") }
        if s.contains(.inverse) { p.append("7") }
        if s.contains(.invisible) { p.append("8") }
        if s.contains(.crossedOut) { p.append("9") }
        func color(_ c: Attribute.Color, base: Int, extended: Int) -> String? {
            switch c {
            case .ansi256(let code) where code < 8: return "\(base + Int(code))"
            case .ansi256(let code) where code < 16: return "\(base + 60 + Int(code) - 8)"
            case .ansi256(let code): return "\(extended);5;\(code)"
            case .trueColor(let r, let g, let b): return "\(extended);2;\(r);\(g);\(b)"
            case .defaultColor, .defaultInvertedColor: return nil
            }
        }
        if let f = color(a.fg, base: 30, extended: 38) { p.append(f) }
        if let b = color(a.bg, base: 40, extended: 48) { p.append(b) }
        switch a.underlineColor {
        case .ansi256(let code)?: p.append("58;5;\(code)")
        case .trueColor(let r, let g, let b)?: p.append("58;2;\(r);\(g);\(b)")
        default: break
        }
        return "\u{1b}[" + p.joined(separator: ";") + "m"
    }

    /// Where a full-screen program's screen is left (after `ESC[?1049l` and the like) in `bytes[from..<to]`.
    static func leaveSequences(in bytes: [UInt8], from: Int, to: Int) -> [Int] {
        let leaves = ["\u{1b}[?1049l", "\u{1b}[?1047l", "\u{1b}[?47l"].map { Array($0.utf8) }
        var found: [Int] = []
        var i = from
        while i < to {
            if bytes[i] == 0x1b, let leave = leaves.first(where: { i + $0.count <= to && bytes[i..<(i + $0.count)].elementsEqual($0) }) {
                found.append(i + leave.count)
                i += leave.count
            } else {
                i += 1
            }
        }
        return found
    }
}
