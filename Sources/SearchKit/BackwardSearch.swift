import Foundation
import TerminalText
import RecordingKit

/// A line of a recording that matched, found looking back from its end.
public struct FoundLine: Sendable, Equatable {
    public var text: String
    /// Matched ranges within `text` (UTF-16 offsets).
    public var ranges: [NSRange]
    /// Where its first row was made: the output first reached it there (its text was written
    /// there or after).
    public var start: Int
    /// The end of the piece of output that finished it (it left the screen, or the output ended):
    /// its text is final there.
    public var end: Int
}

extension SearchEngine {
    /// Output looked at at a time, from the end of a recording back to its start.
    public static let backwardSegment = 2 << 20
    /// The first segments are smaller (each twice the one before, up to `segment`), so what is
    /// found nearest the end, and how far the search is, shows at once in a long recording.
    static let backwardFirstSegment = 128 << 10
    /// Bytes read from the recording at a time (ending where asked, reaching back).
    static let readBlock = 16 << 20
    /// Output after a segment laid out with it, so a line it made but a program finished drawing
    /// a little later (a progress line, redrawn) is seen as it was shown; and before it, so what a
    /// program redraws there lands where it did (not on a fresh screen's rows). Each line is the
    /// segment's whose output made its first row.
    static let segmentFollow = 64 << 10

