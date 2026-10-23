import AppKit
import SwiftTerm

extension TerminalView {
    /// Feeds output like Terminal.app: clearing the screen (Ctrl+L, `clear`) first moves the visible
    /// lines into the scrollback, so nothing is lost, and output cannot erase the scrollback (ESC[3J).
    /// A clear is `ESC[2J`, or — as shells inside tmux and screen send it — `ESC[J` with the cursor
    /// at the top left (after `ESC[H`). Full-screen programs on the alternate screen are left alone.
    func feedKeepingScrollback(_ bytes: ArraySlice<UInt8>) {
        var rest = bytes
        while let (range, code) = Self.findErase(in: rest) {
            feed(byteArray: rest[rest.startIndex..<range.lowerBound])
            let t = getTerminal()
            switch code {
            case UInt8(ascii: "2"):
                if !t.isCurrentBufferAlternate { keepScreenInScrollback() }
                feed(byteArray: rest[range])
            case UInt8(ascii: "0"):
                let cursor = t.getCursorLocation()
                if !t.isCurrentBufferAlternate && cursor.x == 0 && cursor.y == 0 { keepScreenInScrollback() }
                feed(byteArray: rest[range])
            default:
                break   // ESC[3J: the scrollback is never erased by output
            }
            rest = rest[range.upperBound...]
        }
        if !rest.isEmpty { feed(byteArray: rest) }
    }

    /// The next erase-in-display: `ESC[2J` → "2", `ESC[3J` → "3", `ESC[J` / `ESC[0J` → "0".
    static func findErase(in bytes: ArraySlice<UInt8>) -> (Range<Int>, UInt8)? {
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
    private func keepScreenInScrollback() {
        let t = getTerminal()
        // Only for the normal full-screen scroll region (apps with their own region manage the screen).
        guard t.buffer.scrollTop == 0, t.buffer.scrollBottom == t.rows - 1 else { return }
        var total = t.buffer.totalLinesTrimmed
        while t.getScrollInvariantLine(row: total) != nil { total += 1 }
        let top = total - t.rows
        var lastUsed = -1
        for r in 0..<t.rows {
            if let line = t.getScrollInvariantLine(row: top + r),
               !line.translateToString(trimRight: true).replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespaces).isEmpty {
                lastUsed = r
            }
        }
        guard lastUsed >= 0 else { return }
        let scroll = "\u{1b}7\u{1b}[\(t.rows);1H" + String(repeating: "\n", count: lastUsed + 1) + "\u{1b}8"
        feed(byteArray: Array(scroll.utf8)[...])
    }
}
