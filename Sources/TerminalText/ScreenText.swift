import Foundation
import SwiftTerm

/// The text of terminal output as the terminal showed it, for search and plain-text export.
///
/// The output runs through a terminal emulator without a view (`ScrollbackRule` applies, as on
/// screen), and a line is taken once it has scrolled up off the screen — from then on nothing can
/// change it — or, at the end, from what is left on the screen. So:
/// - cursor movement, erasing and in-place updates (progress bars, spinners, prompts) give the
///   line as it was finally shown, once;
/// - full-screen programs on the alternate screen (vim, less, htop) add nothing; the output before
///   and after them is kept;
/// - a program that clears everything and prints its whole screen again (Claude Code redrawing,
///   `clear` and the same output) does not repeat lines already taken: a run of at least
///   `repeatRun` lines that repeats earlier lines in order right after a clear is skipped;
/// - wrapped rows are joined back into the lines the program wrote.
///
/// Recordings say the terminal's size with `SizeMarker` (written when it changes); without one the
/// text is laid out 200 columns wide.
public final class ScreenText {
    public static let defaultCols = 200
    public static let defaultRows = 50
    /// Lines repeated after a clear are dropped only in runs at least this long, so a short line
    /// printed again after a clear (`ls` twice) is kept.
    public static let repeatRun = 4
    /// How far back a repeat is looked for (lines).
    static let window = 20_000
    /// Lines at the end of a redraw that may differ from what was there (a status or input line).
    static let redrawSlack = 5

    private let terminal: Terminal
    private let delegate = Sink()
    /// Next row (scroll-invariant) not taken yet.
    private var next = 0
    /// Rows in the buffer at the last count (to count quickly).
    private var known = 0
    /// A logical line still growing (its next row may be a wrapped continuation).
    private var open: String?
    /// Bytes held back until the next line break, so no escape sequence or marker is cut in two.
    private var carry: [UInt8] = []

    // Repeats after a clear.
    private var recent: [String] = []
    private var recentIndex: [String: [Int]] = [:]
    private var dropped = 0          // lines removed from the front of `recent`
    private var afterClear = false
    /// A run that may repeat earlier lines: where it could continue in `recent`, and its lines so far.
    private var candidate: (positions: [Int], held: [String])?
    /// The terminal was resized while a full-screen program was up: where the normal screen's
    /// output continues is found again when the program ends.
    private var resizedInAlternate = false

    public init(cols: Int = ScreenText.defaultCols, rows: Int = ScreenText.defaultRows) {
        var options = TerminalOptions.default
        options.cols = cols
        options.rows = rows
        options.scrollback = 4_000
        terminal = Terminal(delegate: delegate, options: options)
        known = terminal.rows
    }

    /// Feeds output; returns the lines finished by it.
    public func feed(_ bytes: some Sequence<UInt8>) -> [String] {
        carry.append(contentsOf: bytes)
        // Up to the last line break (or everything, past 1 MB without one).
        guard let cut = carry.lastIndex(of: 0x0a).map({ $0 + 1 }) ?? (carry.count > 1 << 20 ? carry.count : nil) else { return [] }
        let ready = carry[0..<cut]
        defer { carry.removeFirst(cut) }
        return process(ready)
    }

    /// The rest: what is still on the screen (without trailing empty lines).
    public func finish() -> [String] {
        var out = carry.isEmpty ? [] : process(carry[...])
        carry.removeAll()
        // A full-screen program still up: the normal screen's rows were taken when it started.
        if !terminal.isCurrentBufferAlternate { out += takeScreen() }
        if let open { out += accept(open) }
        open = nil
        out += flushCandidate()
        while out.last?.isEmpty == true { out.removeLast() }
        return out
    }

    /// Converts a whole buffer at once.
    public static func lines(from data: some Sequence<UInt8>, cols: Int = defaultCols) -> [String] {
        let s = ScreenText(cols: cols)
        return s.feed(data) + s.finish()
    }

    // MARK: Feeding

