import Foundation
import SwiftTerm

/// How output treats the scrollback, the same for the terminal on screen and for text made from a
/// recording (`ScreenText`), so search and export show what the terminal kept:
///
/// - Clearing the screen (Ctrl+L, `clear`) first moves the visible lines into the scrollback, as
///   Terminal.app does. A clear is `ESC[2J`, or — as shells inside tmux and screen send it — `ESC[J`
///   right after `ESC[H` (the cursor sent to the top left). A program that moved up to redraw what
///   it drew (a build's progress, a package manager) and so reached the top is not clearing: its
///   frames are not kept, only what it leaves.
/// - `ESC[3J` (erase the scrollback, sent by `clear` and by programs that redraw everything) is
///   ignored unless `programsMayClear` is set (Settings ▸ Terminal).
/// - Full-screen programs on the alternate screen are left alone.
public enum ScrollbackRule {
    /// Feeds `bytes` to `terminal` through `feed` (a view's own feed, so it redraws), applying the rule.
    /// `cleared` is told after each clear of the normal screen.
    public static func feed(_ bytes: ArraySlice<UInt8>, terminal t: Terminal, programsMayClear: Bool = false,
                            cleared: (() -> Void)? = nil, feed: (ArraySlice<UInt8>) -> Void) {
        var context = Context(keepRedraws: true)
        self.feed(bytes, terminal: t, programsMayClear: programsMayClear, context: &context, cleared: cleared, feed: feed)
    }

    /// What the rule remembers between pieces of one terminal's output.
    public struct Context: Sendable {
        /// Every clear keeps the screen (also a program clearing again and again on its own).
        public var keepRedraws: Bool
        /// The end of what was fed before: a home sequence at the end of one piece and the erase at
        /// the start of the next are seen together.
        var tail: [UInt8] = []
        /// Clears that keep the screen, from the last typing on: one per Return or Ctrl+L typed at
        /// once (pasted `clear⏎ls⏎clear⏎` keeps both). The next clear is the user's (or the
        /// command's they started), and what is on screen goes to the scrollback. A program that
        /// clears again with nobody typing (a dashboard, `docker stats`, a progress screen) leaves
        /// only what it shows last. Typing sets it (commands run earlier without a clear do not add
        /// up); the first clear seen keeps the screen too (what came before it is not known).
        public var typedSinceClear = 1
        /// Whether typing is known at all: always for the terminal on screen (`typed()`); for output
        /// read back from a recording once its markers of commands (`ESC]7771;mark=`) or of Ctrl+L
        /// (`ESC]7771;typed`) appear — a recording without them clears as before.
        public var knowsTyping: Bool
        /// Markers are looked for in the output (a recording read back).
        let readsMarkers: Bool

        public init(keepRedraws: Bool, knowsTyping: Bool = false, readsMarkers: Bool = false) {
            self.keepRedraws = keepRedraws
            self.knowsTyping = knowsTyping
            self.readsMarkers = readsMarkers
        }

        /// The user typed Return or Ctrl+L in the terminal (or Tether is about to redraw the screen
        /// itself, which must not drop what is on it).
        public mutating func typed(_ count: Int = 1) { typedSinceClear = min(max(count, 1), 64) }
    }

    /// The same, for output that comes in pieces (see `Context`).
    public static func feed(_ bytes: ArraySlice<UInt8>, terminal t: Terminal, programsMayClear: Bool = false,
                            context: inout Context, cleared: (() -> Void)? = nil,
                            feed: (ArraySlice<UInt8>) -> Void) {
        defer {
            context.tail.append(contentsOf: bytes.suffix(Self.tailLength))
            if context.tail.count > Self.tailLength { context.tail.removeFirst(context.tail.count - Self.tailLength) }
        }
        var rest = bytes
        while let (range, code) = findErase(in: rest) {
            feed(rest[rest.startIndex..<range.lowerBound])
            let inPiece = rest[rest.startIndex..<range.lowerBound]
            if context.readsMarkers {
                let typed = typingMarkers(in: inPiece)
                if typed > 0 { context.knowsTyping = true; context.typed(typed) }
            }
            let before = range.lowerBound - bytes.startIndex < Self.tailLength ? (context.tail + bytes[bytes.startIndex..<range.lowerBound])[...] : inPiece
            var clears = keepsScreen(code, terminal: t, before: before, keepRedraws: context.keepRedraws)
            if clears, !context.keepRedraws, context.knowsTyping {
                // A clear with nobody typing since the last one: a program redrawing on its own.
                if context.typedSinceClear > 0 { context.typedSinceClear -= 1 } else { clears = false }
            }
            if clears { keepScreen(t, feed: feed) }
            erase(code, rest[range], terminal: t, programsMayClear: programsMayClear, feed: feed)
            if clears { cleared?() }
            rest = rest[range.upperBound...]
        }
        if !rest.isEmpty {
            feed(rest)
            if context.readsMarkers {
                let typed = typingMarkers(in: rest)
                if typed > 0 { context.knowsTyping = true; context.typed(typed) }
            }
        }
    }

