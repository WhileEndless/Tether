import Foundation
import SwiftTerm

/// One match in a terminal buffer, as the cells it covers. A match on a wrapped line can run
/// over several rows: it has one segment per row.
public struct BufferMatch: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        /// Scroll-invariant row (stays valid when old scrollback lines are trimmed).
        public var row: Int
        public var columns: Range<Int>
        public init(row: Int, columns: Range<Int>) {
            self.row = row
            self.columns = columns
        }
    }

    public var segments: [Segment]
    public init(segments: [Segment]) { self.segments = segments }

    /// First row of the match.
    public var row: Int { segments.first?.row ?? 0 }
    public var column: Int { segments.first?.columns.lowerBound ?? 0 }
    /// Every row the match touches.
    public var rows: ClosedRange<Int> { row...(segments.last?.row ?? row) }
}

/// Finds text in a terminal's scrollback and screen by cell position, so matches can be drawn
/// where the terminal shows them (wide characters take two cells, wrapped rows are joined into
/// the lines the program wrote before matching).
public enum BufferSearch {
    /// Builds the matcher for a pattern (the same rules as the search window).
    public static func regex(_ pattern: String, isRegex: Bool, caseSensitive: Bool, wholeWord: Bool) throws -> NSRegularExpression {
        var p = isRegex ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        if wholeWord { p = "\\b(?:\(p))\\b" }
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: p, options: options)
    }

    /// All matches in the terminal's current buffer, top to bottom, at most `limit`. `from`: only
    /// lines from the one holding that scroll-invariant row on (the rows before did not change
    /// since the last look, see `TerminalFindSession`).
    public static func matches(in terminal: Terminal, regex: NSRegularExpression, limit: Int = 10_000,
                               from: Int? = nil) -> [BufferMatch] {
        var results: [BufferMatch] = []
        guard limit > 0 else { return results }
        var text = ""
        /// For each UTF-16 unit of `text`: the row and column range of its cell.
        var cells: [(row: Int, columns: Range<Int>)] = []
        let cols = terminal.cols

        func flush() {
            defer { text = ""; cells.removeAll(keepingCapacity: true) }
            guard !text.isEmpty, results.count < limit else { return }
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
                results.append(match(cells[m.range.location..<(m.range.location + m.range.length)]))
                if results.count >= limit { return }
            }
        }

        var row = lineStart(in: terminal, row: max(from ?? 0, terminal.buffer.totalLinesTrimmed))
        var line = terminal.getScrollInvariantLine(row: row)
        while let current = line {
            if !current.isWrapped { flush() }
            if results.count >= limit { break }
            let next = terminal.getScrollInvariantLine(row: row + 1)
            // Blank cells at the end of a line are padding, not output (inside a wrapped line they
            // are text): they are not read at all.
            var end = min(current.count, cols)
            if next?.isWrapped != true {
                while end > 0 {
                    let ch = terminal.getCharacter(for: current[end - 1])
                    if ch != " " && ch != "\0" { break }
                    end -= 1
                }
            }
            for col in 0..<end {
                let cell = current[col]
                if cell.width == 0 { continue }        // second half of a wide character
                var ch = terminal.getCharacter(for: cell)
                if ch == "\0" { ch = " " }
                text.append(ch)
                let span = col..<(col + max(Int(cell.width), 1))
                for _ in 0..<ch.utf16.count { cells.append((row, span)) }
            }
            row += 1
            line = next
        }
        flush()
        return results
    }

    /// The text of the line (wrapped rows joined) that starts at `row`, as `matches` reads it.
    public static func lineText(in terminal: Terminal, row: Int) -> String {
        var text = ""
        var r = row
        while let line = terminal.getScrollInvariantLine(row: r), r == row || line.isWrapped {
            for col in 0..<min(line.count, terminal.cols) where line[col].width != 0 {
                let ch = terminal.getCharacter(for: line[col])
                text.append(ch == "\0" ? " " : ch)
            }
            r += 1
        }
        return text
    }

    /// The first row of the line (as the program wrote it, before wrapping) holding `row`.
    public static func lineStart(in terminal: Terminal, row: Int) -> Int {
        var r = row
        let first = terminal.buffer.totalLinesTrimmed
        while r > first, terminal.getScrollInvariantLine(row: r)?.isWrapped == true { r -= 1 }
        return r
    }

    private static func match(_ cells: ArraySlice<(row: Int, columns: Range<Int>)>) -> BufferMatch {
        var segments: [BufferMatch.Segment] = []
        for c in cells {
            if let last = segments.last, last.row == c.row {
                segments[segments.count - 1].columns = last.columns.lowerBound..<max(last.columns.upperBound, c.columns.upperBound)
            } else {
                segments.append(.init(row: c.row, columns: c.columns))
            }
        }
        return BufferMatch(segments: segments)
    }
}
