import AppKit
import SwiftTerm
import TetherCore
import TerminalText
import RecordingKit
import SearchKit

/// What to find in a terminal.
public struct TerminalFindQuery: Equatable, Sendable {
    public var term: String
    public var isRegex = false
    public var caseSensitive = false
    public var wholeWord = false

    public init(term: String, isRegex: Bool = false, caseSensitive: Bool = false, wholeWord: Bool = false) {
        self.term = term
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
    }
}

/// Where a find stands, for the find bar ("3 of 14").
public struct TerminalFindStatus: Equatable, Sendable {
    /// 1-based position of the current match (0: none).
    public var current = 0
    public var total = 0
    /// More matches than `TerminalFindSession.limit` exist: `total` is a lower bound.
    public var limited = false
    public var invalidPattern = false
    /// Row of the current match within the history, 0…1 from the top (nil without one).
    public var position: Double?
    /// Earlier output (in the recording) is still being searched: more may come.
    public var searchingRecording = false
    /// How far that search is (0…1), once it has started reading.
    public var recordingProgress: Double?
    /// Some earlier output could not be read (Tether locked, or recorded with another key): not
    /// all of it was searched.
    public var recordingUnreadable = false
    public init() {}
}

/// A find running in one terminal view: its matches, the current one and the overlay.
final class TerminalFindSession {
    static let limit = 10_000

    var query: TerminalFindQuery
    var regex: NSRegularExpression?
    var matches: [BufferMatch] = []
    var current: Int?
    let overlay = FindOverlay()
    var rescanScheduled = false
    /// How long the last scan took, so busy output is scanned less often.
    var scanDuration: TimeInterval = 0
    /// How long the last look through everything took (typing waits for a pause when it is long).
    var fullScanDuration: TimeInterval = 0
    /// Rows from here on may have changed since the last scan (the screen's top then): only they
    /// are looked through again. nil: everything is.
    var changedFrom: Int?
    /// The line just above `changedFrom` at that scan: another one there now means the buffer was
    /// rebuilt (cleared, replayed), and everything is looked through again.
    weak var lineAboveChanged: BufferLine?
    var scannedColumns = 0
    var scannedRows = 0
    /// The last scan looked only at what may have changed (for tests).
    var lastScanWasPartial = false
    var scannedAlternate = false
    /// A changed term waits for typing to pause when looking through the buffer takes a while.
    var typing: DispatchWorkItem?

    /// Matches in the recording before what is in memory, oldest first: where they are (reader
    /// positions, within `SearchEngine.offsetPiece`) and as shares of the session for the scroller.
    struct Earlier {
        /// Where its line was finished (left the screen): its text is final by there.
        var offset: Int
        var share: CGFloat
        /// The line it is on and which match in that line, to find it in the history view.
        var line = ""
        var occurrence = 0
        /// Where its line's first row was made (its text was written there or after).
        var start = 0
        /// Stays the same while older matches are put in front (the recording is searched back).
        var id = 0
    }
    /// The next `Earlier.id`.
    var nextEarlierID = 0
    var earlier: [Earlier] = []
    /// The current match is `earlier[i]` (shown in the history view) rather than one in memory.
    var currentEarlier: Int?
    var earlierTask: Task<Void, Never>?
    var searchingEarlier = false
    /// How far that look is (0…1), when it has started reading.
    var earlierProgress: Double?
    /// Lines the terminal had dropped when the recording was searched (more dropped since: again,
    /// at most every `researchInterval`), and when that was.
    var earlierDropped = -1
    var earlierSearchedAt: TimeInterval = 0
    static let researchInterval: TimeInterval = 30
    /// The earlier match to go to once the recording is searched: at (or after) this position (a
    /// result opened from Search), or the first one from where the history view is (`fromView`).
    var pendingEarlier: (offset: Int?, fromView: Bool)?
    /// The earlier match asked for while another part of the recording was being read (its id).
    var queuedEarlier: Int?
    /// The match selected at once in the part of the recording on screen (`markMatchInView`): its
    /// line's text and which occurrence on it, and where the view's top was in the recording.
    var viewPick: (line: String, occurrence: Int, from: Int)?
    /// The match of the recording's last selected: which, where in the part shown, and that part.
    /// Where in the text it is (found again in any part of the recording that holds it).
    var lastEarlierPick: (id: Int, place: HistoryTerminalView.Place?)?

    /// The place in `earlier` of the match `id`.
    func earlierIndex(of id: Int) -> Int? { earlier.firstIndex { $0.id == id } }
    /// The current match, when it is the earlier one `id` (it may have moved in `earlier`).
    func currentEarlier(is id: Int) -> Int? {
        currentEarlier.flatMap { earlier.indices.contains($0) && earlier[$0].id == id ? $0 : nil }
    }
    /// Some of the recording could not be read (see `TerminalFindStatus.recordingUnreadable`).
    var recordingUnreadable = false
    /// A step asked for before any match was found (the recording still being searched): taken
    /// once the first one is (forwards or not).
    var waitingStep: Bool?

    init(query: TerminalFindQuery) { self.query = query }
}

