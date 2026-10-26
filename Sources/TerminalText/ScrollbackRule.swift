import Foundation
import SwiftTerm

/// How output treats the scrollback, the same for the terminal on screen and for text made from a
/// recording (`ScreenText`), so search and export show what the terminal kept:
///
/// - Clearing the screen (Ctrl+L, `clear`) first moves the visible lines into the scrollback, as
///   Terminal.app does. A clear is `ESC[2J`, or — as shells inside tmux and screen send it — `ESC[J`
///   with the cursor at the top left (after `ESC[H`).
/// - `ESC[3J` (erase the scrollback, sent by `clear` and by programs that redraw everything) is
///   ignored unless `programsMayClear` is set (Settings ▸ Terminal).
/// - Full-screen programs on the alternate screen are left alone.
public enum ScrollbackRule {
    /// Feeds `bytes` to `terminal` through `feed` (a view's own feed, so it redraws), applying the rule.
    /// `cleared` is told after each clear of the normal screen.
    public static func feed(_ bytes: ArraySlice<UInt8>, terminal t: Terminal, programsMayClear: Bool = false,
                            cleared: (() -> Void)? = nil, feed: (ArraySlice<UInt8>) -> Void) {
        var rest = bytes
        while let (range, code) = findErase(in: rest) {
            feed(rest[rest.startIndex..<range.lowerBound])
            let clears = keepsScreen(code, terminal: t)
            if clears { keepScreen(t, feed: feed) }
            erase(code, rest[range], terminal: t, programsMayClear: programsMayClear, feed: feed)
            if clears { cleared?() }
            rest = rest[range.upperBound...]
        }
        if !rest.isEmpty { feed(rest) }
    }

    /// Whether the erase `code` clears a normal screen whose lines must first go to the scrollback.
    public static func keepsScreen(_ code: UInt8, terminal t: Terminal) -> Bool {
        guard !t.isCurrentBufferAlternate else { return false }
        switch code {
        case UInt8(ascii: "2"): return true
        case UInt8(ascii: "0"):
            let cursor = t.getCursorLocation()
            return cursor.x == 0 && cursor.y == 0
        default: return false
        }
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

    public static func isBlank(_ line: BufferLine) -> Bool {
        line.translateToString(trimRight: true).replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespaces).isEmpty
    }
}
