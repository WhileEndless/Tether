import AppKit
import SwiftTerm
import RecordingKit
import TerminalText

/// Earlier output than the live terminal holds, shown over it while the user scrolls back: a
/// read-only terminal replaying a window of the session's recording, moved through it a chunk at
/// a time as the user scrolls (memory stays the same however long the session is).
///
/// The live terminal underneath is never touched: what runs there goes on, its modes and screen
/// stay as they are, and going back to it is only hiding this view.
final class HistoryTerminalView: TerminalView, TerminalViewDelegate {
    unowned let live: TetherTerminalView
    /// The same, to tell whether it is still there: a part read in the background can arrive after
    /// the terminal went (its tab closed) while this view was still held; it is let go of then.
    private weak var owner: TetherTerminalView?

    /// The part of the recording shown, as positions in its output (`RecordingReader`'s).
    struct Window: Equatable { var start: Int; var end: Int }
    private(set) var shown: Window?
    /// The recording's length when the window was read: a window ending there reaches the live end.
    private(set) var total = 0
    /// Where the live terminal's first line is in this replay (scroll-invariant row), and how many
    /// lines the live terminal had dropped then: scrolling down past it shows the live terminal.
    private var liveTop: (row: Int, liveDropped: Int)?
    /// Commands run in the window: scroll-invariant rows, and what the recording says of them.
    private(set) var commands: [(row: Int, mark: RecordingIndex.Mark)] = []
    /// What the recording's index adds to the positions of what is shown (see `Replay.base`).
    private(set) var indexBase = 0

    /// The index position of a command of the part shown.
    func indexOffset(of mark: RecordingIndex.Mark) -> Int { mark.offset + indexBase }
    /// Marks of the part shown that ran no command (Return pressed with nothing before the cursor).
    private var skippedMarks: Set<Int> = []
    /// Whether the mark at index position `offset` is in the part shown and ran no command.
    func ranNoCommand(atIndexOffset offset: Int) -> Bool { skippedMarks.contains(offset - indexBase) }

    /// The place in `index` of the last command before scroll-invariant row `row` (one before the
    /// part shown when none in it is above), nil when there is none.
    func command(before row: Int, in index: RecordingIndex) -> Int? {
        if let c = commands.last(where: { $0.row < row }) { return position(of: c.mark, in: index) }
        // Commands of the part not in `commands` were in rows it dropped from its top.
        let limit = commands.first.map(\.mark.offset) ?? shown?.end ?? 0
        return index.marks.lastIndex { $0.offset - indexBase < limit }
    }

    /// The place in `index` of the first command after scroll-invariant row `row` (one after the
    /// part shown when none in it is below), nil when there is none.
    func command(after row: Int, in index: RecordingIndex) -> Int? {
        if let c = commands.first(where: { $0.row > row }) { return position(of: c.mark, in: index) }
        let from = commands.last.map { $0.mark.offset + 1 } ?? shown?.end ?? 0
        return index.marks.firstIndex { $0.offset - indexBase >= from }
    }

    private func position(of mark: RecordingIndex.Mark, in index: RecordingIndex) -> Int? {
        let offset = indexOffset(of: mark)
        return index.marks.firstIndex { $0.offset == offset }
    }

    /// Set while the recording is read and replayed.
    private(set) var loading = false {
        didSet { if loading != oldValue { live.historyLoadingChanged() } }
    }

    /// At the edge of what is shown, in the direction a part is being read (the user waits for it).
    var waitsAtEdge: Bool {
        guard loading, shown != nil else { return false }
        let t = getTerminal()
        return t.buffer.yDisp == 0 || atBottom
    }
    private var queued = false
    /// Uptime before which no new load starts by itself (one just gave up).
    private var retryAfter: TimeInterval = 0
    /// Called when a load ends (applied or given up).
    var onLoaded: ((Bool) -> Void)?

    init(live: TetherTerminalView) {
        self.live = live
        owner = live
        var options = TerminalOptions.default
        options.scrollback = 1_000
        super.init(frame: live.bounds, font: live.font, options: options)
        terminalDelegate = self
        scrollerStyle = .legacy
        allowMouseReporting = false
        getTerminal().registerOscHandler(code: 7771) { _ in }    // Tether's markers in the recording
        HistoryScroller.hideNativeScroller(of: self)              // the live terminal's stands for both
        SteadyCaret.prepare(self)
        applyLook()
    }