extension TetherTerminalView {
    /// Starts, changes or (nil) ends the find. A new search starts at the match nearest the
    /// latest output on screen — or on `anchorRow` (scroll-invariant), e.g. a match picked in the
    /// search window; a changed term keeps the place of the current match where it can.
    /// `earlierOffset`: a match in the recording (a result opened from Search, at about that
    /// position) is to be the current one. Returns false when nothing changed (the same term).
    @discardableResult
    public func setFind(_ query: TerminalFindQuery?, anchorRow: Int? = nil, earlierOffset: Int? = nil) -> Bool {
        guard let query else {
            findSession?.typing?.cancel()
            findSession?.earlierTask?.cancel()
            findSession?.overlay.remove()
            findSession = nil
            notifyUpdateChanges = false
            reportFind()
            return true
        }
        if let s = findSession, s.query == query, anchorRow == nil, earlierOffset == nil {
            drawFind()
            reportFind()
            return false
        }
        let previous = findSession.flatMap { s in s.current.map { s.matches[$0] } }
        let session = findSession ?? TerminalFindSession(query: query)
        let slow = findSession != nil && session.fullScanDuration > 0.03
        session.query = query
        findSession = session
        notifyUpdateChanges = true
        session.typing?.cancel()
        session.typing = nil
        // A long scrollback takes a moment to look through: while the term is being typed it is
        // looked through once typing pauses, not for every letter.
        if slow, anchorRow == nil, earlierOffset == nil {
            let work = DispatchWorkItem { [weak self, weak session] in
                guard let self, let session, self.findSession === session, session.query == query else { return }
                session.typing = nil
                self.applyFind(session, previous: previous, anchorRow: nil, earlierOffset: nil)
            }
            session.typing = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            return true
        }
        applyFind(session, previous: previous, anchorRow: anchorRow, earlierOffset: earlierOffset)
        return true
    }

    private func applyFind(_ session: TerminalFindSession, previous: BufferMatch?, anchorRow: Int?, earlierOffset: Int?) {
        let query = session.query
        session.regex = query.term.isEmpty ? nil
            : try? BufferSearch.regex(query.term, isRegex: query.isRegex, caseSensitive: query.caseSensitive, wholeWord: query.wholeWord)
        scanFind(everything: true)
        session.currentEarlier = nil
        history?.selection.selectNone()
        // A result in the recording, or the term changed while browsing it: the place there is kept
        // (the match is picked once the recording is searched).
        if let earlierOffset {
            session.pendingEarlier = (earlierOffset, false)
        } else if isBrowsingHistory {
            session.pendingEarlier = (nil, true)
        } else {
            session.pendingEarlier = nil
        }
        searchRecordingForFind(restart: true)
        if session.pendingEarlier != nil {
            session.current = nil
            reportFind()
            drawFind()
            // Browsing: what the view shows is looked through at once (the recording's search can
            // take a while), from the top of the view.
            if session.pendingEarlier?.fromView == true { markMatchInView(session) }
            return
        }

        let m = session.matches
        if m.isEmpty {
            session.current = nil
        } else if let anchorRow {
            session.current = m.firstIndex { $0.rows.contains(anchorRow) } ?? min(FindOverlay.firstIndex(in: m, atOrAfter: anchorRow), m.count - 1)
        } else if let previous {
            let i = FindOverlay.firstIndex(in: m, atOrAfter: previous.row)
            session.current = m.indices.contains(i) ? i : m.count - 1
        } else {
            // The first match on screen, from the top (↩ / ⌘G then goes on downwards to the next
            // one there); with none on screen, the nearest one above it (the most recent output
            // before what is shown), else the first below.
            let top = findGeometry.topRow
            let bottom = top + getTerminal().rows
            let onScreen = FindOverlay.firstIndex(in: m, atOrAfter: top)
            if m.indices.contains(onScreen), m[onScreen].row < bottom {
                session.current = onScreen
            } else {
                session.current = onScreen > 0 ? onScreen - 1 : min(onScreen, m.count - 1)
            }
        }
        // Typing more of the term usually keeps the same match: it is shown again only when the
        // find lands somewhere else.
        let landed = session.current.map { m[$0].row }
        revealCurrentMatch(announce: landed != nil && landed != previous?.row)
    }

    /// ⌘G / ⇧⌘G: the next or previous match, round the end.
    /// Matches in the recording come first (the oldest output), then those in memory.
    public func findStep(forward: Bool) {
        flushPendingFind()
        guard let s = findSession else { NSSound.beep(); return }
        if s.matches.isEmpty && s.earlier.isEmpty {
            // Still looking through the recording: the step is taken when a match turns up.
            if s.searchingEarlier { s.waitingStep = forward } else { NSSound.beep() }
            return
        }
        s.waitingStep = nil
        let e = s.earlier.count, n = s.matches.count
        let all = e + n
        let position = s.currentEarlier ?? s.current.map { e + $0 }
        // Nothing current yet: forwards from the first match in memory, backwards from the newest;
        // with none in memory, the newest of the recording's (nearest; it is searched from its end).
        let next = position.map { ($0 + (forward ? 1 : -1) + all) % all } ?? (forward && n > 0 ? e : all - 1)
        if next < e {
            showEarlierMatch(next, fromMemory: position.map { $0 >= e } ?? true, forward: forward)
            return
        }
        s.currentEarlier = nil
        s.lastEarlierPick = nil
        s.current = next - e
        if isBrowsingHistory { returnToLive() }
        revealCurrentMatch(announce: true)
    }

