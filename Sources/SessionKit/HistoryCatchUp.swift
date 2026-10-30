import Foundation

/// Catching up after a reconnect: what the server's tmux pane printed while Tether was not
/// connected is added to the local terminal as if it had streamed in live, so the local scrollback
/// and the recording miss nothing and repeat nothing.
///
/// The local screen still shows what tmux showed at the moment the connection dropped. Its last
/// used rows (the anchor) are looked up in the pane's captured history + screen; everything after
/// them is new and is printed below the anchor row, scrolling the terminal like live output would.
enum HistoryCatchUp {
    /// The local screen's last used rows (plain text, trailing spaces removed) and the row of the
    /// last one; the cursor's row, when known.
    struct Anchor: Equatable {
        var lines: [String]
        var lastRow: Int
        var cursorRow: Int? = nil
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

    /// Where the new output starts in `captured` (plain rows).
    struct Resume: Equatable {
        /// The first captured row to print.
        var index: Int
        /// It is the anchor's last row, printed again over it: that row was still being written when
        /// the connection dropped (a prompt, a line without its end yet, a progress bar).
        var replacesLastRow: Bool
    }

    /// Where the new output starts in `captured`: after the last place the anchor appears; when its
    /// last row changed meanwhile (more was written on it, or a progress line was redrawn), that row
    /// is printed again in its final form. Nil when the anchor is not there (cleared, or older than
    /// what the server kept).
    static func resume(captured: [String], anchor: [String]) -> Resume? {
        guard let last = anchor.last, anchor.contains(where: { !$0.isEmpty }), captured.count >= anchor.count else { return nil }
        let n = anchor.count
        let head = anchor.dropLast()
        // The top row may be the end of a line whose start the local terminal never had (output
        // from before it was there): it matches the end of the server's row.
        func headMatches(_ start: Int) -> Bool {
            guard n > 1 else { return true }
            let top = captured[start]
            guard top == anchor[0] || (!anchor[0].isEmpty && n > 2 && top.hasSuffix(anchor[0])) else { return false }
            return captured[(start + 1)..<(start + n - 1)].elementsEqual(head.dropFirst())
        }
        // The newest place whose rows are the same, the last one perhaps with more written on it.
        for start in stride(from: captured.count - n, through: 0, by: -1) where headMatches(start) {
            let row = captured[start + n - 1]
            if row == last { return Resume(index: start + n, replacesLastRow: false) }
            if !last.isEmpty, row.hasPrefix(last) { return Resume(index: start + n - 1, replacesLastRow: true) }
        }
        // The last row was rewritten (a progress line): the rows above it alone, when they are enough
        // to be sure (two with text).
        guard head.filter({ !$0.isEmpty }).count >= 2 else { return resumeByText(captured: captured, anchor: anchor) }
        for start in stride(from: captured.count - n, through: 0, by: -1) where headMatches(start) {
            return Resume(index: start + n - 1, replacesLastRow: true)
        }
        return resumeByText(captured: captured, anchor: anchor)
    }

    /// The anchor's text found in `captured` whatever the rows: a restored tab draws its recording
    /// at the width it has now, not the one the output was written at — long lines wrap elsewhere,
    /// and zsh's mark for output without a final line break (`%`, `#` as root: printed with as many
    /// spaces as the terminal was wide, then taken back) is left on a row of its own. Compared
    /// without spaces and without those rows, the anchor's last character at the end of a row.
    static func resumeByText(captured: [String], anchor: [String]) -> Resume? {
        func letters(_ s: String) -> [Character] {
            let kept = s.filter { $0 != " " }
            return kept == "%" || kept == "#" ? [] : Array(kept)
        }
        let rows = anchor.map(letters)
        // Enough to be sure: two rows with text, and more than a few characters.
        guard rows.filter({ !$0.isEmpty }).count >= 2, let lastText = rows.lastIndex(where: { !$0.isEmpty }) else { return nil }
        let whole = rows.flatMap { $0 }
        let head = rows[..<lastText].flatMap { $0 }
        let last = rows[lastText]
        guard whole.count >= 8 else { return nil }
        let text = captured.map(letters)
        /// Whether the text of `captured` up to the end of row `end` ends in `want`.
        func endsIn(_ want: [Character], atRow end: Int) -> Bool {
            var k = want.count, r = end
            while k > 0 {
                guard r >= 0 else { return false }
                let row = text[r]
                var c = row.count
                while c > 0, k > 0 {
                    guard row[c - 1] == want[k - 1] else { return false }
                    c -= 1; k -= 1
                }
                if k > 0 { r -= 1 }
            }
            return true
        }
        // The newest place: the anchor whole, else its last row with more written on it.
        for end in stride(from: captured.count - 1, through: 0, by: -1) where !text[end].isEmpty {
            if endsIn(whole, atRow: end) { return Resume(index: end + 1, replacesLastRow: false) }
            if text[end].starts(with: last), text[end].count > last.count, end > 0, endsIn(head, atRow: end - 1) {
                return Resume(index: end, replacesLastRow: true)
            }
        }
        return nil
    }