    private func process(_ bytes: ArraySlice<UInt8>) -> [String] {
        var out: [String] = []
        var rest = bytes
        // Size markers resize the terminal where they stand.
        while let (range, size) = SizeMarker.find(in: rest) {
            out += run(rest[rest.startIndex..<range.lowerBound])
            out += resize(cols: size.cols, rows: size.rows)
            rest = rest[range.upperBound...]
        }
        out += run(rest)
        return out
    }

    /// Feeds in slices small enough that no row leaves the scrollback before it is taken.
    private func run(_ bytes: ArraySlice<UInt8>) -> [String] {
        var out: [String] = []
        var start = bytes.startIndex
        while start < bytes.endIndex {
            var end = start
            var breaks = 0
            while end < bytes.endIndex, end - start < 32_768, breaks < 500 {
                if bytes[end] == 0x0a { breaks += 1 }
                end += 1
            }
            // Never between the bytes of an escape sequence (a clear cut in two would be missed).
            if end < bytes.endIndex, let esc = bytes[max(start, end - 16)..<end].lastIndex(of: 0x1b), esc > start { end = esc }
            out += feedSlice(bytes[start..<end])
            start = end
        }
        return out
    }

    /// Feeds one slice under `ScrollbackRule`. At a clear, the lines it moves into the scrollback are
    /// taken first (they are new), and only what is printed after it is checked for repeats.
    private func feedSlice(_ bytes: ArraySlice<UInt8>) -> [String] {
        let t = terminal
        var out: [String] = []
        var rest = bytes
        while let (range, code) = Self.nextEvent(in: rest) {
            t.feed(buffer: rest[rest.startIndex..<range.lowerBound])
            if code == Self.alternateEnter {
                // The normal screen stays as it is behind the program: what is above the cursor is
                // taken now, the rest once the program ends.
                if !t.isCurrentBufferAlternate { out += take() + takeAboveCursor() }
                t.feed(buffer: rest[range])
                rest = rest[range.upperBound...]
                continue
            }
            if code == Self.alternateExit {
                t.feed(buffer: rest[range])
                rest = rest[range.upperBound...]
                // Resized meanwhile: the normal screen reflowed, so its rows are counted again from
                // the cursor (put back where it was when the program started).
                if resizedInAlternate, !t.isCurrentBufferAlternate {
                    resizedInAlternate = false
                    known = ScrollbackRule.lineCount(t)
                    next = max(cursorRow, t.buffer.totalLinesTrimmed)
                }
                continue
            }
            if ScrollbackRule.keepsScreen(code, terminal: t) {
                ScrollbackRule.keepScreen(t) { t.feed(buffer: $0) }
                out += take()
                if let open { out += accept(open) }
                open = nil
                afterClear = true
            } else if code == UInt8(ascii: "3"), !t.isCurrentBufferAlternate {
                afterClear = true
            }
            ScrollbackRule.erase(code, rest[range], terminal: t, programsMayClear: false) { t.feed(buffer: $0) }
            rest = rest[range.upperBound...]
        }
        if !rest.isEmpty { t.feed(buffer: rest) }
        return out + take()
    }

    /// `ESC[?1049h`, `ESC[?1047h`, `ESC[?47h`: a full-screen program starts (`…l`: it ends).
    static let alternateEnter = UInt8(ascii: "a")
    static let alternateExit = UInt8(ascii: "e")

    /// The next clear (`ScrollbackRule.findErase`) or start of the alternate screen.
    static func nextEvent(in bytes: ArraySlice<UInt8>) -> (Range<Int>, UInt8)? {
        let erase = ScrollbackRule.findErase(in: bytes)
        var i = bytes.startIndex
        let end = erase?.0.lowerBound ?? bytes.endIndex
        while i + 3 < end, let esc = bytes[i..<end].firstIndex(of: 0x1b) {
            i = esc + 1
            guard esc + 2 < bytes.endIndex, bytes[esc + 1] == 0x5b, bytes[esc + 2] == 0x3f else { continue }   // ESC [ ?
            // Private modes, possibly several at once (`ESC[?1049;1006h`).
            var j = esc + 3
            var numbers: [Int] = [0]
            while j < bytes.endIndex, (0x30...0x39).contains(bytes[j]) || bytes[j] == 0x3b, numbers.count < 16 {
                if bytes[j] == 0x3b { numbers.append(0) } else if numbers[numbers.count - 1] < 100_000 {
                    numbers[numbers.count - 1] = numbers[numbers.count - 1] * 10 + Int(bytes[j] - 0x30)
                }
                j += 1
            }
            if j < bytes.endIndex, numbers.contains(where: { [1049, 1047, 47].contains($0) }) {
                if bytes[j] == 0x68 { return (esc..<(j + 1), alternateEnter) }
                if bytes[j] == 0x6c { return (esc..<(j + 1), alternateExit) }
            }
        }
        return erase
    }