    /// A term still waiting for typing to pause, or output not looked through yet: done now, so a
    /// step goes on from the matches of the term shown (a deferred look would otherwise put the
    /// current match back where it was and the step was lost).
    private func flushPendingFind() {
        guard let s = findSession else { return }
        if let typing = s.typing {
            typing.cancel()
            s.typing = nil
            applyFind(s, previous: s.current.map { s.matches[$0] }, anchorRow: nil, earlierOffset: nil)
        } else if s.rescanScheduled, s.regex != nil, s.currentEarlier == nil, s.pendingEarlier == nil {
            let previous = s.current.map { s.matches[$0] }
            scanFind()
            if let previous, !s.matches.isEmpty {
                let i = FindOverlay.firstIndex(in: s.matches, atOrAfter: previous.row)
                s.current = s.matches.firstIndex(of: previous) ?? (s.matches.indices.contains(i) ? i : s.matches.count - 1)
            } else {
                s.current = s.matches.isEmpty ? nil : s.matches.count - 1
            }
        }
    }

    /// Searches the recording for what is no longer in memory, in the background, a moment after
    /// the term was typed (not for every letter). `restart`: the term changed; otherwise only when
    /// more lines left memory since, and at most every `researchInterval`.
    func searchRecordingForFind(restart: Bool) {
        guard let s = findSession else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if !restart {
            guard !s.searchingEarlier, s.earlierDropped != linesDropped,
                  now - s.earlierSearchedAt >= TerminalFindSession.researchInterval else { return }
        }
        s.earlierTask?.cancel()
        if restart { s.earlier = []; s.currentEarlier = nil; s.lastEarlierPick = nil; s.waitingStep = nil; s.recordingUnreadable = false }
        guard let regex = s.regex, hasOlderOutput, hasHistoryOnDisk, let reader = historyReader else {
            s.searchingEarlier = false
            applyPendingEarlier()
            return
        }
        s.searchingEarlier = true
        s.earlierProgress = nil
        s.earlierDropped = linesDropped
        let index = exactIndex
        let term = s.query
        s.earlierTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(restart ? 350 : 0))
            guard !Task.isCancelled, let self else { return }
            // Where memory starts in the recording is found by its first lines, as Search does.
            let (skip, head) = self.memoryLinesForFind()
            // The recording made current; the search itself is a child task, so it stops when
            // this one is cancelled (a new term, the find bar closed).
            let target: RecordingSnapshot? = await withCheckedContinuation { done in
                if !reader({ done.resume(returning: $0) }) { done.resume(returning: nil) }
            }
            guard let snap = target, !Task.isCancelled else { return }
            let found: [TerminalFindSession.Earlier] = await withTaskGroup(of: [TerminalFindSession.Earlier].self) { group in
                group.addTask { [weak self] in
                    let base = index.map { $0.partLengths.isEmpty ? 0 : $0.removedLength(firstPart: RecordingParts.parts(of: snap.url).first?.number) } ?? 0
                    let lines = max((index?.lines ?? 0) + 1, 1)
                    func earlier(_ found: [FoundLine]) -> [TerminalFindSession.Earlier] {
                        var all: [TerminalFindSession.Earlier] = []
                        for m in found {
                            // On the scroller where its line was written.
                            let share: CGFloat = index.map { CGFloat($0.line(near: m.start + base)) / CGFloat(lines) }
                                ?? CGFloat(m.start) / CGFloat(max(snap.length, 1))
                            // One per occurrence (a line can hold several), as in memory.
                            for n in m.ranges.indices {
                                all.append(.init(offset: m.end, share: share, line: String(TetherTerminalView.lineKey(m.text)), occurrence: n, start: m.start))
                            }
                        }
                        return all
                    }
                    // From the end back: the matches nearest memory come first, put in front of
                    // those shown (counted, marked and stepped to before the search ends).
                    var all: [TerminalFindSession.Earlier] = []
                    let complete = (try? SearchEngine.findBackward(read: { snap.bytes(from: $0, to: $1) }, length: snap.length, regex: regex,
                                                   memoryLines: skip, memoryHead: head, limit: TerminalFindSession.limit,
                                                   progress: { share in Task { @MainActor in self?.noteRecordingSearched(share, term: term) } }) { batch in
                        let older = earlier(batch)
                        all = older + all
                        if restart { Task { @MainActor in self?.noteEarlierBatch(older, term: term) } }
                        return !Task.isCancelled
                    }) ?? true
                    if !complete { Task { @MainActor in self?.noteRecordingUnreadable(term: term) } }
                    return Array(all.suffix(TerminalFindSession.limit))
                }
                return await group.next() ?? []
            }
            guard !Task.isCancelled, let s = self.findSession, s.query == term else { return }
            s.searchingEarlier = false
            s.earlierProgress = nil
            s.earlierSearchedAt = ProcessInfo.processInfo.systemUptime
            self.settleEarlier(found)
            self.applyPendingEarlier()
            self.drawFind()
            self.reportFind()
            if let forward = s.waitingStep {
                s.waitingStep = nil
                if !found.isEmpty || !s.matches.isEmpty { self.findStep(forward: forward) } else { NSSound.beep() }
            }
        }
    }

    /// Positions in the recording the history view is to know the rows of: where each match's
    /// piece of output starts and ends.
    func findCutOffsets() -> [Int] {
        guard let s = findSession, !s.earlier.isEmpty else { return [] }
        var cuts = Set<Int>()
        for e in s.earlier {
            cuts.insert(e.offset)
            cuts.insert(e.start)
        }
        return Array(cuts)
    }

    /// What identifies a line for finding it again: its text without trailing blanks, at most
    /// 400 characters (ten thousand matches keep it).
    nonisolated static func lineKey(_ s: String) -> Substring {
        var t = Substring(s)
        while let c = t.last, c == " " || c == "\t" || c == "\0" { t = t.dropLast() }
        return t.prefix(400)
    }

    /// Matches found in the recording, older than those found before (it is searched from its
    /// end back): put in front, counted and marked at once, and ⌘G reaches them while the rest is
    /// still being looked for. What points into the list moves with it.
    func noteEarlierBatch(_ older: [TerminalFindSession.Earlier], term: TerminalFindQuery) {
        guard let s = findSession, s.query == term, s.searchingEarlier, !older.isEmpty else { return }
        var older = older
        for k in older.indices { older[k].id = s.nextEarlierID; s.nextEarlierID += 1 }
        s.earlier = older + s.earlier
        if let c = s.currentEarlier { s.currentEarlier = c + older.count }
        drawFind()
        reportFind()
        if let forward = s.waitingStep { findStep(forward: forward) }
    }

    /// The search of the recording ended with `found` (oldest first): the list shown becomes it,
    /// keeping the ids (and so the current match) of those already shown.
    private func settleEarlier(_ found: [TerminalFindSession.Earlier]) {
        guard let s = findSession else { return }
        func key(_ e: TerminalFindSession.Earlier) -> String { "\(e.start)|\(e.offset)|\(e.occurrence)|\(e.line)" }
        var known: [String: [Int]] = [:]
        for e in s.earlier { known[key(e), default: []].append(e.id) }
        let currentID = s.currentEarlier.flatMap { s.earlier.indices.contains($0) ? s.earlier[$0].id : nil }
        let currentStart = s.currentEarlier.flatMap { s.earlier.indices.contains($0) ? s.earlier[$0].start : nil }
        var settled = found
        for k in settled.indices {
            if var ids = known[key(settled[k])], !ids.isEmpty {
                settled[k].id = ids.removeFirst()
                known[key(settled[k])] = ids
            } else {
                settled[k].id = s.nextEarlierID
                s.nextEarlierID += 1
            }
        }
        s.earlier = settled
        if let currentID {
            s.currentEarlier = settled.firstIndex { $0.id == currentID } ?? currentStart.flatMap { start in settled.firstIndex { $0.start >= start } }
        }
    }

    /// Some of the recording could not be read while `term` was looked for there.
    func noteRecordingUnreadable(term: TerminalFindQuery) {
        guard let s = findSession, s.query == term else { return }
        s.recordingUnreadable = true
        reportFind()
    }

    /// How far the look into the recording for `term` is (0…1), for the find bar.
    func noteRecordingSearched(_ share: Double, term: TerminalFindQuery) {
        guard let s = findSession, s.query == term, s.searchingEarlier else { return }
        let percent = (share * 100).rounded(.down) / 100
        guard s.earlierProgress != percent else { return }
        s.earlierProgress = percent
        reportFind()
    }

    /// The recording is searched: the match a result or a change of term while browsing asked for.
    private func applyPendingEarlier() {
        guard let s = findSession, let pending = s.pendingEarlier else { return }
        s.pendingEarlier = nil
        var target: Int?
        if let offset = pending.offset {
            target = s.earlier.firstIndex { $0.offset >= offset } ?? s.earlier.indices.last
        } else if pending.fromView, let pick = s.viewPick,
                  let i = s.earlier.firstIndex(where: { $0.offset >= pick.from && $0.line == pick.line && $0.occurrence == pick.occurrence }) {
            // The one already selected on screen: it is the current one now, and stays where it is.
            s.viewPick = nil
            if isBrowsingHistory, let h = history, h.selection.active {
                s.lastEarlierPick = (s.earlier[i].id, h.place(ofRow: h.selection.start.row + h.getTerminal().buffer.totalLinesTrimmed, column: h.selection.start.col))
                s.currentEarlier = i
                s.current = nil
                reportFind()
                drawFind()
                return
            }
            target = i
        } else if pending.fromView, let h = history, let start = h.offsetAtTop ?? h.shown?.start {
            // From the top of the view (the line looked at).
            target = s.earlier.firstIndex { $0.offset >= start }
        }
        s.viewPick = nil
        if let target {
            showEarlierMatch(target)
        } else {
            // None there: the find goes on in memory, from the most recent output.
            if isBrowsingHistory, pending.offset == nil { returnToLive() }
            s.current = s.matches.isEmpty ? nil : s.matches.count - 1
            revealCurrentMatch(announce: false)
        }
    }

    /// The first match in what the history view holds, from the top of the view (else the last one
    /// above it): selected and shown, before the recording's search has said which one it is.
    private func markMatchInView(_ s: TerminalFindSession) {
        guard isBrowsingHistory, let h = history, !h.loading, let regex = s.regex else { return }
        let t = h.getTerminal()
        let found = BufferSearch.matches(in: t, regex: regex, limit: TerminalFindSession.limit)
        let trimmed = t.buffer.totalLinesTrimmed
        let top = t.buffer.yDisp + trimmed
        guard let m = found.first(where: { $0.row >= top }) ?? found.last,
              let first = m.segments.first, let last = m.segments.last else { return }
        // Remembered by its line, as the recording's matches are (see `applyPendingEarlier`).
        let lineStart = BufferSearch.lineStart(in: t, row: m.row)
        let occurrence = found.filter { BufferSearch.lineStart(in: t, row: $0.row) == lineStart && $0.row <= m.row }
            .firstIndex { $0.row == m.row && $0.segments.first?.columns == first.columns } ?? 0
        s.viewPick = (String(Self.lineKey(BufferSearch.lineText(in: t, row: lineStart))), occurrence, h.offsetAtTop ?? h.shown?.start ?? 0)
        h.selection.setSelection(start: Position(col: first.columns.lowerBound, row: first.row - trimmed),
                                 end: Position(col: last.columns.upperBound, row: last.row - trimmed))
        h.notePlaced()
        if !Self.inSight(m.rows, top: top, rows: t.rows, coveredAtTop: findBarCoveredRows) { h.scrollTo(row: max(m.row - trimmed - t.rows / 3, 0)) }
        h.flashRows((m.row - trimmed)...(m.rows.upperBound - trimmed))
    }

    /// Shows match `i` of the recording's in the history view, with the matched text selected:
    /// in place when the view holds that part, otherwise read (after a read under way).
    /// `fromMemory`: the step came from memory (or from no match), backwards (`forward` false: the
    /// last match above where memory starts) or round to the recording's first match.
    func showEarlierMatch(_ i: Int, fromMemory: Bool = false, forward: Bool = true) {
        guard let s = findSession, s.earlier.indices.contains(i), let regex = s.regex else { return }
        let target = s.earlier[i]
        let offset = target.offset, id = target.id
        // Matches whose lines were made in the same piece of output, up to this one.
        let piece = s.earlier[(s.earlier.firstIndex { $0.start == target.start } ?? i)...i]
        // Which of the matches in the same piece this is, and which of the lines with its text there.
        let nth = piece.count - 1
        let sameLine = piece.filter { $0.line == target.line && $0.occurrence == 0 }.count - (target.occurrence == 0 ? 1 : 0)
        let last = s.lastEarlierPick
        s.currentEarlier = i
        s.current = nil
        s.queuedEarlier = nil
        reportFind()
        drawFind()
        if let h = history, isBrowsingHistory, h.loading { s.queuedEarlier = id; return }

        // One step from the match selected before: the next (previous) match in the text from it.
        // The recording's search knows a line only by the piece of output it left the screen in —
        // long after it was written where a program redrew below it — so places from it would
        // pick other lines with the same text, or the same ones again.
        if let last, let place = last.place, let lastIndex = s.earlierIndex(of: last.id), abs(lastIndex - i) == 1 {
            let forward = i > lastIndex
            if isBrowsingHistory, let h = history, let m = Self.neighbour(in: h, regex: regex, of: place, forward: forward) {
                showPick(m, in: h, index: i)
                return
            }
            // Not in the part shown: the part from there on is read, through the match; back, a
            // part reaching further back each time until it holds one (output redrawn in place
            // gives few rows for its lines).
            var span = Self.backSpan
            func read(at start: Int, through end: Int?) {
                let shown = showRecording(at: start, through: end) { [weak self] row in
                    guard let self, let h = self.history, let i = self.findSession?.currentEarlier(is: id) else { return }
                    // Whether the part read holds the match: a part holds only so many lines, and
                    // long output between two matches leaves it short of the next one.
                    let holds = h.shown.map { forward ? $0.end >= offset : $0.start <= target.start } ?? false
                    if let m = Self.neighbour(in: h, regex: regex, of: place, forward: forward) {
                        self.showPick(m, in: h, index: i)
                    } else if !forward, !holds, let first = h.shown?.start, first > 0, span < Self.backSpan << 6, h.row(of: place) != nil {
                        span *= 2
                        read(at: max(place.cut - span, 0), through: place.cut)
                    } else if holds, let m = self.pick(in: h, regex: regex, target: target, sameLine: sameLine, nth: nth, from: row) {
                        self.showPick(m, in: h, index: i)
                    } else if let s = self.findSession {
                        // Not in it: read from where its line was made (another line with the same
                        // text in the part read is not it).
                        s.lastEarlierPick = nil
                        self.showEarlierMatch(i)
                    }
                }
                if !shown { s.queuedEarlier = id }
            }
            if forward { read(at: place.cut, through: offset) } else { read(at: max(place.cut - span, 0), through: place.cut) }
            return
        }
        // From memory, back: the last match above where memory starts.
        // (The recording is searched from its end: the newest of its matches is known first.)
        if fromMemory, !forward, i == s.earlier.count - 1, !isBrowsingHistory,
           enterHistoryAtSeam(then: { [weak self] h in
               guard let self, let i = self.findSession?.currentEarlier(is: id) else { return }
               let found = BufferSearch.matches(in: h.getTerminal(), regex: regex, limit: TerminalFindSession.limit)
               let seam = h.seamRow ?? Int.max
               if let m = found.last(where: { $0.row < seam }) { self.showPick(m, in: h, index: i) } else { self.showEarlierMatch(i) }
           }) {
            return
        }
        // From where its line was made (round from the end: the recording's first match).
        let start = fromMemory && forward && i == 0 && !s.searchingEarlier ? 0 : target.start
        // The part shown holds it: no reading (the piece's row is where a cut was made).
        // (Read again when the part was drawn before the matches were known: their rows come
        // exactly with it then.)
        if isBrowsingHistory, let h = history, let cut = h.snapped(start), h.knowsRow(atOffset: cut), let row = h.row(atOffset: cut), let w = h.shown, w.end >= offset,
           let m = pick(in: h, regex: regex, target: target, sameLine: sameLine, nth: nth, from: row + h.getTerminal().buffer.totalLinesTrimmed) {
            showPick(m, in: h, index: i)
            return
        }
        let shown = showRecording(at: start, through: offset) { [weak self] row in
            guard let self, let h = self.history, let i = self.findSession?.currentEarlier(is: id) else { return }
            let first = start == 0 ? BufferSearch.matches(in: h.getTerminal(), regex: regex, limit: 1).first : nil
            if let m = first ?? self.pick(in: h, regex: regex, target: target, sameLine: sameLine, nth: nth, from: row) {
                self.showPick(m, in: h, index: i)
            }
        }
        if !shown { s.queuedEarlier = id }
    }

    /// How far back a part is read first for the previous match (bytes; doubled while it holds none).
    static let backSpan = 64 * 1024

    /// The match after (before) `place` in the history view, when the part shown holds the place.
    private static func neighbour(in h: HistoryTerminalView, regex: NSRegularExpression, of place: HistoryTerminalView.Place,
                                  forward: Bool) -> BufferMatch? {
        guard let row = h.row(of: place) else { return nil }
        let found = BufferSearch.matches(in: h.getTerminal(), regex: regex, limit: TerminalFindSession.limit)
        func at(_ x: BufferMatch) -> (Int, Int) { (x.row, x.segments.first?.columns.lowerBound ?? 0) }
        return forward ? found.first { at($0) > (row, place.column) } : found.last { at($0) < (row, place.column) }
    }

    /// A match of the recording's found about where its piece starts (scroll-invariant `row`):
    /// by its line's text — counting matches from where the piece starts goes wrong where a
    /// program moved the cursor around (a progress line, a full-screen chat redrawn).
    private func pick(in h: HistoryTerminalView, regex: NSRegularExpression, target: TerminalFindSession.Earlier,
                      sameLine: Int, nth: Int, from row: Int) -> BufferMatch? {
        let t = h.getTerminal()
        let found = BufferSearch.matches(in: t, regex: regex, limit: TerminalFindSession.limit)
        let want = Substring(target.line)
        var byLine: [(start: Int, matches: [BufferMatch])] = []
        for m in found {
            let first = BufferSearch.lineStart(in: t, row: m.row)
            if byLine.last?.start == first { byLine[byLine.count - 1].matches.append(m) } else { byLine.append((first, [m])) }
        }
        let lines = byLine.filter { Self.lineKey(BufferSearch.lineText(in: t, row: $0.start)) == want }
        let onLine = lines.filter { $0.start >= row }.dropFirst(max(sameLine, 0)).first ?? lines.last { $0.start < row } ?? lines.first
        if let onLine {
            return onLine.matches.indices.contains(target.occurrence) ? onLine.matches[target.occurrence] : onLine.matches.first
        }
        let after = found.filter { $0.row >= row }
        return after.indices.contains(nth) ? after[nth] : after.first ?? found.last
    }

    /// Selects match `m` of the recording's (its `index`) in the history view and shows it.
    private func showPick(_ m: BufferMatch, in h: HistoryTerminalView, index: Int) {
        let t = h.getTerminal()
        let trimmed = t.buffer.totalLinesTrimmed
        guard let first = m.segments.first, let last = m.segments.last else { return }
        if let s = findSession, s.earlier.indices.contains(index) {
            s.lastEarlierPick = (s.earlier[index].id, h.place(ofRow: m.row, column: first.columns.lowerBound))
            // The mark on the scroller where the view shows it.
            if let share = historyShare(ofRow: m.row, in: h) { s.earlier[index].share = share }
        }
        h.selection.setSelection(start: Position(col: first.columns.lowerBound, row: first.row - trimmed),
                                 end: Position(col: last.columns.upperBound, row: last.row - trimmed))
        // Placed by the find, not scrolled to an edge by the user: no other part is read.
        h.notePlaced()
        if !Self.inSight(m.rows, top: t.buffer.yDisp + trimmed, rows: t.rows, coveredAtTop: findBarCoveredRows) {
            h.scrollTo(row: max(m.row - trimmed - t.rows / 3, 0))
        }
        // Where it is, as a match in memory shows it.
        h.flashRows((m.row - trimmed)...(m.rows.upperBound - trimmed))
        h.needsDisplay = true
        scrollerNeedsUpdate()
    }

    /// A part of the recording finished loading: a match asked for meanwhile is shown now.
    func showQueuedEarlierMatch() {
        guard let s = findSession, let id = s.queuedEarlier else { return }
        s.queuedEarlier = nil
        if let i = s.earlierIndex(of: id) { showEarlierMatch(i) }
    }

    /// The text of the current match (for "Use Selection for Find" and copying).
    public var currentFindMatchText: String? {
        guard let s = findSession, let c = s.current else { return nil }
        return s.matches[c].segments.map { seg in
            findCells(row: seg.row, columns: seg.columns).map(\.1).joined()
        }.joined()
    }

    // MARK: Internals

    /// Output or size changed: matches are found again a moment later (coalesced).
    func findBufferChanged() {
        // Off screen nothing is drawn: the find catches up when the tab is shown (`noteShown`).
        guard window != nil, let s = findSession, !s.rescanScheduled else { return }
        s.rescanScheduled = true
        let delay = max(0.2, s.scanDuration * 5)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let s = self.findSession else { return }
            s.rescanScheduled = false
            let previous = s.current.map { s.matches[$0] }
            self.scanFind()
            if s.currentEarlier != nil || s.pendingEarlier != nil {
                s.current = nil         // the current match is in the recording
            } else if let previous, !s.matches.isEmpty {
                // The same match if it is still there, otherwise the next one.
                let i = FindOverlay.firstIndex(in: s.matches, atOrAfter: previous.row)
                s.current = s.matches.firstIndex(of: previous) ?? (s.matches.indices.contains(i) ? i : s.matches.count - 1)
            } else {
                s.current = s.matches.isEmpty ? nil : s.matches.count - 1
            }
            self.drawFind()
            self.reportFind()
            // Lines left memory meanwhile (into the recording): they are searched there too.
            self.searchRecordingForFind(restart: false)
        }
    }

    /// Scrolled, resized or restyled: the overlay follows.
    func drawFind() {
        guard window != nil, let s = findSession, let layer else { return }
        // Above the history view and the scroller (their layers come after it otherwise).
        if s.overlay.root.superlayer !== layer || layer.sublayers?.last !== s.overlay.root { layer.addSublayer(s.overlay.root) }
        var geometry = findGeometry
        // While browsing the recording, what is in memory is not on screen: only the scroller marks.
        if isBrowsingHistory { geometry.rows = 0 }
        s.overlay.update(matches: s.matches, current: s.current, geometry: geometry, style: settingsFindStyle,
                         font: font, scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, appearance: effectiveAppearance,
                         // Shares of the whole session: only when the scroller stands for it.
                         earlier: exactIndex == nil ? [] : s.earlier.map(\.share), currentEarlier: s.currentEarlier,
                         text: { [unowned self] row, columns in self.findCells(row: row, columns: columns) })
    }

    /// Finds the matches: only in the rows that may have changed since the last look (output
    /// arrives at the screen; what scrolled above it stays as it was), or `everything`.
    private func scanFind(everything: Bool = false) {
        guard let s = findSession else { return }
        let start = ProcessInfo.processInfo.systemUptime
        let t = getTerminal()
        let trimmed = t.buffer.totalLinesTrimmed
        defer {
            s.scanDuration = ProcessInfo.processInfo.systemUptime - start
            // Next time: from the screen's top (the rows output can still change).
            var end = trimmed, hi = trimmed + 4_000_000
            while end < hi {
                let mid = (end + hi) / 2
                if t.getScrollInvariantLine(row: mid) != nil { end = mid + 1 } else { hi = mid }
            }
            let top = max(end - t.rows, trimmed)
            s.changedFrom = s.regex == nil ? nil : top
            s.lineAboveChanged = top > trimmed ? t.getScrollInvariantLine(row: top - 1) : nil
            s.scannedColumns = t.cols
            s.scannedRows = t.rows
            s.scannedAlternate = t.isCurrentBufferAlternate
        }
        guard let regex = s.regex else { s.matches = []; return }
        // At the limit, the rows after the last match kept were never looked through: all again.
        if !everything, s.matches.count < TerminalFindSession.limit, let changed = s.changedFrom, changed > trimmed, s.scannedColumns == t.cols, s.scannedRows == t.rows,
           s.scannedAlternate == t.isCurrentBufferAlternate, let above = s.lineAboveChanged,
           t.getScrollInvariantLine(row: changed - 1) === above {
            s.lastScanWasPartial = true
            let from = BufferSearch.lineStart(in: t, row: changed)
            let kept = s.matches.filter { $0.row >= trimmed && $0.rows.upperBound < from }
            s.matches = kept + BufferSearch.matches(in: t, regex: regex, limit: TerminalFindSession.limit - kept.count, from: from)
        } else {
            s.lastScanWasPartial = false
            s.matches = BufferSearch.matches(in: t, regex: regex, limit: TerminalFindSession.limit)
            s.fullScanDuration = ProcessInfo.processInfo.systemUptime - start
        }
    }

    private func revealCurrentMatch(announce: Bool) {
        if let s = findSession, let c = s.current {
            let t = getTerminal()
            let rows = s.matches[c].rows
            let top = findGeometry.topRow
            // Only scroll when the match is not in sight: rows under the find bar do not count.
            if !Self.inSight(rows, top: top, rows: t.rows, coveredAtTop: findBarCoveredRows) {
                placeView(row: max(rows.lowerBound - t.buffer.totalLinesTrimmed - t.rows / 3, 0))
            }
        }
        drawFind()
        if announce { findSession?.overlay.announce(settingsFindStyle.jumpEffect) }
        reportFind()
    }

    /// Whether rows `rows` (scroll-invariant) are on screen and not under what covers its top (the
    /// find bar), nor on its last row.
    nonisolated static func inSight(_ rows: ClosedRange<Int>, top: Int, rows screen: Int, coveredAtTop: Int) -> Bool {
        let first = top + min(coveredAtTop, max(screen / 3, 0))
        let last = top + screen - (screen > 4 ? 2 : 1)
        return rows.lowerBound >= first && rows.upperBound <= last
    }

    /// Rows the floating find bar covers at the top of the terminal.
    var findBarCoveredRows: Int {
        guard findSession != nil, findBarHeight > 0 else { return 0 }
        let height = findGeometry.cell.height
        return height > 0 ? Int((findBarHeight / height).rounded(.up)) : 0
    }

    private func reportFind() {
        var status = TerminalFindStatus()
        if let s = findSession {
            let e = s.earlier.count
            status.total = e + s.matches.count
            status.limited = s.matches.count >= TerminalFindSession.limit || e >= TerminalFindSession.limit
            status.invalidPattern = s.regex == nil && !s.query.term.isEmpty
            status.searchingRecording = s.searchingEarlier
            status.recordingProgress = s.searchingEarlier ? s.earlierProgress : nil
            status.recordingUnreadable = s.recordingUnreadable
            if let i = s.currentEarlier {
                status.current = i + 1
                status.position = Double(s.earlier[i].share)
            } else if let c = s.current {
                status.current = e + c + 1
                status.position = min(max(findGeometry.share(row: s.matches[c].row), 0), 1)
            }
        }
        onFindStatus?(status)
    }

    var findGeometry: FindOverlay.Geometry {
        let t = getTerminal()
        let trimmed = t.buffer.totalLinesTrimmed
        let caret = caretFrame.size
        // The caret is a cell — but two cells wide over a wide character: then the width last seen
        // on a single cell is used.
        let roughWidth = bounds.width / CGFloat(max(t.cols, 1))
        if caret.width > 0, caret.width < roughWidth * 1.5 { lastCellWidth = caret.width }
        let width = lastCellWidth ?? (caret.width > 0 && caret.width < roughWidth * 1.5 ? caret.width : roughWidth)
        let cell = CGSize(width: width, height: caret.height > 0 ? caret.height : bounds.height / CGFloat(max(t.rows, 1)))
        let scroller = historyScroller.isHidden ? nil : historyScroller.frame
        // The scroller stands for the whole session (memory is its last part), in lines, as its
        // knob does (`updateHistoryScroller`); without an index, for the rows in memory.
        var g = FindOverlay.Geometry(bounds: bounds, cell: cell, topRow: trimmed + t.getTopVisibleRow(), rows: t.rows,
                                     textWidth: scroller.map { $0.minX } ?? bounds.width,
                                     scroller: scroller, firstRow: trimmed, lineCount: bufferLineCount)
        g.visibleLines = historyScroller.visible
        if let index = exactIndex, !isAlternateScreen || isBrowsingHistory {
            g.lineBefore = Double(liveFirstLineForMarks)
            g.rowsPerLine = rowsPerLine
            g.lineCount = index.lines + 1
        }
        return g
    }

    /// The characters of a row's cells (start column, text), wide characters once.
    func findCells(row: Int, columns: Range<Int>) -> [(Int, String)] {
        let t = getTerminal()
        guard let line = t.getScrollInvariantLine(row: row) else { return [] }
        var out: [(Int, String)] = []
        for col in columns where col < line.count {
            let cell = line[col]
            if cell.width == 0 { continue }
            let ch = t.getCharacter(for: cell)
            out.append((col, ch == "\0" ? " " : String(ch)))
        }
        return out
    }
}