    /// The index output continues from (see `resume`).
    static func resumeIndex(captured: [String], anchor: [String]) -> Int? {
        resume(captured: captured, anchor: anchor)?.index
    }

    /// `stream` prints `captured[start...]` below the anchor row as live output would (it is recorded).
    /// `captured` ends with the pane's full screen (`height` rows), so the bottom rows line up.
    /// `redraw` then draws that screen once more in place and puts the cursor where tmux has it, so the
    /// screen matches tmux exactly even if the local one had drifted; it only touches the screen (no
    /// scrolling), so it is shown but not recorded — the recording would otherwise hold the screen twice.
    /// With `replacingAnchorRow`, the first line is printed over the anchor row instead of below it.
    /// With `cursorRow` (the local cursor's row), `stream` moves only relative to the cursor: it is
    /// recorded, and a recording is shown again at other heights (a restored tab first draws at a
    /// guessed size, the history view at the window's) — rows counted from the top of the screen
    /// it was written for would land elsewhere there, over earlier output, and a command typed next
    /// would be marked on another line.
    /// The lines tmux joined (`capture-pane -J`: a long line wrapped on its screen comes as one)
    /// from row `start` of the same capture taken row by row (`rows`, as plain text) on: what is
    /// added after a re-attach then wraps at the terminal's width, as the line it was, also when
    /// the window is made wider later — not at the width tmux had. nil when the two do not line up
    /// (output came in between, or `start` is inside a wrapped line): the rows are used then.
    static func joinedLines(rows: [String], joined: [[UInt8]], from start: Int) -> [[UInt8]]? {
        func letters(_ s: String) -> String { s.filter { $0 != " " } }
        // Every joined line is made of whole rows, all the way: the place `start` is at is kept.
        var r = 0
        var from: Int?
        for (k, line) in joined.enumerated() {
            if r == start { from = k }
            if r > start, from == nil { return nil }
            let want = letters(plainText(line))
            var got = ""
            repeat {
                guard r < rows.count else { return nil }
                got += letters(rows[r])
                r += 1
            } while got.count < want.count
            guard got == want else { return nil }
        }
        guard r == rows.count else { return nil }
        if r == start { return [] }
        return from.map { Array(joined[$0...]) }
    }

    /// `screen`: the screen's rows to draw again (row by row as tmux has them), when `captured` is
    /// joined lines.
    static func output(captured: [[UInt8]], from start: Int, anchorRow: Int, cursorRow: Int? = nil, height: Int,
                       cursor: (x: Int, y: Int), notice: String? = nil,
                       replacingAnchorRow: Bool = false, screen: [[UInt8]]? = nil) -> (stream: [UInt8], redraw: [UInt8]) {
        var out: [UInt8]
        if let cursorRow {
            let down = anchorRow - cursorRow
            out = Array(("\r" + (down > 0 ? "\u{1b}[\(down)B" : down < 0 ? "\u{1b}[\(-down)A" : "")).utf8)
        } else {
            out = Array("\u{1b}[\(anchorRow + 1);1H".utf8)
        }
        if let notice {
            out += Array("\r\n\u{1b}[2K\u{1b}[2m\(notice)\u{1b}[0m".utf8)
        }
        for (i, line) in captured[start...].enumerated() {
            out += Array((i == 0 && replacingAnchorRow && notice == nil ? "\r\u{1b}[2K" : "\r\n\u{1b}[2K").utf8)
            out += line
            out += Array("\u{1b}[0m".utf8)
        }
        var redraw: [UInt8] = []
        let rows = screen ?? captured
        if height > 0, rows.count >= height {
            for (row, line) in rows.suffix(height).enumerated() {
                redraw += Array("\u{1b}[\(row + 1);1H\u{1b}[2K".utf8)
                redraw += line
                redraw += Array("\u{1b}[0m".utf8)
            }
        }
        let place = Array("\u{1b}[0m\u{1b}[\(cursor.y + 1);\(cursor.x + 1)H".utf8)
        guard cursorRow != nil else { return (out + place, redraw + place) }
        // The stream ends on the row of the screen's last one (tmux's row `height - 1`): from there.
        let up = height - 1 - cursor.y
        let back = Array(("\u{1b}[0m\r" + (up > 0 ? "\u{1b}[\(up)A" : "") + (cursor.x > 0 ? "\u{1b}[\(cursor.x)C" : "")).utf8)
        return (out + back, redraw + place)
    }
}
