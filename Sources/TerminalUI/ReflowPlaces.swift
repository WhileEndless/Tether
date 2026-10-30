import AppKit
import SwiftTerm

/// Places in a terminal's buffer that must stay on the same text when a new width makes long lines
/// wrap differently (the rows below them move up or down): taken as lines the program wrote,
/// counted back from the cursor's, and how far into such a line — then turned back into rows.
struct ReflowPlaces {
    private struct Place { var fromCursor: Int; var column: Int }
    private let places: [Place?]
    private let cols: Int
    /// Where each line started before.
    private let startsBefore: [Int]

    /// `rows`: buffer rows (0 is the oldest row in memory).
    init(_ view: TerminalView, rows: [Int]) {
        let starts = Self.lineStarts(view)
        startsBefore = starts
        let cursor = Self.line(of: Self.cursorRow(view), starts: starts) ?? 0
        cols = view.getTerminal().cols
        places = rows.map { row in
            guard row >= 0, let i = Self.line(of: row, starts: starts) else { return nil }
            return Place(fromCursor: cursor - i, column: (row - starts[i]) * view.getTerminal().cols)
        }
    }

    /// The rows the places are at now (nil: that text is no longer in the buffer).
    func rows(in view: TerminalView) -> [Int?] {
        let starts = Self.lineStarts(view)
        let cursor = Self.line(of: Self.cursorRow(view), starts: starts) ?? 0
        let newCols = max(view.getTerminal().cols, 1)
        let total = Self.rowCount(view)
        return places.map { place in
            guard let place else { return nil }
            let i = cursor - place.fromCursor
            guard starts.indices.contains(i) else { return nil }
            let lineRows = (i + 1 < starts.count ? starts[i + 1] : total) - starts[i]
            return starts[i] + min(place.column / newCols, max(lineRows - 1, 0))
        }
    }

    /// Rows (of the width before) whose lines are no longer in the buffer: a narrower width needs
    /// more rows than the scrollback holds, and SwiftTerm drops the oldest without counting them
    /// as trimmed.
    func droppedRows(in view: TerminalView) -> Int {
        let lost = startsBefore.count - Self.lineStarts(view).count
        guard lost > 0 else { return 0 }
        return lost < startsBefore.count ? startsBefore[lost] : Self.rowCount(view)
    }

    /// Where each line the program wrote starts (wrapped rows continue the line above).
    private static func lineStarts(_ view: TerminalView) -> [Int] {
        let t = view.getTerminal()
        let base = t.buffer.totalLinesTrimmed
        var starts: [Int] = []
        var r = 0
        while let line = t.getScrollInvariantLine(row: base + r) {
            if r == 0 || !line.isWrapped { starts.append(r) }
            r += 1
        }
        return starts
    }

    private static func rowCount(_ view: TerminalView) -> Int {
        let t = view.getTerminal()
        var lo = t.buffer.totalLinesTrimmed, hi = lo + 4_000_000
        while lo < hi {
            let mid = (lo + hi) / 2
            if t.getScrollInvariantLine(row: mid) != nil { lo = mid + 1 } else { hi = mid }
        }
        return lo - t.buffer.totalLinesTrimmed
    }

    private static func cursorRow(_ view: TerminalView) -> Int {
        let t = view.getTerminal()
        return rowCount(view) - t.rows + t.getCursorLocation().y
    }

    /// The line holding `row`.
    private static func line(of row: Int, starts: [Int]) -> Int? {
        var lo = 0, hi = starts.count - 1
        guard hi >= 0, row >= starts[0] else { return nil }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= row { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
