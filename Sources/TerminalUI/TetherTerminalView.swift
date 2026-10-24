import AppKit
import SwiftTerm
import RecordingKit
import TetherCore
import SessionKit

/// The terminal view bound to one `TerminalSession`.
public final class TetherTerminalView: TerminalView, TerminalViewDelegate, TerminalSink {
    public private(set) weak var session: TerminalSession?
    private var settings: AppSettings
    public private(set) var theme: TerminalTheme
    /// Rows where the user pressed Return (like Terminal.app's marks), counted from the start of the
    /// session so they stay valid when old scrollback lines are trimmed. See `marks`.
    private var markLines: [Int] = []
    private var pendingResize: DispatchWorkItem?
    private var lastSentSize: (cols: Int, rows: Int)?
    /// The display scale the cell size was worked out for (see `viewDidChangeBackingProperties`).
    private var metricsScale: CGFloat = 1
    /// Called with files dropped onto (or pasted into) the terminal.
    public var onFiles: (([URL]) -> Void)?

    /// Called when the background colour/translucency changes so SwiftUI can update the pane.
    public var onThemeChange: ((TerminalTheme) -> Void)?
    /// Called with `true` when the user scrolls to the top of the in-memory history while older
    /// lines have already been dropped (they are still in the session's recording on disk).
    public var onReachedHistoryLimit: ((Bool) -> Void)?
    private var atHistoryLimit = false

