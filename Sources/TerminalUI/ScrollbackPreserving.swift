import AppKit
import SwiftTerm

extension TerminalView {
    /// Feeds output like Terminal.app: clearing the screen (Ctrl+L, `clear`: ESC[2J) first moves the
    /// visible lines into the scrollback, so nothing is lost, and output cannot erase the scrollback
    /// (ESC[3J). Full-screen programs on the alternate screen are left alone.
    func feedKeepingScrollback(_ bytes: ArraySlice<UInt8>) {
        var rest = bytes
        while let (range, code) = Self.findErase(in: rest) {
            feed(byteArray: rest[rest.startIndex..<range.lowerBound])
            if code == UInt8(ascii: "2") {
                if !getTerminal().isCurrentBufferAlternate { keepScreenInScrollback() }
                feed(byteArray: rest[range])
            }
            rest = rest[range.upperBound...]
        }
        if !rest.isEmpty { feed(byteArray: rest) }
    }

    /// The next `ESC [ 2 J` or `ESC [ 3 J`, and which one it is.
    static func findErase(in bytes: ArraySlice<UInt8>) -> (Range<Int>, UInt8)? {
        var i = bytes.startIndex
        while i + 3 < bytes.endIndex {
            if bytes[i] == 0x1b, bytes[i + 1] == 0x5b, bytes[i + 3] == 0x4a, bytes[i + 2] == 0x32 || bytes[i + 2] == 0x33 {
                return (i..<(i + 4), bytes[i + 2])
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