    /// How many of Tether's markers of a command run (`ESC]7771;mark=`) or Ctrl+L typed
    /// (`ESC]7771;typed`) are in `bytes` — not its other markers (`size=`, written on resizes).
    /// Only the last of them typed at once count (markers right after one another: a paste's
    /// Returns), as typing sets what clears keep (`Context.typed`) — commands run before, with
    /// output between them, do not add up.
    static func typingMarkers(in bytes: ArraySlice<UInt8>) -> Int {
        var n = 0
        var i = bytes.startIndex
        var lastEnd = -1
        while let esc = bytes[i...].firstIndex(of: 0x1b) {
            if bytes[esc...].starts(with: commandMarkPrefix) || bytes[esc...].starts(with: typedMarker) {
                n = esc == lastEnd ? n + 1 : 1
                lastEnd = bytes[esc...].firstIndex(of: 0x07).map { $0 + 1 } ?? bytes.endIndex
                i = lastEnd
                continue
            }
            i = esc + 1
        }
        return n
    }
    private static let commandMarkPrefix = Array("\u{1b}]7771;mark=".utf8)
    /// Written into a recording when the user types Ctrl+L (Return writes a command's marker).
    public static let typedMarker = Array("\u{1b}]7771;typed\u{07}".utf8)

    /// Whether the erase `code` clears a normal screen whose lines must first go to the scrollback.
    /// `before`: what came just before the erase (an erase below the cursor counts only right after
    /// the cursor was sent home; at the very start of a piece, with nothing before it, the cursor's
    /// place alone decides).
    public static func keepsScreen(_ code: UInt8, terminal t: Terminal, before: ArraySlice<UInt8> = [],
                                   keepRedraws: Bool = false) -> Bool {
        guard !t.isCurrentBufferAlternate else { return false }
        switch code {
        case UInt8(ascii: "2"): return true
        case UInt8(ascii: "0"):
            let cursor = t.getCursorLocation()
            guard cursor.x == 0 && cursor.y == 0 else { return false }
            return keepRedraws || before.isEmpty || endsWithHome(before)
        default: return false
        }
    }

    /// How much of what came before is kept to look at (a home sequence and what may follow it).
    public static let tailLength = 64

    /// `ESC[H`, `ESC[;H`, `ESC[1;1H`, `ESC[1H`, `ESC[0;0H` (or with `f`) at the end of `bytes` —
    /// also with colours reset or the cursor hidden after it (`ESC[0m`, `ESC[?25l`), as some
    /// programs send before they erase.
    static func endsWithHome(_ bytes: ArraySlice<UInt8>) -> Bool {
        var end = bytes.endIndex
        while let start = harmlessSequence(endingAt: end, in: bytes) { end = start }
        return isHome(bytes[bytes.startIndex..<end])
    }

    /// Where an SGR (`ESC[…m`) or a mode switch (`ESC[?…h` / `l`) ending at `end` starts.
    private static func harmlessSequence(endingAt end: Int, in bytes: ArraySlice<UInt8>) -> Int? {
        guard end > bytes.startIndex else { return nil }
        let last = bytes[end - 1]
        guard last == 0x6d || last == 0x68 || last == 0x6c else { return nil }                // m, h, l
        var i = end - 1
        while i > bytes.startIndex {
            i -= 1
            let b = bytes[i]
            if b == 0x5b {
                guard i > bytes.startIndex, bytes[i - 1] == 0x1b else { return nil }
                let isMode = i + 1 < end && bytes[i + 1] == 0x3f
                return last == 0x6d || isMode ? i - 1 : nil
            }
            guard (0x30...0x39).contains(b) || b == 0x3b || b == 0x3f || b == 0x3a, end - i < 24 else { return nil }
        }
        return nil
    }