    /// Finds `regex` in a recording from its end back to its start: the newest matches first, a
    /// segment at a time (`found` gets each segment's, oldest first, and returns false to stop).
    /// Each segment is laid out as the terminal showed it on its own — only the pieces that can
    /// hold a match (`Prefilter`), with what led up to them.
    ///
    /// The end of the recording is also in memory: its last `memoryLines` lines, whose first are
    /// `memoryHead`, are left out (`HistorySeam`). `read(from, to)` gives the recording's bytes,
    /// `length` how many there are.
    ///
    /// An encrypted recording reads as nothing while Tether is locked, and a part encrypted with
    /// another key as nothing (the bytes after it would be at other positions): output that does
    /// not read whole is not looked through — the search stops where nothing can be read, and goes
    /// on past a part that cannot. Returns false when some output was not looked through so.
    @discardableResult
    public static func findBackward(read: @escaping (Int, Int) -> Data, length: Int, regex: NSRegularExpression,
                                    memoryLines: Int, memoryHead: [String], limit: Int = .max,
                                    segment: Int = backwardSegment,
                                    progress: ((Double) -> Void)? = nil,
                                    found: ([FoundLine]) -> Bool) throws -> Bool {
        guard length > 0 else { return true }
        var complete = true
        // Read a block at a time going back (older parts of a recording are compressed: reading
        // a little of one decompresses it from its start).
        var cache: (start: Int, data: Data)?
        let read: (Int, Int) -> Data = { from, to in
            if let c = cache, from >= c.start, to <= c.start + c.data.count {
                return c.data.subdata(in: (c.data.startIndex + from - c.start)..<(c.data.startIndex + to - c.start))
            }
            let start = max(min(from, to - Self.readBlock), 0)
            let data = read(start, to)
            cache = (start, data)
            let lo = min(max(from - start, 0), data.count), hi = min(max(to - start, lo), data.count)
            return data.subdata(in: (data.startIndex + lo)..<(data.startIndex + hi))
        }
        var end = length
        var first = true
        var count = 0
        // The terminal's size where the segment after the current one starts (none known yet).
        var size: (cols: Int, rows: Int)?
        let full = max(segment, 1)
        var segment = min(Self.backwardFirstSegment, full)
        while end > 0, count < limit {
            try Task.checkCancellation()
            // The last segment holds what memory holds and more, laid out in full (to find where
            // memory starts in it); the others about `segment` bytes, from the start of a line.
            let hold = first ? memoryLines * 2 + HistorySeam.margin : segment
            let span = first ? min(RecordingReader.tailMaxBytes, full) : segment
            let probe = read(max(end - span, 0), end)
            if probe.count < end - max(end - span, 0) {
                complete = false
                // Nothing reads (locked): nothing further back will either.
                if probe.isEmpty { return false }
                end = max(end - span, 0)
                first = false
                continue
            }
            var (start, data) = RecordingReader.lines(endingAt: end, count: hold, maxBytes: first ? RecordingReader.tailMaxBytes : segment, read: read)
            if start >= end {
                // No line break in the whole segment: its bytes as they are.
                start = max(end - segment, 0)
                data = read(start, end)
            }
            let follow = first ? Data() : read(end, min(end + segmentFollow, length))
            let lead = start > 0 ? RecordingReader.lines(endingAt: start, count: segmentFollow, maxBytes: segmentFollow, read: read) : (start: start, data: Data())
            let bytes = lead.data + data + follow
            let markers = Self.sizeMarkers(in: bytes)
            // Laid out at the size the recording says there (the first marker in it, else the one
            // the segment after started with).
            let cols = markers.first?.cols ?? size?.cols ?? ScreenText.defaultCols
            let rows = markers.first?.rows ?? size?.rows ?? ScreenText.defaultRows
            size = (cols, rows)
            let quick = first ? nil : Prefilter(regex: regex, before: .max)
            let layout = LineLayout(start: lead.start, cols: cols, rows: rows, startsInAlternate: Self.startsInAlternateScreen(bytes),
                                    quick: quick)
            var lines: [(text: String, start: Int, end: Int)] = []
            let collect: (String, Int, Int) throws -> Bool = { line, offset, made in
                // Lines made in the output after the segment are the next one's (looked at before),
                // those made before it the one before's.
                guard made < end else { return false }
                if made >= start { lines.append((line, made, offset)) }
                return true
            }
            try layout.take(bytes, collect)
            try layout.finish(collect)
            if first {
                let drop = HistorySeam.overlap(tail: lines.map(\.text), memoryHead: memoryHead, expected: memoryLines)
                lines.removeLast(min(drop, lines.count))
            }
            var matches: [FoundLine] = []
            for line in lines {
                let ns = line.text as NSString
                let ranges = regex.matches(in: line.text, range: NSRange(location: 0, length: ns.length)).map(\.range).filter { $0.length > 0 }
                if !ranges.isEmpty { matches.append(FoundLine(text: line.text, ranges: ranges, start: line.start, end: line.end)) }
            }
            // The newest kept when there are more than `limit`.
            if count + matches.count > limit { matches.removeFirst(count + matches.count - limit) }
            count += matches.count
            progress?(Double(length - start) / Double(length))
            if !matches.isEmpty, !found(matches) { return complete }
            end = start
            if !first { segment = min(segment * 2, full) }
            first = false
        }
        return complete
    }

    /// The sizes the recording's markers in `bytes` give (`SizeMarker`), in order.
    static func sizeMarkers(in bytes: Data) -> [(cols: Int, rows: Int)] {
        var out: [(cols: Int, rows: Int)] = []
        var rest = Array(bytes)[...]
        while let (range, size) = SizeMarker.find(in: rest) {
            out.append(size)
            rest = rest[range.upperBound...]
        }
        return out
    }

    /// Whether `bytes` start on a full-screen program's screen: the first switch in them leaves it.
    static func startsInAlternateScreen(_ bytes: Data) -> Bool {
        let leave = [Array("\u{1b}[?1049l".utf8), Array("\u{1b}[?1047l".utf8), Array("\u{1b}[?47l".utf8)]
        let enter = [Array("\u{1b}[?1049h".utf8), Array("\u{1b}[?1047h".utf8), Array("\u{1b}[?47h".utf8)]
        let b = Array(bytes)
        var i = 0
        while let esc = b[i...].firstIndex(of: 0x1b) {
            let rest = b[esc...]
            if enter.contains(where: { rest.starts(with: $0) }) { return false }
            if leave.contains(where: { rest.starts(with: $0) }) { return true }
            i = esc + 1
        }
        return false
    }
}