    private func resize(cols: Int, rows: Int) -> [String] {
        guard cols != terminal.cols || rows != terminal.rows, cols > 0, rows > 0 else { return [] }
        if terminal.isCurrentBufferAlternate {
            // The normal screen reflows behind the program: its position is found again after it.
            terminal.resize(cols: cols, rows: rows)
            resizedInAlternate = true
            return []
        }
        // Rows above the cursor are taken as they are: reflowing would make their rows unreliable.
        // The cursor's row and what is below stay open (a prompt still being typed).
        var out = take() + takeAboveCursor()
        if let open { out += accept(open) }
        open = nil
        terminal.resize(cols: cols, rows: rows)
        known = ScrollbackRule.lineCount(terminal)
        next = cursorRow
        return out
    }

    /// The scroll-invariant row of the cursor.
    private var cursorRow: Int { ScrollbackRule.lineCount(terminal, from: known) - terminal.rows + terminal.buffer.y }

    /// The rows above the cursor not taken yet; marks them taken.
    private func takeAboveCursor() -> [String] {
        let cursor = cursorRow
        var out: [String] = []
        while next < cursor, let line = terminal.getScrollInvariantLine(row: next) {
            out += row(line)
            next += 1
        }
        return out
    }

    // MARK: Taking lines

    /// Rows that scrolled up off the screen since the last call.
    private func take() -> [String] {
        guard !terminal.isCurrentBufferAlternate else { return [] }
        if resizedInAlternate {
            // Back from a program during which the terminal was resized: above the cursor (where
            // it was when the program started) everything was taken.
            resizedInAlternate = false
            known = ScrollbackRule.lineCount(terminal)
            next = max(cursorRow, terminal.buffer.totalLinesTrimmed)
        }
        known = ScrollbackRule.lineCount(terminal, from: known)
        let base = terminal.buffer.totalLinesTrimmed
        if next < base { next = base }                  // never expected: rows lost to the scrollback limit
        let screenTop = known - terminal.rows
        var out: [String] = []
        while next < screenTop, let line = terminal.getScrollInvariantLine(row: next) {
            out += row(line)
            next += 1
        }
        return out
    }

    /// The rows on the screen, up to the last one in use; marks them taken.
    private func takeScreen() -> [String] {
        guard !terminal.isCurrentBufferAlternate else { return [] }
        known = ScrollbackRule.lineCount(terminal, from: known)
        var last = known - 1
        while last >= next, let line = terminal.getScrollInvariantLine(row: last), ScrollbackRule.isBlank(line) { last -= 1 }
        var out: [String] = []
        while next <= last, let line = terminal.getScrollInvariantLine(row: next) {
            out += row(line)
            next += 1
        }
        next = known
        return out
    }

    /// One row: continues the open line when it is a wrapped continuation, else closes it.
    private func row(_ line: BufferLine) -> [String] {
        // Untrimmed, so a wrapped line joins with the spaces it had at the edge; `accept` trims the
        // end. Wide characters (CJK, emoji) take two cells but are one character.
        let t = terminal
        var text = line.translateToString(trimRight: false, skipNullCellsFollowingWide: true) { t.getCharacter(for: $0) }
        if text.contains("\0") { text = text.replacingOccurrences(of: "\0", with: " ") }
        if line.isWrapped, let o = open {
            open = o + text
            return []
        }
        let closed = open.map(accept) ?? []
        open = text
        return closed
    }

    // MARK: Repeats after a clear