    private static func isHome(_ bytes: ArraySlice<UInt8>) -> Bool {
        guard let last = bytes.last, last == 0x48 || last == 0x66 else { return false }    // H, f
        var i = bytes.index(before: bytes.endIndex)
        var params: [UInt8] = []
        while i > bytes.startIndex {
            i = bytes.index(before: i)
            let b = bytes[i]
            if b == 0x5b {                                                                    // [
                guard i > bytes.startIndex, bytes[bytes.index(before: i)] == 0x1b else { return false }
                let p = String(decoding: params.reversed(), as: UTF8.self)
                return p.split(separator: ";", omittingEmptySubsequences: false).allSatisfy { $0.isEmpty || $0 == "1" || $0 == "0" }
            }
            guard (0x30...0x39).contains(b) || b == 0x3b, params.count < 12 else { return false }   // digits, ;
            params.append(b)
        }
        return false
    }

    /// Feeds the erase sequence itself: `ESC[3J` only when programs may clear the scrollback.
    public static func erase(_ code: UInt8, _ sequence: ArraySlice<UInt8>, terminal t: Terminal, programsMayClear: Bool,
                             feed: (ArraySlice<UInt8>) -> Void) {
        if code != UInt8(ascii: "3") || programsMayClear { feed(sequence) }
    }

    /// The next erase-in-display: `ESC[2J` → "2", `ESC[3J` → "3", `ESC[J` / `ESC[0J` → "0".
    public static func findErase(in bytes: ArraySlice<UInt8>) -> (Range<Int>, UInt8)? {
        var i = bytes.startIndex
        while i + 2 < bytes.endIndex {
            if bytes[i] == 0x1b, bytes[i + 1] == 0x5b {
                if bytes[i + 2] == 0x4a { return (i..<(i + 3), UInt8(ascii: "0")) }                  // ESC [ J
                if i + 3 < bytes.endIndex, bytes[i + 3] == 0x4a {
                    switch bytes[i + 2] {
                    case 0x30: return (i..<(i + 4), UInt8(ascii: "0"))                               // ESC [ 0 J
                    case 0x32, 0x33: return (i..<(i + 4), bytes[i + 2])                              // ESC [ 2 J / 3 J
                    default: break
                    }
                }
            }
            i += 1
        }
        return nil
    }

    /// Scrolls the lines in use on the screen up into the scrollback, keeping the cursor where it is.
    public static func keepScreen(_ t: Terminal, feed: (ArraySlice<UInt8>) -> Void) {
        // Only for the normal full-screen scroll region (apps with their own region manage the screen).
        guard t.buffer.scrollTop == 0, t.buffer.scrollBottom == t.rows - 1 else { return }
        let top = lineCount(t) - t.rows
        var lastUsed = -1
        for r in 0..<t.rows {
            if let line = t.getScrollInvariantLine(row: top + r), !isBlank(line) { lastUsed = r }
        }
        guard lastUsed >= 0 else { return }
        let scroll = "\u{1b}7\u{1b}[\(t.rows);1H" + String(repeating: "\n", count: lastUsed + 1) + "\u{1b}8"
        feed(Array(scroll.utf8)[...])
    }

    /// Rows in the active buffer, scroll-invariant: the last `rows` of them are the screen.
    /// `start` is a row known to exist (a previous count), so the search stays short.
    public static func lineCount(_ t: Terminal, from start: Int? = nil) -> Int {
        var lo = max((start ?? 1) - 1, t.buffer.totalLinesTrimmed)
        if t.getScrollInvariantLine(row: lo) == nil { lo = t.buffer.totalLinesTrimmed }
        guard t.getScrollInvariantLine(row: lo) != nil else { return lo }
        var step = 1
        while t.getScrollInvariantLine(row: lo + step) != nil { lo += step; step *= 2 }
        var hi = lo + step                      // lo exists, hi does not
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if t.getScrollInvariantLine(row: mid) != nil { lo = mid } else { hi = mid }
        }
        return lo + 1
    }

    /// Only spaces and empty cells. Checked cell by cell (every clear looks at each screen row):
    /// no string is built for it.
    public static func isBlank(_ line: BufferLine) -> Bool {
        for i in 0..<line.count {
            let cell = line[i]
            guard cell.isSimpleRune else { return false }       // a grapheme cluster: visible text
            switch cell.getCharacter() {
            case " ", "\0", "\t", "\u{a0}": continue
            default: return false
            }
        }
        return true
    }
}