    public init(session: TerminalSession, settings: AppSettings) {
        self.session = session
        self.settings = settings
        theme = TerminalTheme.resolve(settings, appearance: NSApp.effectiveAppearance)
        var options = TerminalOptions.default
        options.scrollback = settings.scrollbackLines
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 500), font: settings.terminalFont, options: options)
        terminalDelegate = self
        // A permanent scroller shows how far back the history goes.
        scrollerStyle = .legacy
        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        apply(settings: settings)
        // Outside a window SwiftTerm sizes cells for the main screen.
        metricsScale = NSScreen.main?.backingScaleFactor ?? 1
        KeyboardRouter.shared.install()
        // Notifications from programs (OSC 9, 777, 99) — never while old output is replayed.
        for code in [9, 777, 99] {
            getTerminal().registerOscHandler(code: code) { [weak self] payload in
                guard let self, !self.loadingHistory else { return }
                self.session?.terminalOSC(code: code, payload: Array(payload))
            }
        }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Settings

    public func apply(settings: AppSettings) {
        self.settings = settings
        let newFont = settings.terminalFont
        if newFont != font { setFont(newFont) }
        applyTheme()
        optionAsMetaKey = settings.optionAsMeta
        allowMouseReporting = settings.allowMouseReporting
        getTerminal().setCursorStyle(settings.swiftTermCursor)
        getTerminal().changeScrollback(settings.scrollbackLines)
        KeyboardRouter.shared.mappings = settings.keyMappings
    }

    private func applyTheme() {
        theme = TerminalTheme.resolve(settings, appearance: effectiveAppearance)
        installColors(theme.ansi)
        nativeForegroundColor = theme.foreground
        nativeBackgroundColor = theme.background
        caretColor = theme.cursor
        selectedTextBackgroundColor = theme.selection
        wantsLayer = true
        layer?.backgroundColor = theme.background.cgColor
        layer?.isOpaque = !theme.isTranslucent
        needsDisplay = true
        onThemeChange?(theme)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    public override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        blockSelection = nil
        if settings.copyOnSelect, selectionActive, let text = getSelection(), !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    // MARK: Files (drag & drop, paste)

    private func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        !PasteboardFiles.fileURLs(on: pasteboard).isEmpty
            || pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onFiles != nil && carriesFiles(sender.draggingPasteboard) ? .copy : []
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    /// Dropped files upload; so do file promises (the screenshot thumbnail, Photos, Mail).
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let onFiles else { return false }
        let pasteboard = sender.draggingPasteboard
        let urls = PasteboardFiles.fileURLs(on: pasteboard)
        if !urls.isEmpty {
            onFiles(urls)
            return true
        }
        return PasteboardFiles.receivePromises(from: pasteboard) { urls in
            if !urls.isEmpty { onFiles(urls) }
        }
    }

    /// Pasting copied files (Finder ⌘C) or a copied image (e.g. a screenshot taken with ⌃⇧⌘4)
    /// uploads them like a drop; text pastes as usual.
    public override func paste(_ sender: Any) {
        if let onFiles, let files = PasteboardFiles.filesToPaste(from: NSPasteboard.general) {
            onFiles(files)
            return
        }
        super.paste(sender)
    }

    // MARK: TerminalSink

    /// Output from the remote side, with Terminal.app's handling of screen clears (see
    /// `feedKeepingScrollback`). ⌘K (`clearBuffer`) still clears everything.
    public func feed(_ bytes: ArraySlice<UInt8>) {
        feedKeepingScrollback(bytes)
    }

    public var cellSize: (cols: Int, rows: Int) {
        let t = getTerminal()
        return (t.cols, t.rows)
    }

    /// Laid out in a window at least once with a usable size (see `sizeChanged`).
    public var hasRealSize: Bool { lastSentSize != nil }

    /// In a window, the size the view really has is reported — also when the emulator worked it
    /// out before the view was in a window (then the column count does not change on the way in, and
    /// SwiftTerm does not call `sizeChanged` again).
    private func reportSizeIfNeeded() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let size = cellSize
        if lastSentSize.map({ $0 != size }) ?? true { sizeChanged(source: self, newCols: size.cols, newRows: size.rows) }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMetricsForScale()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.reportSizeIfNeeded() } }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateMetricsForScale()
    }

    /// SwiftTerm snaps the cell width to the pixels of the screen it measured on and never measures
    /// again. Box-drawing characters (─ │ ╭ …, Claude Code's tables, rules and input box) are drawn
    /// at whole pixels per cell of the current screen, text at the measured width: measured on a
    /// Retina screen (7.5 pt) and shown on a 1× one, the lines move 0.5 px further right per column.
    /// Views made before they have a window (tabs restored at launch) measure on the main screen,
    /// so measure again for the window's screen.
    private func updateMetricsForScale() {
        guard let scale = window?.backingScaleFactor, scale != metricsScale else { return }
        setFont(font)
    }

    /// Changes the font without resetting the terminal: SwiftTerm soft-resets a sized view when its
    /// font changes (cursor visibility, application keys, scroll region, … of the running program).
    /// With no size, it only measures; the size given back then resizes the terminal as usual.
    private func setFont(_ newFont: NSFont) {
        let size = frame.size
        setFrameSize(.zero)
        font = newFont
        setFrameSize(size)
        metricsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reportSizeIfNeeded()
    }

    public func screenTail(maxRows: Int) -> (lines: [String], lastRow: Int)? {
        let t = getTerminal()
        guard !t.isCurrentBufferAlternate else { return nil }
        // The screen itself, wherever the view is scrolled to.
        var total = t.buffer.totalLinesTrimmed
        while t.getScrollInvariantLine(row: total) != nil { total += 1 }
        let top = total - t.rows
        let rows = (0..<t.rows).map { r in
            (t.getScrollInvariantLine(row: top + r)?.translateToString(trimRight: true) ?? "").replacingOccurrences(of: "\0", with: "")
        }.map { line -> String in
            var s = line
            while s.last == " " { s.removeLast() }
            return s
        }
        guard let last = rows.lastIndex(where: { !$0.isEmpty }) else { return nil }
        let first = max(0, last - maxRows + 1)
        return (Array(rows[first...last]), last)
    }

    func sendMapped(_ bytes: [UInt8]) {
        session?.send(bytes[...])
    }

    /// Clears the scrollback and screen locally (⌘K).
    public func clearBuffer() {
        feed(byteArray: Array("\u{1b}[H\u{1b}[2J\u{1b}[3J".utf8)[...])
        markLines.removeAll()
        // Ask the shell to redraw its prompt.
        if session?.phase.isOnline == true { session?.send([0x0c][...]) }
    }

    // MARK: Scrolling, marks and selection (Terminal.app behaviour)

    /// Marks as current buffer rows (dropping those already trimmed from scrollback).
    var marks: [Int] {
        let trimmed = getTerminal().buffer.totalLinesTrimmed
        return markLines.map { $0 - trimmed }.filter { $0 >= 0 }
    }

    /// Buffer row of the top of the screen when scrolled to the bottom.
    private var bottomBase: Int {
        let t = getTerminal()
        let current = t.getTopVisibleRow()
        scrollToBottom()
        let base = t.getTopVisibleRow()
        if base != current { scrollTo(row: current) }
        return base
    }

    /// Buffer row of the cursor (scrollback + screen), independent of the scroll position.
    var cursorAbsoluteRow: Int {
        bottomBase + getTerminal().getCursorLocation().y
    }

    private var isAlternateScreen: Bool { getTerminal().isCurrentBufferAlternate }

    func scrollPage(up: Bool) {
        let n = max(getTerminal().rows - 1, 1)
        if up { scrollUp(lines: n) } else { scrollDown(lines: n) }
    }

    func scrollToTop() { scrollTo(row: 0) }
    func scrollToBottom() { scrollTo(row: Int.max / 2) }

    /// ⌘↑ / ⌘↓: jump to the previous/next command and briefly highlight it.
    func jumpToMark(up: Bool) {
        let top = getTerminal().getTopVisibleRow()
        let reference = jumpCursor ?? (up ? cursorAbsoluteRow : top)
        guard let target = up ? marks.last(where: { $0 < reference }) : marks.first(where: { $0 > reference }) else {
            if !up { jumpCursor = nil; scrollToBottom() }
            NSSound.beep()
            return
        }
        jumpCursor = target
        blockSelection = nil
        selection.selectNone()
        scrollTo(row: max(target - 2, 0))
        highlight(rows: target...target)
    }

    /// ⇧⌘↑ / ⇧⌘↓: select whole commands (prompt line + output), like Terminal.app.
    /// - ⇧⌘↑ selects the last command, then extends the selection upwards one command at a time.
    /// - ⇧⌘↓ extends the selection downwards one command at a time.
    /// - After jumping with ⌘↑/⌘↓, either key selects the command that was jumped to.
    func selectToMark(up: Bool) {
        let promptRow = cursorAbsoluteRow
        let starts = marks.filter { $0 < promptRow }
        guard !starts.isEmpty else { NSSound.beep(); return }
        func blockEnd(_ start: Int) -> Int { (starts.first { $0 > start } ?? promptRow) - 1 }

        let range: ClosedRange<Int>?
        if let current = blockSelection {
            if up {
                range = starts.last { $0 < current.lowerBound }.map { $0...current.upperBound }
            } else {
                range = starts.first { $0 > current.upperBound }.map { current.lowerBound...blockEnd($0) }
            }
        } else if let jump = jumpCursor {
            range = jump...max(blockEnd(jump), jump)
        } else if up {
            range = starts.last!...max(promptRow - 1, starts.last!)
        } else {
            let top = getTerminal().getTopVisibleRow()
            range = (starts.first { $0 >= top } ?? starts.last).map { $0...max(blockEnd($0), $0) }
        }
        guard let range else { NSSound.beep(); return }
        blockSelection = range
        selection.setSelection(start: Position(col: 0, row: range.lowerBound),
                               end: Position(col: getTerminal().cols, row: range.upperBound))
        let rows = getTerminal().rows
        scrollTo(row: up || range.count > rows ? max(range.lowerBound - 1, 0) : max(range.upperBound - rows + 2, 0))
        highlight(rows: range)
        needsDisplay = true
    }

    /// The current mark-based selection (cleared when the user types or clicks).
    private var blockSelection: ClosedRange<Int>?
    /// Last mark jumped to with ⌘↑/⌘↓.
    var jumpCursor: Int?

    /// Briefly tints buffer rows so the user sees where a jump or selection landed.
    private func highlight(rows: ClosedRange<Int>) {
        let t = getTerminal()
        let rowHeight = bounds.height / CGFloat(max(t.rows, 1))
        let top = t.getTopVisibleRow()
        let first = max(rows.lowerBound - top, 0)
        let last = min(rows.upperBound - top, t.rows - 1)
        guard last >= first else { return }
        let layerRect = NSRect(x: 0, y: bounds.height - CGFloat(last + 1) * rowHeight,
                               width: bounds.width, height: CGFloat(last - first + 1) * rowHeight)
        let l = CALayer()
        l.frame = isFlipped ? NSRect(x: 0, y: CGFloat(first) * rowHeight, width: bounds.width,
                                     height: layerRect.height) : layerRect
        l.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        l.cornerRadius = 3
        layer?.addSublayer(l)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 0.35
        fade.duration = 0.45
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        l.add(fade, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { l.removeFromSuperlayer() }
    }

    // MARK: Search support

    /// All lines of the scrollback and screen as text, plus the scroll-invariant row of the first one.
    public func scrollbackText() -> (base: Int, lines: [String], logicalLines: Int) {
        let t = getTerminal()
        let base = t.buffer.totalLinesTrimmed
        var lines: [String] = []
        var logical = 0
        var row = base
        while let line = t.getScrollInvariantLine(row: row) {
            lines.append(line.translateToString(trimRight: true).replacingOccurrences(of: "\0", with: " "))
            if !line.isWrapped { logical += 1 }
            row += 1
        }
        // Drop trailing empty screen rows.
        while lines.last?.isEmpty == true { lines.removeLast() }
        return (base, lines, logical)
    }

    /// A full-screen program (vim, less, htop) has the alternate screen up: what is shown is only
    /// that screen, the history is in the normal buffer and the recording.
    public var showsAlternateScreen: Bool { isAlternateScreen }

    /// The scrollback and screen as logical lines (wrapped rows joined, as the program wrote them),
    /// whether older lines were dropped from memory, and how many logical lines the buffer holds.
    public func logicalText() -> (trimmed: Bool, lines: [String], logicalLines: Int) {
        let t = getTerminal()
        let base = t.buffer.totalLinesTrimmed
        var lines: [String] = []
        var row = base
        while let line = t.getScrollInvariantLine(row: row) {
            let text = line.translateToString(trimRight: false).replacingOccurrences(of: "\0", with: " ")
            if line.isWrapped, !lines.isEmpty { lines[lines.count - 1] += text } else { lines.append(text) }
            row += 1
        }
        let logical = lines.count
        lines = lines.map { l in
            var s = Substring(l)
            while s.last == " " { s = s.dropLast() }
            return String(s)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return (base > 0, lines, logical)
    }

    /// Scrolls to a scroll-invariant row and selects the given column range (e.g. a search match).
    public func reveal(invariantRow: Int, columns: Range<Int>?) {
        let row = invariantRow - getTerminal().buffer.totalLinesTrimmed
        guard row >= 0 else { NSSound.beep(); return }
        scrollTo(row: max(row - getTerminal().rows / 3, 0))
        if let columns, !columns.isEmpty {
            selection.setSelection(start: Position(col: columns.lowerBound, row: row),
                                   end: Position(col: columns.upperBound, row: row))
        }
        highlight(rows: row...row)
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    func selectAllText() {
        selection.selectAll()
        needsDisplay = true
    }

    /// Handles navigation keys the way Terminal.app does. Returns true if handled.
    func handleNavigationKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, flags) {
        case (126, [.command]): jumpToMark(up: true)
        case (125, [.command]): jumpToMark(up: false)
        case (126, [.command, .shift]): selectToMark(up: true)
        case (125, [.command, .shift]): selectToMark(up: false)
        case (116, []) where !isAlternateScreen, (116, [.command]): scrollPage(up: true)     // Page Up
        case (121, []) where !isAlternateScreen, (121, [.command]): scrollPage(up: false)    // Page Down
        case (115, []) where !isAlternateScreen, (115, [.command]): scrollToTop()            // Home
        case (119, []) where !isAlternateScreen, (119, [.command]): scrollToBottom()         // End
        case (0, [.command]): selectAllText()                                                 // ⌘A
        default: return false
        }
        return true
    }

    // MARK: TerminalViewDelegate

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Ignore transient tiny sizes during layout, and coalesce bursts (window resizing)
        // so the remote shell receives one final size instead of dozens of SIGWINCHs.
        // A view in no window has its initial frame, not a real size: a tab restored in the
        // background must not resize its program (it would redraw now and again when shown).
        guard newCols >= 20, newRows >= 4, window != nil else { return }
        pendingResize?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let size = self.cellSize
            if let last = self.lastSentSize, last == size { return }
            self.lastSentSize = size
            self.session?.terminalDidResize(cols: size.cols, rows: size.rows)
        }
        pendingResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (lastSentSize == nil ? 0 : 0.08), execute: work)
    }

    public func setTerminalTitle(source: TerminalView, title: String) {
        session?.remoteTitle = title
    }

    /// OSC 7 (`file://host/path`) from shells that report their working directory.
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        let path = URL(string: directory)?.path ?? directory
        if !path.isEmpty, session?.reportedDirectory != path { session?.reportedDirectory = path }
    }

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        blockSelection = nil
        jumpCursor = nil
        if data.contains(0x0d), session?.phase.isOnline == true, !isAlternateScreen {
            let line = cursorAbsoluteRow + getTerminal().buffer.totalLinesTrimmed
            if markLines.last != line { markLines.append(line) }
            if markLines.count > 5000 { markLines.removeFirst(markLines.count - 5000) }
        }
        session?.send(data)
    }

    public func scrolled(source: TerminalView, position: Double) {
        let trimmed = getTerminal().buffer.totalLinesTrimmed > 0
        if position <= 0.0001 && trimmed && historySource != nil {
            // Older output is read back from disk as the user reaches the top (no visible break).
            DispatchQueue.main.async { [weak self] in _ = self?.loadOlderHistory() }
        } else if position >= 0.9999 {
            DispatchQueue.main.async { [weak self] in self?.shrinkHistoryIfAtBottom() }
        }
        let atLimit = position <= 0.0001 && trimmed && historySource == nil
        if atLimit != atHistoryLimit {
            atHistoryLimit = atLimit
            onReachedHistoryLimit?(atLimit)
        }
    }

    // MARK: History beyond memory

    /// The session's recording on disk (flushed), used to bring back output dropped from memory.
    public var historySource: (() -> URL?)?
    /// Lines read back each time the top of memory is reached.
    public var historyChunkLines = 10_000
    private var loadingHistory = false
    private var historyExtended = false

    private var bufferLineCount: Int {
        let t = getTerminal()
        var lo = t.buffer.totalLinesTrimmed, hi = lo + 4_000_000
        while lo < hi {   // first invariant row without a line
            let mid = (lo + hi) / 2
            if t.getScrollInvariantLine(row: mid) != nil { lo = mid + 1 } else { hi = mid }
        }
        return lo - t.buffer.totalLinesTrimmed
    }

    /// Replays the end of the recording with room for `historyChunkLines` more lines. The bottom
    /// of the buffer is the same afterwards, so the line being looked at, the selection and the
    /// command marks are put back at the same distance from the end: scrolling simply continues.
    /// Nothing happens in full-screen apps, while the mouse is pressed, or without a recording.
    @discardableResult
    func loadOlderHistory() -> Bool {
        let t = getTerminal()
        guard !loadingHistory, !isAlternateScreen, NSEvent.pressedMouseButtons == 0,
              t.buffer.totalLinesTrimmed > 0, t.buffer.yDisp == 0,
              let url = historySource?() else { return false }
        loadingHistory = true
        defer { loadingHistory = false }

        let oldCount = bufferLineCount
        let oldEnd = t.buffer.totalLinesTrimmed + oldCount
        let selectionRange = selection.active ? (selection.start, selection.end) : nil
        let wanted = oldCount + historyChunkLines
        guard let bytes = Self.tail(of: url, lines: wanted + t.rows) else { return false }
        let markDistances = markLines.map { oldEnd - $0 }

        t.resetToInitialState()
        changeScrollback(wanted)
        feed(bytes[...])

        let newCount = bufferLineCount
        guard newCount > oldCount else { return false }
        historyExtended = true
        let delta = newCount - oldCount
        scrollTo(row: delta)
        if let (a, b) = selectionRange {
            selection.setSelection(start: Position(col: a.col, row: a.row + delta), end: Position(col: b.col, row: b.row + delta))
        }
        let newEnd = t.buffer.totalLinesTrimmed + newCount
        markLines = markDistances.map { newEnd - $0 }
        return true
    }

    /// Back at the bottom: drop the extra lines again so memory returns to the configured size.
    private func shrinkHistoryIfAtBottom() {
        guard historyExtended, !loadingHistory, !selection.active, NSEvent.pressedMouseButtons == 0 else { return }
        historyExtended = false
        changeScrollback(settings.scrollbackLines)
    }

    /// The last `lines` lines of the recording (plain, encrypted or compressed).
    static func tail(of url: URL, lines: Int) -> [UInt8]? {
        RecordingReader.tail(of: url, lines: lines)
    }

    /// Number of lines dropped from memory so far (still available in the recording).
    public var trimmedLineCount: Int { getTerminal().buffer.totalLinesTrimmed }

    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "ftp"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }

    public func bell(source: TerminalView) {
        if !loadingHistory { session?.bellRang() }
        switch settings.bell {
        case .none: break
        case .sound: NSSound.beep()
        case .visual: flash()
        }
    }

    /// OSC 52 from the server. Only the terminal being worked in may set the clipboard: not a tab in
    /// the background, another window, or anything while Tether is not the active app (or locked,
    /// when no terminal has the keyboard) — so a server cannot swap what was just copied.
    public func clipboardCopy(source: TerminalView, content: Data) {
        guard NSApp.isActive, let window, window.isKeyWindow, window.firstResponder === self,
              let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func clipboardRead(source: TerminalView) -> Data? { nil }

    public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    private func flash() {
        let l = CALayer()
        l.frame = bounds
        l.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        layer?.addSublayer(l)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { l.removeFromSuperlayer() }
    }
}