    /// A finished line: kept, unless it is part of a run that repeats earlier lines after a clear.
    private func accept(_ raw: String) -> [String] {
        var text = raw
        if text.last == " " {
            let bytes = text.utf8
            var end = bytes.endIndex
            while end > bytes.startIndex, bytes[bytes.index(before: end)] == 0x20 { end = bytes.index(before: end) }
            text = String(text[..<end])
        }
        if let c = candidate {
            let n = c.held.count
            let still = c.positions.filter { $0 + n - dropped < recent.count && $0 + n >= dropped && recent[$0 + n - dropped] == text }
            if !still.isEmpty {
                candidate = (still, c.held + [text])
                let c = candidate!
                if c.held.count >= Self.repeatRun { afterClear = false }   // a real repeat: keep skipping
                return []
            }
            // The run ended: dropped only when it was a redraw (see `isRedraw`), else kept.
            let out = isRedraw(c) ? [] : c.held
            candidate = nil
            return out.flatMap(remember) + start(text)
        }
        return start(text)
    }

    private func start(_ text: String) -> [String] {
        // Each place the line was seen (the most recent few) may be where the repeat starts: a
        // frame's common first line (a box border) is in many.
        if afterClear, !text.isEmpty, let positions = recentIndex[text]?.suffix(16), !positions.isEmpty {
            afterClear = false
            candidate = (Array(positions), [text])
            return []
        }
        if !text.isEmpty { afterClear = false }
        return remember(text)
    }

    private func flushCandidate() -> [String] {
        guard let c = candidate else { return [] }
        candidate = nil
        return isRedraw(c) ? [] : c.held.flatMap(remember)
    }

    /// A program redrawing everything after a clear prints again, in order, what was there up to
    /// that moment: a run of at least `repeatRun` lines that reaches (within `redrawSlack` lines,
    /// such as a status line that changed) the last line taken. The same command run again later
    /// repeats an older stretch and is kept.
    private func isRedraw(_ c: (positions: [Int], held: [String])) -> Bool {
        guard c.held.count >= Self.repeatRun else { return false }
        let end = dropped + recent.count
        return c.positions.contains { $0 + c.held.count >= end - Self.redrawSlack }
    }

    private func remember(_ text: String) -> [String] {
        recentIndex[text, default: []].append(dropped + recent.count)
        recent.append(text)
        if recent.count > Self.window * 2 {
            let gone = recent.count - Self.window
            recent.removeFirst(gone)
            dropped += gone
            recentIndex = recentIndex.compactMapValues { list in
                let kept = list.filter { $0 >= dropped }
                return kept.isEmpty ? nil : kept
            }
        }
        return [text]
    }

    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
}

/// The terminal's size, written into recordings when it changes so a replay or the text of the
/// recording can be laid out the same way: `ESC ] 7771 ; size=<cols>x<rows> BEL`. Terminals ignore
/// unknown OSC sequences, so it is invisible everywhere.
public enum SizeMarker {
    static let prefix = Array("\u{1b}]7771;size=".utf8)

    public static func bytes(cols: Int, rows: Int) -> [UInt8] {
        prefix + Array("\(cols)x\(rows)\u{07}".utf8)
    }

    /// The next marker in `bytes`, and the size it gives.
    public static func find(in bytes: ArraySlice<UInt8>) -> (Range<Int>, (cols: Int, rows: Int))? {
        var i = bytes.startIndex
        while let esc = bytes[i...].firstIndex(of: 0x1b) {
            if bytes[esc...].starts(with: prefix) {
                let body = esc + prefix.count
                guard let bell = bytes[body...].prefix(16).firstIndex(of: 0x07) else { i = body; continue }
                let parts = String(decoding: bytes[body..<bell], as: UTF8.self).split(separator: "x")
                if parts.count == 2, let c = Int(parts[0]), let r = Int(parts[1]) {
                    return (esc..<(bell + 1), (c, r))
                }
                i = bell + 1
                continue
            }
            i = esc + 1
        }
        return nil
    }

    /// The last size given in `bytes` (to start a replay or a slice the way the terminal was).
    public static func last(in bytes: ArraySlice<UInt8>) -> (cols: Int, rows: Int)? {
        var rest = bytes
        var found: (cols: Int, rows: Int)?
        while let (range, size) = find(in: rest) {
            found = size
            rest = rest[range.upperBound...]
        }
        return found
    }
}
