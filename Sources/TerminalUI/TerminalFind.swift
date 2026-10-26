import AppKit
import SwiftTerm
import TetherCore
import TerminalText

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

    init(query: TerminalFindQuery) { self.query = query }
}

extension TetherTerminalView {
    /// Starts, changes or (nil) ends the find. A new search starts at the match nearest the
    /// latest output on screen — or on `anchorRow` (scroll-invariant), e.g. a match picked in the
    /// search window; a changed term keeps the place of the current match where it can.
    public func setFind(_ query: TerminalFindQuery?, anchorRow: Int? = nil) {
        guard let query else {
            findSession?.overlay.remove()
            findSession = nil
            notifyUpdateChanges = false
            reportFind()
            return
        }
        if let s = findSession, s.query == query, anchorRow == nil {
            drawFind()
            reportFind()
            return
        }
        let previous = findSession.flatMap { s in s.current.map { s.matches[$0] } }
        let session = findSession ?? TerminalFindSession(query: query)
        session.query = query
        findSession = session
        notifyUpdateChanges = true
        session.regex = query.term.isEmpty ? nil
            : try? BufferSearch.regex(query.term, isRegex: query.isRegex, caseSensitive: query.caseSensitive, wholeWord: query.wholeWord)
        scanFind()

        let m = session.matches
        if m.isEmpty {
            session.current = nil
        } else if let anchorRow {
            session.current = m.firstIndex { $0.rows.contains(anchorRow) } ?? min(FindOverlay.firstIndex(in: m, atOrAfter: anchorRow), m.count - 1)
        } else if let previous {
            let i = FindOverlay.firstIndex(in: m, atOrAfter: previous.row)
            session.current = m.indices.contains(i) ? i : m.count - 1
        } else {
            // The last match above the bottom of the screen: the most recent output first.
            let bottom = findGeometry.topRow + getTerminal().rows
            let i = FindOverlay.firstIndex(in: m, atOrAfter: bottom)
            session.current = max(i - 1, 0)
        }
        // Typing more of the term usually keeps the same match: it is shown again only when the
        // find lands somewhere else.
        let landed = session.current.map { m[$0].row }
        revealCurrentMatch(announce: landed != nil && landed != previous?.row)
    }

    /// ⌘G / ⇧⌘G: the next or previous match, round the end.
    public func findStep(forward: Bool) {
        guard let s = findSession, !s.matches.isEmpty else { NSSound.beep(); return }
        let n = s.matches.count
        if let c = s.current {
            s.current = (c + (forward ? 1 : -1) + n) % n
        } else {
            s.current = forward ? 0 : n - 1
        }
        revealCurrentMatch(announce: true)
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
        guard let s = findSession, !s.rescanScheduled else { return }
        s.rescanScheduled = true
        let delay = max(0.2, s.scanDuration * 5)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let s = self.findSession else { return }
            s.rescanScheduled = false
            let previous = s.current.map { s.matches[$0] }
            self.scanFind()
            if let previous, !s.matches.isEmpty {
                // The same match if it is still there, otherwise the next one.
                let i = FindOverlay.firstIndex(in: s.matches, atOrAfter: previous.row)
                s.current = s.matches.firstIndex(of: previous) ?? (s.matches.indices.contains(i) ? i : s.matches.count - 1)
            } else {
                s.current = s.matches.isEmpty ? nil : s.matches.count - 1
            }
            self.drawFind()
            self.reportFind()
        }
    }

    /// Scrolled, resized or restyled: the overlay follows.
    func drawFind() {
        guard let s = findSession, let layer else { return }
        if s.overlay.root.superlayer !== layer { layer.addSublayer(s.overlay.root) }
        s.overlay.update(matches: s.matches, current: s.current, geometry: findGeometry, style: settingsFindStyle,
                         font: font, scale: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2, appearance: effectiveAppearance,
                         text: { [unowned self] row, columns in self.findCells(row: row, columns: columns) })
    }

    private func scanFind() {
        guard let s = findSession else { return }
        let start = Date()
        s.matches = s.regex.map { BufferSearch.matches(in: getTerminal(), regex: $0, limit: TerminalFindSession.limit) } ?? []
        s.scanDuration = Date().timeIntervalSince(start)
    }

    private func revealCurrentMatch(announce: Bool) {
        if let s = findSession, let c = s.current {
            let t = getTerminal()
            let rows = s.matches[c].rows
            let top = findGeometry.topRow
            // Only scroll when the match is not on screen (a little margin from the edges).
            if rows.lowerBound < top || rows.upperBound >= top + t.rows {
                scrollTo(row: max(rows.lowerBound - t.buffer.totalLinesTrimmed - t.rows / 3, 0))
            }
        }
        drawFind()
        if announce { findSession?.overlay.announce(settingsFindStyle.jumpEffect) }
        reportFind()
    }

    private func reportFind() {
        var status = TerminalFindStatus()
        if let s = findSession {
            status.total = s.matches.count
            status.limited = s.matches.count >= TerminalFindSession.limit
            status.invalidPattern = s.regex == nil && !s.query.term.isEmpty
            if let c = s.current {
                status.current = c + 1
                let g = findGeometry
                status.position = Double(s.matches[c].row - g.firstRow) / Double(max(g.lineCount - 1, 1))
            }
        }
        onFindStatus?(status)
    }

    var findGeometry: FindOverlay.Geometry {
        let t = getTerminal()
        let trimmed = t.buffer.totalLinesTrimmed
        let caret = caretFrame.size
        let cell = caret.width > 0 && caret.height > 0 ? caret
            : CGSize(width: bounds.width / CGFloat(max(t.cols, 1)), height: bounds.height / CGFloat(max(t.rows, 1)))
        let scroller = subviews.first { $0 is NSScroller && !$0.isHidden }
        return FindOverlay.Geometry(bounds: bounds, cell: cell, topRow: trimmed + t.getTopVisibleRow(), rows: t.rows,
                                    textWidth: scroller.map { $0.frame.minX } ?? bounds.width,
                                    scroller: scroller?.frame, firstRow: trimmed, lineCount: bufferLineCount)
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
