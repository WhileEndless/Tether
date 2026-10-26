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

    /// All matches in the terminal's current buffer, top to bottom, at most `limit`.
    public static func matches(in terminal: Terminal, regex: NSRegularExpression, limit: Int = 10_000) -> [BufferMatch] {
        var results: [BufferMatch] = []
        var text = ""
        /// For each UTF-16 unit of `text`: the row and column range of its cell.
        var cells: [(row: Int, columns: Range<Int>)] = []

        func flush() {
            // Trailing blank cells are padding, not output.
            while text.last == " " {
                let ch = text.removeLast()
                cells.removeLast(ch.utf16.count)
            }
            defer { text = ""; cells.removeAll(keepingCapacity: true) }
            guard !text.isEmpty, results.count < limit else { return }
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
                results.append(match(cells[m.range.location..<(m.range.location + m.range.length)]))
                if results.count >= limit { return }
            }
        }

        var row = terminal.buffer.totalLinesTrimmed
        while let line = terminal.getScrollInvariantLine(row: row) {
            if !line.isWrapped { flush() }
            for col in 0..<min(line.count, terminal.cols) {
                let cell = line[col]
                if cell.width == 0 { continue }        // second half of a wide character
                var ch = terminal.getCharacter(for: cell)
                if ch == "\0" { ch = " " }
                text.append(ch)
                let span = col..<(col + max(Int(cell.width), 1))
                for _ in 0..<ch.utf16.count { cells.append((row, span)) }
            }
            row += 1
        }
        flush()
        return results
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
