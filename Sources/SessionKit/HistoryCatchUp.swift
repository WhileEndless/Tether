import Foundation

/// Catching up after a reconnect: what the server's tmux pane printed while Tether was not
/// connected is added to the local terminal as if it had streamed in live, so the local scrollback
/// and the recording miss nothing and repeat nothing.
///
/// The local screen still shows what tmux showed at the moment the connection dropped. Its last
/// used rows (the anchor) are looked up in the pane's captured history + screen; everything after
/// them is new and is printed below the anchor row, scrolling the terminal like live output would.
enum HistoryCatchUp {
    /// The local screen's last used rows (plain text, trailing spaces removed) and the row of the last one.
    struct Anchor: Equatable {
        var lines: [String]
        var lastRow: Int
    }

    /// A captured line as plain text: escape sequences removed, trailing spaces trimmed.
    static func plainText(_ line: [UInt8]) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(line.count)
        var i = 0
        while i < line.count {
            let b = line[i]
            guard b == 0x1b, i + 1 < line.count else {
                if b >= 0x20 || b == 0x09 { out.append(b) }
                i += 1
                continue
            }
            let next = line[i + 1]
            if next == UInt8(ascii: "[") {                      // CSI … final byte 0x40–0x7e
                i += 2
                while i < line.count, !(0x40...0x7e).contains(line[i]) { i += 1 }
                i += 1
            } else if next == UInt8(ascii: "]") {               // OSC … BEL or ESC \
                i += 2
                while i < line.count, line[i] != 0x07, !(line[i] == 0x1b && i + 1 < line.count && line[i + 1] == UInt8(ascii: "\\")) { i += 1 }
                i += (i < line.count && line[i] == 0x07) ? 1 : 2
            } else {
                i += 2
            }
        }
        var text = String(decoding: out, as: UTF8.self)
        while text.last == " " { text.removeLast() }
        return text
    }

    /// Where the new output starts in `captured` (plain rows): right after the last place the anchor
    /// appears, or nil when it is not there (cleared, or older than what the server kept).
    static func resumeIndex(captured: [String], anchor: [String]) -> Int? {
        guard !anchor.isEmpty, anchor.contains(where: { !$0.isEmpty }), captured.count >= anchor.count else { return nil }
        var start = captured.count - anchor.count
        while start >= 0 {
            if Array(captured[start..<(start + anchor.count)]) == anchor { return start + anchor.count }
            start -= 1
        }
        return nil
    }

    /// `stream` prints `captured[start...]` below the anchor row as live output would (it is recorded).
    /// `captured` ends with the pane's full screen (`height` rows), so the bottom rows line up.
    /// `redraw` then draws that screen once more in place and puts the cursor where tmux has it, so the
    /// screen matches tmux exactly even if the local one had drifted; it only touches the screen (no
    /// scrolling), so it is shown but not recorded — the recording would otherwise hold the screen twice.
    static func output(captured: [[UInt8]], from start: Int, anchorRow: Int, height: Int,
                       cursor: (x: Int, y: Int), notice: String? = nil) -> (stream: [UInt8], redraw: [UInt8]) {
        var out = Array("\u{1b}[\(anchorRow + 1);1H".utf8)
        if let notice {
            out += Array("\r\n\u{1b}[2K\u{1b}[2m\(notice)\u{1b}[0m".utf8)
        }
        for line in captured[start...] {
            out += Array("\r\n\u{1b}[2K".utf8)
            out += line
            out += Array("\u{1b}[0m".utf8)
        }
        var redraw: [UInt8] = []
        if height > 0, captured.count >= height {
            for (row, line) in captured.suffix(height).enumerated() {
                redraw += Array("\u{1b}[\(row + 1);1H\u{1b}[2K".utf8)
                redraw += line
                redraw += Array("\u{1b}[0m".utf8)
            }
        }
        let place = Array("\u{1b}[0m\u{1b}[\(cursor.y + 1);\(cursor.x + 1)H".utf8)
        return (out + place, redraw + place)
    }
}