    // Old output has no cursor: the cursor view stays hidden (and never moves the window's layout).
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        guard !holdingDisplay else { return }
        super.setNeedsDisplay(invalidRect)
        SteadyCaret.sync(self, shown: false, onScreen: false)
    }

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set { if !(holdingDisplay && newValue) { super.needsDisplay = newValue } }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The live terminal's font and colours.
    func applyLook() {
        if font != live.font { font = live.font }
        installColors(live.theme.ansi)
        nativeForegroundColor = live.theme.foreground
        nativeBackgroundColor = live.theme.background
        selectedTextBackgroundColor = live.theme.selection
        optionAsMetaKey = live.optionAsMetaKey
    }

    // MARK: Sizes

    /// Rows in the buffer (scrollback and screen).
    var bufferRows: Int {
        let t = getTerminal()
        var lo = t.buffer.totalLinesTrimmed, hi = lo + 4_000_000
        while lo < hi {
            let mid = (lo + hi) / 2
            if t.getScrollInvariantLine(row: mid) != nil { lo = mid + 1 } else { hi = mid }
        }
        return lo - t.buffer.totalLinesTrimmed
    }

    /// The cursor's scroll-invariant row.
    private var cursorInvariantRow: Int {
        let t = getTerminal()
        return bufferRows - t.rows + t.getCursorLocation().y + t.buffer.totalLinesTrimmed
    }

    /// The scroll-invariant row at the top of the view.
    var topInvariantRow: Int { getTerminal().buffer.yDisp + getTerminal().buffer.totalLinesTrimmed }

    private var atBottom: Bool { getTerminal().buffer.yDisp >= bufferRows - getTerminal().rows }

    // MARK: Loading

    /// What a load replays, and where the rows of interest are.
    private struct Replay: Sendable {
        var data: Data
        /// Where `data` starts in the recording.
        var start: Int
        var window: Window
        var total: Int
        /// Positions whose rows are wanted (line starts): the line kept in view, the live
        /// terminal's first line, commands.
        var anchor: Int
        var liveStart: Int?
        var marks: [RecordingIndex.Mark]
        /// The line number (in the whole session) of the window's first line, when known.
        var startLine: Int? = nil
        /// A full-screen program's screen was up where the window starts (its output there goes
        /// to that screen, as it did in the live terminal, not into the history).
        var startsInAlternate = false
        /// What the replay left, drawn instead of replaying it (worked out off the main thread).
        var compacted: ReplayCompactor.Result?
        /// Bytes of the recording no longer there (see `base`): index positions are this much more.
        var base = 0
        /// The terminal it was worked out for.
        var shape: Shape?
        /// Positions whose rows a find needs (its matches' places in the recording).
        var findCuts: [Int] = []
    }

    /// How far apart the positions are whose rows are noted, besides those asked for: where any
    /// position is found within this many bytes, however much output was redrawn in place.
    nonisolated static let cutSpacing = 4096

    /// The position just after the first line break at or after `offset` in `data` (which starts
    /// at `start`), nil without one there. The same in every part that holds it.
    nonisolated static func snap(_ offset: Int, in data: Data, start: Int) -> Int? {
        guard offset >= start, offset < start + data.count,
              let nl = data[(data.startIndex + offset - start)...].firstIndex(of: 0x0a) else { return nil }
        return start + (nl - data.startIndex) + 1
    }

    /// `snap` in the part shown.
    func snapped(_ offset: Int) -> Int? {
        guard let shown else { return nil }
        return Self.snap(offset, in: replayed, start: shown.start)
    }

    /// The terminal a replay is worked out for: this view's size and scrollback.
    private struct Shape: Sendable, Equatable {
        var cols: Int, rows: Int, scrollback: Int, programsMayClear: Bool, keepRedraws: Bool, knowsTyping: Bool
    }

    private var shape: Shape {
        Shape(cols: getTerminal().cols, rows: getTerminal().rows,
              scrollback: live.historyWindowLines + live.historyWindowLines / 4,
              programsMayClear: live.programsMayClearScrollback, keepRedraws: live.keepsRedrawnFrames,
              knowsTyping: live.historyIndex?()?.marks.isEmpty == false)
    }

    /// Works out what `replay` leaves on a terminal of its own (off the main thread and off the
    /// recording's queue), then hands it to `then` on the main thread.
    nonisolated private static func prepare(_ replay: Replay, _ shape: Shape, then: @escaping @MainActor (Replay) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var r = replay
            r.shape = shape
            for _ in 0..<6 {
                var cuts = Set(r.marks.flatMap { [$0.offset, $0.at] })
                let end = r.start + r.data.count
                // Each just after a line break: a piece fed must not end inside an escape sequence
                // (a clear cut in two would be missed, and the rows laid out otherwise).
                let wanted = Array(stride(from: r.start - r.start % cutSpacing + cutSpacing, to: end, by: cutSpacing))
                    + r.findCuts.filter { $0 > r.start && $0 < end }
                cuts.formUnion(wanted.compactMap { snap($0, in: r.data, start: r.start) })
                cuts.insert(r.anchor)
                if let s = r.liveStart { cuts.insert(s) }
                r.compacted = ReplayCompactor.compact([UInt8](r.data), start: r.start, cuts: Array(cuts), cols: shape.cols,
                                                      rows: shape.rows, scrollback: shape.scrollback,
                                                      startsInAlternate: r.startsInAlternate, programsMayClear: shape.programsMayClear,
                                                      keepRedraws: shape.keepRedraws, knowsTyping: shape.knowsTyping)
                // At this width the lines read take more rows than the view keeps (it got narrower
                // after they were read): the line asked for went from the top with the oldest rows.
                // Fewer lines are kept, so it stays.
                guard let c = r.compacted, c.rows[r.anchor] == nil, c.trimmedAway.contains(r.anchor), Self.shorten(&r) else { break }
            }
            let ready = r
            DispatchQueue.main.async { MainActor.assumeIsolated { then(ready) } }
        }
    }

    /// `replay` as this terminal is now: worked out again when the view changed size meanwhile
    /// (rows laid out at another width would put everything on the wrong rows).
    private func whenCurrent(_ replay: Replay, _ body: @escaping @MainActor (Replay) -> Void) {
        guard owner != nil else { return }
        let now = shape
        guard replay.shape != now else { body(replay); return }
        Self.prepare(replay, now) { [weak self] r in self?.whenCurrent(r, body) }
    }

    /// Where the view goes after a load.
    private enum Placement {
        /// The anchor line stays where `topRow` (relative to it) had it: scrolling continues.
        case keep(offsetFromAnchor: Int)
        /// As `keep`, with the view as it is when the new part is put in (it may have been scrolled
        /// while the part was read): from the window's first row (`up`) or its last.
        case keepView(up: Bool)
        /// The anchor line a third down the screen (a search result, a command).
        case show
        /// The anchor line at the top (the scroller dragged there).
        case top
    }

    /// Lines of the recording the window holds: the memory budget in rows, by how many rows a line
    /// takes here (long lines wrap).
    private func windowLines(rowsPerLine: Double) -> Int {
        max(Int(Double(live.historyWindowLines) / max(rowsPerLine, 1)), getTerminal().rows * 3)
    }

    /// Rows per line in what is replayed now (1 before anything is).
    var rowsPerLine: Double {
        guard let shown, shown.end > shown.start else { return live.rowsPerLine }
        let lines = max(replayedLines, 1)
        // Every row the replay made, those trimmed from its top included.
        return max(1, Double(bufferRows + getTerminal().buffer.totalLinesTrimmed) / Double(lines))
    }
    private var replayedLines = 0

    /// Starts browsing from the live terminal's top: the window holds the live terminal's lines and
    /// a chunk before them, and the view shows exactly what the live terminal showed.
    /// `liveTopRows`: when the live terminal's top row continues a long line whose first rows it
    /// dropped, how many of that line's rows it still shows (the history shows the whole line).
    func enter(liveLines: Int, liveTopOffset: Int, liveTopRows: Int?, done: @escaping (Bool) -> Void) {
        guard !loading, let reader = live.historyReader else { done(false); return }
        let lines = windowLines(rowsPerLine: live.rowsPerLine)
        let chunk = max(min(live.historyChunkLines, lines / 2), 1)
        let rows = getTerminal().rows
        let index = live.historyIndex?()
        let shape = self.shape
        let findCuts = live.findCutOffsets()
        loading = true
        let started = reader { [weak self] snap in
            let url = snap.url, total = snap.length
            let base = Self.base(index, url)
            let liveStart = snap.lines(endingAt: total, count: liveLines).start
            guard liveStart > 0 else {
                DispatchQueue.main.async { self?.giveUp(); done(false) }
                return
            }
            let before = snap.lines(endingAt: liveStart, count: chunk)
            let after = snap.lines(startingAt: liveStart, count: max(lines - chunk, rows))
            var replay = Replay(data: before.data + after.data, start: before.start,
                                window: Window(start: before.start, end: after.end), total: total, anchor: liveStart,
                                liveStart: after.end >= total ? liveStart : nil,
                                marks: Self.marks(index, base: base, in: before.start..<after.end))
            replay.base = base
            replay.startLine = Self.line(of: replay.start, index: index, base: base, snap: snap)
            replay.startsInAlternate = Self.alternateScreen(at: replay.start, snap: snap)
            replay.findCuts = findCuts
            Self.prepare(replay, shape) { replay in
                self?.whenCurrent(replay) { replay in
                    guard let self else { return }
                    self.apply(replay, placement: .keep(offsetFromAnchor: liveTopOffset), partlyShownRows: liveTopRows, done: done)
                }
            }
        }
        if !started { loading = false; done(false) }
    }

    /// The view reached the top or the bottom of the window: the next chunk of the recording.
    func slide(up: Bool) {
        guard !loading, let shown, let reader = live.historyReader else { return }
        if up, shown.start == 0 { return }
        let lines = windowLines(rowsPerLine: rowsPerLine)
        let chunk = max(min(live.historyChunkLines, lines / 2), 1)
        let rows = getTerminal().rows
        let liveLines = live.linesAboveCursor
        let index = live.historyIndex?()
        // What stays of the window is in memory already (what it replayed): only the new chunk is
        // read from the recording.
        let held = replayed
        let shape = self.shape
        let findCuts = live.findCutOffsets()
        loading = true
        let started = reader { [weak self] snap in
            let url = snap.url, total = snap.length
            let base = Self.base(index, url)
            func breaks(_ d: Data) -> Int { d.reduce(0) { $0 + ($1 == 0x0a ? 1 : 0) } }
            var replay: Replay
            if up {
                let before = snap.lines(endingAt: shown.start, count: chunk)
                let keep = max(lines - breaks(before.data) - rows, rows)
                let rest = Self.kept(held, startingAt: shown.start, count: keep)
                replay = Replay(data: before.data + rest.data, start: before.start, window: Window(start: before.start, end: rest.end),
                                total: total, anchor: shown.start, liveStart: nil, marks: [])
            } else {
                let after = snap.lines(startingAt: shown.end, count: chunk)
                let keep = max(lines - breaks(after.data) - rows, rows)
                let stays = Self.kept(held, endingAt: shown.end, count: keep)
                replay = Replay(data: stays.data + after.data, start: stays.start, window: Window(start: stays.start, end: after.end),
                                total: total, anchor: shown.end, liveStart: nil, marks: [])
            }
            if replay.window.end >= total {
                let liveStart = snap.lines(endingAt: total, count: liveLines).start
                if liveStart >= replay.window.start { replay.liveStart = liveStart }
            }
            replay.marks = Self.marks(index, base: base, in: replay.window.start..<replay.window.end)
            replay.base = base
            replay.startLine = Self.line(of: replay.start, index: index, base: base, snap: snap)
            replay.startsInAlternate = Self.alternateScreen(at: replay.start, snap: snap)
            // The line at the edge being scrolled past stays where it is on screen.
            replay.findCuts = findCuts
            Self.prepare(replay, shape) { replay in
                self?.whenCurrent(replay) { replay in self?.apply(replay, placement: .keepView(up: up)) }
            }
        }
        if !started { loading = false }
    }

    /// Shows the recording at `offset` (a line start, or about one): a search result, a command,
    /// the scroller dragged there. `done` gets the scroll-invariant row of the line at `offset`.
    /// `indexed`: `offset` is the index's (from the very start), and `skipLines` more lines are
    /// skipped from there (a line number: its checkpoint, then the lines after it).
    /// `through`: the window reaches at least this far (a find's piece of the recording: output a
    /// program redrew in place has many line breaks for few lines, which would end the window early).
    func show(offset: Int, indexed: Bool = false, skipLines: Int = 0, atTop: Bool = false, through: Int? = nil,
              done: ((Int) -> Void)? = nil) {
        guard !loading, let reader = live.historyReader else { return }
        let lines = windowLines(rowsPerLine: shown == nil ? live.rowsPerLine : rowsPerLine)
        let rows = getTerminal().rows
        let liveLines = live.linesAboveCursor
        let index = live.historyIndex?()
        let shape = self.shape
        let findCuts = live.findCutOffsets()
        loading = true
        let started = reader { [weak self] snap in
            let url = snap.url, total = snap.length
            let base = Self.base(index, url)
            var at = min(max(indexed ? offset - base : offset, 0), total)
            if skipLines > 0 {
                let ahead = snap.lines(startingAt: at, count: skipLines)
                at = ahead.end
            }
            // From the start of the line at (or after) the position.
            if at > 0, skipLines == 0, !indexed, let nl = snap.bytes(from: at - 1, to: min(total, at + (1 << 20))).firstIndex(of: 0x0a) {
                at += nl
            }
            let before = snap.lines(endingAt: at, count: atTop ? lines / 4 : lines / 3)
            var after = snap.lines(startingAt: at, count: max(lines - lines / 3, rows))
            if let through, after.end < min(through, total) {
                // On to the end of the line at `through` (at most a megabyte more).
                let limit = min(total, through + (1 << 20))
                let tail = snap.bytes(from: through, to: limit)
                let end = tail.firstIndex(of: 0x0a).map { through + ($0 - tail.startIndex) + 1 } ?? limit
                after = (end, after.data + snap.bytes(from: after.end, to: end))
            }
            var replay = Replay(data: before.data + after.data, start: before.start, window: Window(start: before.start, end: after.end),
                                total: total, anchor: at, liveStart: nil, marks: [])
            if replay.window.end >= total {
                let liveStart = snap.lines(endingAt: total, count: liveLines).start
                if liveStart >= replay.window.start { replay.liveStart = liveStart }
            }
            replay.marks = Self.marks(index, base: base, in: replay.window.start..<replay.window.end)
            replay.base = base
            replay.startLine = Self.line(of: replay.start, index: index, base: base, snap: snap)
            replay.startsInAlternate = Self.alternateScreen(at: replay.start, snap: snap)
            replay.findCuts = findCuts
            Self.prepare(replay, shape) { replay in
                self?.whenCurrent(replay) { replay in
                    guard let self else { return }
                    self.apply(replay, placement: atTop ? .top : .show) { [weak self] ok in
                        guard let self, ok else { return }
                        done?(self.anchorRow)
                    }
                }
            }
        }
        if !started { loading = false }
    }

    /// The first `count` lines of the bytes a window replayed (it started at `start`).
    nonisolated private static func kept(_ held: Data, startingAt start: Int, count: Int) -> (end: Int, data: Data) {
        let r = RecordingReader.lines(startingAt: 0, count: count, total: held.count) { held.subdata(in: (held.startIndex + $0)..<(held.startIndex + $1)) }
        return (start + r.end, r.data)
    }

    /// The last `count` lines of the bytes a window replayed (it ended at `end`).
    nonisolated private static func kept(_ held: Data, endingAt end: Int, count: Int) -> (start: Int, data: Data) {
        let r = RecordingReader.lines(endingAt: held.count, count: count) { held.subdata(in: (held.startIndex + $0)..<(held.startIndex + $1)) }
        return (end - (held.count - r.start), r.data)
    }

    /// Bytes of the recording no longer there (the storage limit removed its oldest parts):
    /// the index counts from the very start, the reader from the oldest part left.
    nonisolated private static func base(_ index: RecordingIndex?, _ url: URL) -> Int {
        guard let index, !index.partLengths.isEmpty else { return 0 }
        return index.removedLength(firstPart: RecordingParts.parts(of: url).first?.number)
    }

    /// The line number (in the whole session) at reader position `offset`, a line start.
    nonisolated private static func line(of offset: Int, index: RecordingIndex?, base: Int, snap: RecordingSnapshot) -> Int? {
        guard let index, index.isExact else { return nil }
        let checkpoint = index.checkpoint(before: offset + base)
        let from = checkpoint.offset - base
        guard from >= 0, from <= offset else { return nil }
        return checkpoint.line + snap.bytes(from: from, to: offset).reduce(0) { $0 + ($1 == 0x0a ? 1 : 0) }
    }

    /// Drops half of what comes before the anchor and, when more comes after it, a quarter of
    /// that, at lines' starts. False when there is nothing to drop.
    nonisolated private static func shorten(_ r: inout Replay) -> Bool {
        var data = r.data
        var anchor = r.anchor - r.start + data.startIndex
        guard anchor >= data.startIndex, anchor <= data.endIndex else { return false }
        var changed = false
        let beforeCount = anchor - data.startIndex, afterCount = data.endIndex - anchor
        if afterCount > beforeCount {
            let cut = data.endIndex - afterCount / 4
            if cut > anchor, let nl = data[cut...].firstIndex(of: 0x0a), nl + 1 < data.endIndex {
                data = data[..<(nl + 1)]
                r.window.end = r.start + data.count
                r.marks = r.marks.filter { $0.offset < r.window.end }
                if let s = r.liveStart, s >= r.window.end { r.liveStart = nil }
                changed = true
            }
        }
        if beforeCount > 0 {
            let middle = data.startIndex + beforeCount / 2
            if let nl = data[middle..<anchor].firstIndex(of: 0x0a) ?? (data[anchor - 1] == 0x0a ? anchor - 1 : nil) {
                let dropped = data[data.startIndex...nl]
                r.startLine = r.startLine.map { $0 + dropped.reduce(0) { $0 + ($1 == 0x0a ? 1 : 0) } }
                r.startsInAlternate = alternateScreen(in: dropped, from: r.startsInAlternate)
                r.start += dropped.count
                r.window.start = r.start
                data = data[(nl + 1)...]
                anchor = r.anchor - r.start + data.startIndex
                r.marks = r.marks.filter { $0.offset >= r.start }
                if let s = r.liveStart, s < r.start { r.liveStart = nil }
                changed = true
            }
        }
        r.data = Data(data)
        return changed
    }

    /// Whether a full-screen program's screen is up at reader position `offset`: the last switch to
    /// or from it in the output before (within a few megabytes).
    nonisolated private static func alternateScreen(at offset: Int, snap: RecordingSnapshot) -> Bool {
        guard offset > 0 else { return false }
        return alternateScreen(in: snap.bytes(from: max(offset - (4 << 20), 0), to: offset), from: false)
    }

    /// Whether a full-screen program's screen is up after `before`, given whether it was before it.
    nonisolated private static func alternateScreen(in before: Data, from: Bool) -> Bool {
        var on = from, i = before.startIndex
        let enters = ["\u{1b}[?1049h", "\u{1b}[?1047h", "\u{1b}[?47h"].map { Array($0.utf8) }
        let leaves = ["\u{1b}[?1049l", "\u{1b}[?1047l", "\u{1b}[?47l"].map { Array($0.utf8) }
        while let esc = before[i...].firstIndex(of: 0x1b) {
            let rest = before[esc...]
            if enters.contains(where: { rest.starts(with: $0) }) { on = true } else if leaves.contains(where: { rest.starts(with: $0) }) { on = false }
            i = esc + 1
        }
        return on
    }

    /// The index's commands within a window, in reader positions.
    nonisolated private static func marks(_ index: RecordingIndex?, base: Int, in range: Range<Int>) -> [RecordingIndex.Mark] {
        guard let index, index.isExact else { return [] }
        return index.marks.compactMap { m in
            var m = m
            m.offset -= base
            m.at -= base
            return range.contains(m.offset) ? m : nil
        }
    }

    /// What the window replayed (to find where a position is in it).
    private var replayed = Data()
    /// Positions of the part shown (reader positions, in order) and the scroll-invariant row the
    /// cursor was on when the output reached each, as the replay worked them out: every
    /// `cutSpacing` bytes, and exactly at the find's matches and the commands.
    private var offsetRows: [(offset: Int, row: Int)] = []
    /// A place in the text of the recording, found again in any part read that holds it: rows
    /// below where the output was at position `cut` (one noted in every part: a multiple of
    /// `cutSpacing`, or another position noted in both), and the column.
    struct Place: Equatable {
        var cut: Int
        var rows: Int
        var column: Int
    }

    /// The place of scroll-invariant row `row`, column `column`, in the part shown.
    func place(ofRow row: Int, column: Int) -> Place? {
        // A position every part notes (a multiple of `cutSpacing`) with its row nearest — not one
        // just after where the part starts: output redrawn in place, cut there, is laid out
        // otherwise than in a part that starts before it.
        let settled = (shown?.start ?? 0) == 0 ? 0 : (shown?.start ?? 0) + 2 * Self.cutSpacing
        let regular = Set(stride(from: settled - settled % Self.cutSpacing + Self.cutSpacing, to: shown?.end ?? 0, by: Self.cutSpacing)
            .compactMap { snapped($0) })
        let candidates = offsetRows.filter { regular.contains($0.offset) && $0.offset >= settled }
        guard let near = candidates.min(by: { abs($0.row - row) < abs($1.row - row) }) else { return nil }
        return Place(cut: near.offset, rows: row - near.row, column: column)
    }

    /// The scroll-invariant row of `place`, when the part shown holds it.
    func row(of place: Place) -> Int? {
        guard knowsRow(atOffset: place.cut), let i = Self.lastIndex(in: offsetRows, atOrBefore: place.cut) else { return nil }
        let row = offsetRows[i].row + place.rows
        return getTerminal().getScrollInvariantLine(row: row) != nil ? row : nil
    }

    /// The scroll-invariant row where the live terminal's first line is, when the part reaches it.
    var seamRow: Int? { liveTop?.row }

    /// The buffer row where the output was at position `offset` (a reader position) — exactly at
    /// a position noted (`offsetRows`), else at the last one before it — when the part shown
    /// holds it. Counting line breaks would not do: output redrawn in place has many more of them
    /// than the rows it left.
    func row(atOffset offset: Int) -> Int? {
        guard !loading, let shown, offset >= shown.start, offset < shown.end,
              let i = Self.lastIndex(in: offsetRows, atOrBefore: offset) else { return nil }
        let row = offsetRows[i].row - getTerminal().buffer.totalLinesTrimmed
        return row >= 0 ? row : nil
    }

    /// Whether the row of position `offset` is known exactly (not only of one before it).
    func knowsRow(atOffset offset: Int) -> Bool {
        Self.lastIndex(in: offsetRows, atOrBefore: offset).map { offsetRows[$0].offset == offset } ?? false
    }

    /// The index of the last position at or before `offset` (positions in order).
    nonisolated static func lastIndex(in places: [(offset: Int, row: Int)], atOrBefore offset: Int) -> Int? {
        var lo = 0, hi = places.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if places[mid].offset <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? lo - 1 : nil
    }

    /// The recording position (reader position) where the line at the top of the view starts,
    /// about: lines counted as `row(atOffset:)` does.
    var offsetAtTop: Int? {
        guard !loading, let shown else { return nil }
        // The last position noted whose row is at or above the top of the view.
        let top = topInvariantRow
        return offsetRows.last { $0.row <= top }?.offset ?? shown.start
    }

    /// The session line number of the first line replayed (nil when not known: no index).
    private(set) var firstLine: Int?
    /// The session line number at the top of the view (`sessionLine(ofRow:)`; else about, rows
    /// taken as lines).
    var topLine: Int? {
        sessionLine(ofRow: topInvariantRow).map { Int($0) }
            ?? firstLine.map { $0 + Int(Double(topInvariantRow - firstRowInvariant) / rowsPerLine) }
    }

    /// Lines of the session the screen shows (by `sessionLine(ofRow:)`).
    var visibleLines: Int? {
        guard let top = sessionLine(ofRow: topInvariantRow), let bottom = sessionLine(ofRow: topInvariantRow + getTerminal().rows) else { return nil }
        return max(Int(bottom - top), 1)
    }

    /// Rows of the part shown and the session line (the recording's index: line breaks) the output
    /// was at when it first reached each — the scale the scroller and the find's marks use. Output
    /// redrawn in place has many more line breaks than rows, so rows are not lines there.
    private var rowLines: [(row: Int, line: Double)] = []

    private func noteRowLines() {
        guard let index = live.historyIndex?(), index.isExact, !index.checkpoints.isEmpty else { rowLines = []; return }
        var out: [(row: Int, line: Double)] = []
        var highest = -Double.infinity
        for o in offsetRows.sorted(by: { ($0.row, $0.offset) < ($1.row, $1.offset) }) {
            // Never back: a row lower down is not an earlier line.
            let line = max(index.line(near: o.offset + indexBase), highest)
            highest = line
            if out.last?.row == o.row { continue }
            out.append((o.row, line))
        }
        rowLines = out
    }

    /// The session line of scroll-invariant row `row` (between noted rows, in proportion).
    func sessionLine(ofRow row: Int) -> Double? {
        guard let first = rowLines.first, let last = rowLines.last else { return nil }
        if row <= first.row { return first.line }
        if row >= last.row { return last.line + Double(row - last.row) / rowsPerLine }
        var lo = 0, hi = rowLines.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if rowLines[mid].row <= row { lo = mid } else { hi = mid }
        }
        let a = rowLines[lo], b = rowLines[hi]
        return a.line + (b.line - a.line) * Double(row - a.row) / Double(max(b.row - a.row, 1))
    }

    /// The scroll-invariant row where session line `line` is, when the part shown holds it.
    func row(ofSessionLine line: Double) -> Int? {
        guard let first = rowLines.first, let last = rowLines.last, line >= first.line, line <= last.line else { return nil }
        var lo = 0, hi = rowLines.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if rowLines[mid].line <= line { lo = mid } else { hi = mid }
        }
        let a = rowLines[lo], b = rowLines[hi]
        guard b.line > a.line else { return a.row }
        return a.row + Int((Double(b.row - a.row) * (line - a.line) / (b.line - a.line)).rounded(.down))
    }

    /// The scroll-invariant row of the first line replayed.
    private var firstRowInvariant = 0
    var firstRow: Int { firstRowInvariant }
    /// The row of the line a load kept or showed.
    private(set) var anchorRow = 0

    /// Puts `r` in: its rows are drawn a slice at a time (never holding the main thread long),
    /// while what was shown stays on screen; then the view is placed. `done` says whether it is in.
    private func apply(_ r: Replay, placement: Placement, partlyShownRows: Int? = nil, done: @escaping (Bool) -> Void = { _ in }) {
        notePlaced()
        var placement = placement
        if case .keepView(let up) = placement {
            placement = .keep(offsetFromAnchor: up ? topInvariantRow - firstRowInvariant : topInvariantRow - cursorInvariantRow)
            keptRows = rowsText(at: topInvariantRow, count: 4)
        } else {
            keptRows = nil
        }
        let t = getTerminal()
        guard !r.data.isEmpty, let c = r.compacted else { giveUp(); done(false); return }
        t.resetToInitialState()
        t.changeScrollback(live.historyWindowLines + live.historyWindowLines / 4)
        feeding = true
        resizedWhileFeeding = false
        holdingDisplay = true
        let resolved = placement
        feedSlices(ImageSequenceFilter.filtered(c.bytes), from: 0) { [weak self] in
            guard let self else { return }
            // The view got another size while the rows were drawn: they (and where the rows of
            // interest are) are worked out again for it, the old frame still showing meanwhile.
            if r.shape != self.shape || self.resizedWhileFeeding {
                self.resizedWhileFeeding = false
                // (Prepared again even for the same shape: a width there and back rewrapped, and
                // may have dropped, the rows half drawn.)
                var stale = r
                stale.shape = nil
                self.whenCurrent(stale) { [weak self] again in
                    self?.feeding = false
                    self?.holdingDisplay = false
                    self?.apply(again, placement: resolved, partlyShownRows: partlyShownRows, done: done)
                }
                return
            }
            self.feed(byteArray: Array("\u{1b}[?25l".utf8)[...])
            self.feeding = false
            self.holdingDisplay = false
            self.setNeedsDisplay(self.bounds)
            let placed = self.place(r, c, placement: resolved, partlyShownRows: partlyShownRows)
            // Wheel steps taken while the rows were drawn go on from where the view now is.
            let held = self.heldWheel
            self.heldWheel = []
            if placed, case .keep = resolved { for event in held { self.scrollWheel(with: event) } }
            done(placed)
        }
    }

    /// The most the main thread is held at a time while rows are drawn.
    nonisolated(unsafe) static var sliceTime: TimeInterval = 0.03

    private func feedSlices(_ bytes: [UInt8], from start: Int, then: @escaping () -> Void) {
        let began = ProcessInfo.processInfo.systemUptime
        var at = start
        while at < bytes.count, ProcessInfo.processInfo.systemUptime - began < Self.sliceTime {
            let end = min(at + 16 * 1024, bytes.count)
            feed(byteArray: bytes[at..<end])
            at = end
        }
        if at >= bytes.count { then(); return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.owner != nil else { return }
            self.feedSlices(bytes, from: at, then: then)
        }
    }

    /// While a part's rows are drawn: nothing is shown of them (what was shown stays) until all are in.
    private var holdingDisplay = false

    private func place(_ r: Replay, _ c: ReplayCompactor.Result, placement: Placement, partlyShownRows: Int?) -> Bool {
        let t = getTerminal()
        loading = false
        notePlaced()
        // Worked out off the main thread (`prepare`): the rows of interest (the line kept in view,
        // the live terminal's first line, commands) are where it found them.
        var rows: [Int: Int] = [r.start: 0]
        for (k, v) in c.rows { rows[k] = v }

        shown = r.window
        total = r.total
        firstLine = r.startLine
        replayed = r.data
        firstRowInvariant = 0
        replayedLines = r.data.reduce(0) { $0 + ($1 == 0x0a ? 1 : 0) }
        anchorRow = rows[r.anchor] ?? 0
        seamMatched = false
        liveTop = r.liveStart.flatMap { s in rows[s].map { (alignedSeam(near: $0), live.linesDropped) } }
        if let s = r.liveStart, s == r.anchor, let seam = liveTop?.row { anchorRow = seam }
        // Each on the line the cursor was on when Return was pressed (its first row), as the live
        // terminal marks it — not where the last line break before it was (a program's footer
        // below the line typed on, a line redrawn in place).
        // Return pressed where nothing was before the cursor (no prompt, nothing typed: Return
        // pressed while a program's output went on) ran no command.
        // (Marks with a column were made by this version, which marks no such Return.)
        func ranNothing(_ m: RecordingIndex.Mark) -> Bool { m.column == nil && c.columns[m.at] == 0 }
        skippedMarks = Set(r.marks.filter(ranNothing).map(\.offset))
        commands = r.marks.compactMap { m in
            if ranNothing(m) { return nil }
            return (rows[m.at].map { lineStart(at: $0, linesUp: m.up) } ?? rows[m.offset]).map { ($0, m) }
        }
        offsetRows = rows.sorted { $0.key < $1.key }.map { (offset: $0.key, row: $0.value) }
        noteRowLines()
        indexBase = r.base
        let trimmed = t.buffer.totalLinesTrimmed
        switch placement {
        case .keep(var offset):
            if let shownRows = partlyShownRows, !seamMatched {
                // The live terminal showed only the last rows of its first line: so does this.
                var rows = 1
                while let line = t.getScrollInvariantLine(row: anchorRow + rows), line.isWrapped { rows += 1 }
                offset += max(rows - shownRows, 0)
            }
            scrollTo(row: max(anchorRow - trimmed + offset, 0))
            // Worked out from where the part ended (the cursor): a program that redrew in place
            // there (a coding agent's status block) leaves the cursor rows away from it, and the
            // view would jump. The rows that were at the top are found again nearby, exactly.
            if let kept = keptRows, let row = Self.nearest(kept, around: topInvariantRow, in: self) { scrollTo(row: row - trimmed) }
        case .keepView: break   // resolved above
        case .show: scrollTo(row: max(anchorRow - trimmed - t.rows / 3, 0))
        case .top: scrollTo(row: max(anchorRow - trimmed, 0))
        }
        if prefetching, case .keep = placement {
            let up = topInvariantRow - trimmed < prefetchMargin
            let down = bufferRows - t.rows - t.buffer.yDisp < prefetchMargin
            if up { prefetchGainsLittle.insert(true) }
            if down { prefetchGainsLittle.insert(false) }
        }
        prefetching = false
        // The scroll held while feeding is reported once the new window is in place (with the old
        // one's seam it could take the view straight back to the live terminal).
        if scrolledWhileFeeding {
            scrolledWhileFeeding = false
            super.scrolled(source: t, yDisp: t.buffer.yDisp)
        }
        selection.selectNone()
        live.historyWindowChanged()
        onLoaded?(true)
        return true
    }

    private func giveUp() {
        guard owner != nil else { return }
        loading = false
        retryAfter = ProcessInfo.processInfo.systemUptime + 1
        live.historyLoadFailed()
        onLoaded?(false)
    }

    /// When Tether last placed the view itself (system uptime).
    private var placedAt: TimeInterval = 0
    func notePlaced() { placedAt = ProcessInfo.processInfo.systemUptime }

    /// SwiftTerm reports a scroll per line scrolled: during a replay they are held, and the last
    /// position is reported once (a window of tens of thousands of rows would otherwise update the
    /// scroller and the edges that many times).
    private(set) var feeding = false
    private var scrolledWhileFeeding = false
    /// The width changed while a part was drawn (see `apply`).
    private var resizedWhileFeeding = false

    /// Wheel steps while a part is drawn: the buffer is not the one shown then (the last frame is).
    private var heldWheel: [NSEvent] = []

    /// A wheel step for this view: held (true) while a part is drawn (see `TetherTerminalView.watchWheel`).
    func holdsWheel(_ event: NSEvent) -> Bool {
        guard feeding else { return false }
        if heldWheel.count < 64 { heldWheel.append(event) }
        return true
    }

    override func scrolled(source terminal: Terminal, yDisp: Int) {
        if feeding { scrolledWhileFeeding = true; return }
        super.scrolled(source: terminal, yDisp: yDisp)
    }

    /// The text of the rows at the top of the view when a part was asked for (see `place`).
    private var keptRows: [String]?

    private func rowsText(at row: Int, count: Int) -> [String] {
        let t = getTerminal()
        return (0..<count).compactMap { t.getScrollInvariantLine(row: row + $0)?.translateToString(trimRight: true) }
    }

    /// The scroll-invariant row nearest `row` (within 400) where `rows` are, row for row; nil when
    /// they are not there, or say too little to be sure (mostly empty).
    static func nearest(_ rows: [String], around row: Int, in view: HistoryTerminalView) -> Int? {
        guard rows.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).count >= 2 else { return nil }
        let t = view.getTerminal()
        func matches(_ r: Int) -> Bool {
            guard r >= t.buffer.totalLinesTrimmed else { return false }
            for (k, text) in rows.enumerated() {
                guard let line = t.getScrollInvariantLine(row: r + k), line.translateToString(trimRight: true) == text else { return false }
            }
            return true
        }
        if matches(row) { return nil }      // already there
        for d in 1...400 {
            if matches(row - d) { return row - d }
            if matches(row + d) { return row + d }
        }
        return nil
    }

    /// The seam found by counting line breaks can be off where output redrew lines in place
    /// (progress bars, prompts redrawn with cursor moves): it is checked against the live
    /// terminal's first rows, and moved to where they really are nearby.
    /// The last seam was found by the live terminal's rows themselves (exact, row for row).
    private var seamMatched = false

    private func alignedSeam(near row: Int) -> Int {
        let liveRows = live.firstRowsText(6)
        guard liveRows.contains(where: { !$0.isEmpty }) else { return row }
        let t = getTerminal()
        func matches(at r: Int) -> Bool {
            for (k, text) in liveRows.enumerated() {
                guard let line = t.getScrollInvariantLine(row: r + k), line.translateToString(trimRight: true) == text else { return false }
            }
            return true
        }
        seamMatched = true
        if matches(at: row) { return row }
        for d in 1...600 {
            if matches(at: row - d) { return row - d }
            if matches(at: row + d) { return row + d }
        }
        seamMatched = false
        return row
    }

    /// Still holds the seam with the live terminal as it is now (nothing dropped from its top
    /// since): showing it again needs no reading.
    func reaches(liveTop dropped: Int) -> Bool {
        guard !loading, let liveTop else { return false }
        return liveTop.liveDropped == dropped
    }

    /// Shown again at the seam: the live terminal's line at `offset` rows from its top at the top.
    func showLiveTop(offset: Int) {
        guard let liveTop else { return }
        scrollTo(row: max(liveTop.row - getTerminal().buffer.totalLinesTrimmed + offset, 0))
    }

    // MARK: Scrolling

    /// Scrolled to within a few screens of the window's top or bottom: the next part is read now,
    /// while there is still something to scroll through, rather than once the edge is reached.
    private func prefetchIfNear() {
        // Not while text is selected or being selected: putting the part in would take the
        // selection away (it is read at the edge then, as the user goes there).
        guard let shown, !selection.active, NSEvent.pressedMouseButtons == 0 else { return }
        let t = getTerminal()
        if shown.start > 0, t.buffer.yDisp < prefetchMargin, !prefetchGainsLittle.contains(true) {
            prefetching = true
            slide(up: true)
        } else if shown.end < total, bufferRows - t.rows - t.buffer.yDisp < prefetchMargin, liveTop == nil,
                  !prefetchGainsLittle.contains(false) {
            prefetching = true
            slide(up: false)
        }
    }

    private var prefetchMargin: Int { max(getTerminal().rows * 6, 150) }
    /// A part read ahead that left the view still near the edge (output of mostly redraws gives
    /// few rows): in that direction the next part is read at the edge only, not again and again.
    private var prefetchGainsLittle: Set<Bool> = []
    private var prefetching = false

    /// At the top: earlier output. At the bottom: later output, or the live terminal again once the
    /// view reaches what it shows. Asked again for every step past an edge (the wheel watcher), so
    /// a load that could not start then starts as soon as it can.
    func request(up: Bool) {
        guard !queued, !loading, shown != nil else { return }
        prefetchGainsLittle.remove(up)
        let t = getTerminal()
        if up { guard t.buffer.yDisp == 0, (shown?.start ?? 0) > 0 else { return } }
        else {
            if leaveIfLiveReached() { return }
            guard atBottom else { return }
        }
        queued = true
        let wait = NSEvent.pressedMouseButtons != 0 ? 0.25 : max(0, retryAfter - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.queued = false
            if NSEvent.pressedMouseButtons != 0 || ProcessInfo.processInfo.systemUptime < self.retryAfter {
                self.request(up: up)
                return
            }
            if !up, self.leaveIfLiveReached() { return }
            // Still at that edge (a load meanwhile may have moved the view away from it).
            if up ? self.getTerminal().buffer.yDisp != 0 : !self.atBottom { return }
            self.slide(up: up)
        }
    }

    /// The view reached the live terminal's first line (or the end of everything recorded): the live
    /// terminal takes over at the same place. True if it did.
    @discardableResult
    func leaveIfLiveReached() -> Bool {
        guard let shown else { return false }
        if let liveTop {
            // Lines the live terminal dropped since: they are no longer at its top.
            // Past the seam by a row: scrolling down there goes on in the live terminal.
            let liveRow = topInvariantRow - liveTop.row - (live.linesDropped - liveTop.liveDropped)
            if liveRow > 0 {
                live.leaveHistory(scrollTo: liveRow)
                return true
            }
        } else if shown.end >= total, atBottom {
            live.leaveHistory(scrollTo: nil)
            return true
        }
        return false
    }

    // MARK: TerminalViewDelegate

    func scrolled(source: TerminalView, position: Double) {
        live.historyScrolled()
        guard !loading else { return }
        // Tether just placed the view (a part shown, a match selected): being at an edge then is
        // not the user going on past it (the wheel and the scroller still ask for more).
        if ProcessInfo.processInfo.systemUptime - placedAt < 0.5 { return }
        if position <= 0.0001 { request(up: true) } else if position >= 0.9999 { request(up: false) } else if !leaveIfLiveReached() {
            prefetchIfNear()
        }
    }

    // Replayed output's queries, titles, folders, clipboard and bells are old: nothing is done.
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        live.requestOpenLink(source: live, link: link, params: params)
    }

    // MARK: Width

    /// Another width wraps long lines differently: the line at the top, the commands and the seam
    /// with the live terminal stay on their text.
    override func setFrameSize(_ newSize: NSSize) {
        // While a part is drawn the buffer is being replaced: `apply` makes it again for the new size.
        if feeding, newSize.width != frame.width { resizedWhileFeeding = true }
        guard newSize.width != frame.width, shown != nil, !feeding else { super.setFrameSize(newSize); return }
        let t = getTerminal()
        let trimmed = t.buffer.totalLinesTrimmed
        let rows = offsetRows.map { $0.row - trimmed } + commands.map { $0.row - trimmed }
            + [liveTop.map { $0.row - trimmed } ?? -1, anchorRow - trimmed, t.buffer.yDisp]
        let places = ReflowPlaces(self, rows: rows)
        let oldCols = t.cols
        // Narrower, the lines take more rows: room for all of them, so none is dropped from the top
        // (the line looked at with them). The text takes no more memory, only more rows.
        let room = (bufferRows + 1) * max(oldCols, 1) / 10 + t.rows
        if room > t.options.scrollback { t.changeScrollback(room) }
        super.setFrameSize(newSize)
        guard getTerminal().cols != oldCols else { return }
        let now = places.rows(in: self)
        let newTrimmed = getTerminal().buffer.totalLinesTrimmed
        let k = offsetRows.count
        offsetRows = zip(offsetRows, now.prefix(k)).compactMap { o, r in r.map { (o.offset, $0 + newTrimmed) } }
        noteRowLines()
        commands = zip(commands, now.dropFirst(k)).compactMap { c, r in r.map { ($0 + newTrimmed, c.mark) } }
        let n = rows.count
        if let top = liveTop { liveTop = now[n - 3].map { ($0 + newTrimmed, top.liveDropped) } }
        if let a = now[n - 2] { anchorRow = a + newTrimmed }
        if let top = now[n - 1] { scrollTo(row: top) }
        live.historyReflowed()
    }

    // MARK: Mouse and keys

    /// Selecting text here keeps the keyboard with the live terminal: typing goes there (and brings
    /// it back), ⌘C copies what is selected here (`TetherTerminalView.copy`).
    override func mouseDown(with event: NSEvent) {
        // While a part is drawn the last frame is shown, not the rows being drawn: a click there
        // would select other text.
        guard !feeding else { return }
        live.clearCommandSelection()
        super.mouseDown(with: event)
        if window?.firstResponder === self { window?.makeFirstResponder(live) }
    }

    /// The live terminal's menu (Copy reads the selection here, Paste types there).
    override func menu(for event: NSEvent) -> NSMenu? { live.editMenu() }

    override func mouseDragged(with event: NSEvent) {
        guard !feeding else { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if window?.firstResponder === self { window?.makeFirstResponder(live) }
        // Copy on select (Settings ▸ Terminal), as in the live terminal.
        if live.copiesOnSelect, selection.active, let text = getSelection(), !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
