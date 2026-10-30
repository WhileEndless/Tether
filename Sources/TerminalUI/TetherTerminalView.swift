import AppKit
import os
import SwiftTerm
import RecordingKit
import TetherCore
import SessionKit
import TerminalText

/// The terminal view bound to one `TerminalSession`.
public final class TetherTerminalView: TerminalView, TerminalViewDelegate, TerminalSink {
    public private(set) weak var session: TerminalSession?
    private var settings: AppSettings
    public private(set) var theme: TerminalTheme
    /// Rows where the user pressed Return (like Terminal.app's marks), counted from the start of the
    /// session so they stay valid when old scrollback lines are trimmed. See `marks`.
    private var markLines: [Int] { markEntries.map(\.line) }
    /// Each mark's row and the time the recording noted the command with (which command of the
    /// recording's index it is; nil when nothing was recorded); `column`: where typing started,
    /// in cells from the line's start (after the prompt; nil: not known).
    private struct MarkEntry { var line: Int; var time: Date?; var column: Int? = nil }
    /// Where the user started typing since the last Return (scroll-invariant row, column): the
    /// command's start, after the prompt — for any program that reads a line, not only shells.
    private var inputStart: (row: Int, column: Int)?
    /// Something was typed on the line since the last Return (not only Return).
    private var typedOnLine = false
    /// What was typed on the line, as text (nil once a key other than a character or Backspace was
    /// pressed: arrows, history, completion — then the shell shows something else).
    private var typedText: String? = ""
    /// Output came just before the first key on the line: a program was still printing — what is
    /// typed goes ahead of it, and the shell shows the command after it.
    private var typedAhead = false
    /// When output last came (system uptime).
    private var lastOutputAt: TimeInterval = 0
    /// Stricter handling of image sequences in what is shown (`ImageSequenceFilter`).
    private var images = ImageSequenceFilter()
    /// A command typed ahead, run: marked once the shell shows it (`resolveTypedAhead`).
    private var pendingTypedAhead: (text: String, row: Int, since: TimeInterval)?
    /// How long a command typed ahead is waited for, and how recent output must be for typing to
    /// count as ahead of it.
    static let typedAheadWait: TimeInterval = 15
    static let busyBeforeTyping: TimeInterval = 0.3
    /// Return marks commands also without a connection (tests).
    var marksWhileOffline = false
    private var markEntries: [MarkEntry] = []
    private var pendingResize: DispatchWorkItem?
    private(set) var lastSentSize: (cols: Int, rows: Int)?
    /// The display scale the cell size was worked out for (see `viewDidChangeBackingProperties`).
    private var metricsScale: CGFloat = 1
    /// Called with files dropped onto (or pasted into) the terminal.
    public var onFiles: (([URL]) -> Void)?
    /// Files copied in Tether's file manager are on the clipboard: true when they were handled
    /// (their paths typed here, or fetched to this terminal's host first).
    public var onRemoteFiles: (() -> Bool)?
    /// Files dragged from Tether's file manager were dropped (`RemoteClipboard`'s data): true when
    /// they were handled — before any of them is downloaded, so on their own server only their
    /// paths are typed.
    public var onRemoteDrop: (([Data]) -> Bool)?
    /// The user clicked into the terminal (the window then follows it: sidebar row, host panel).
    public var onClick: (() -> Void)?

    /// Called when the background colour/translucency changes so SwiftUI can update the pane.
    public var onThemeChange: ((TerminalTheme) -> Void)?
    /// Called with `true` when the user scrolls to the top of the in-memory history while older
    /// lines have already been dropped (they are still in the session's recording on disk).
    public var onReachedHistoryLimit: ((Bool) -> Void)?
    private var atHistoryLimit = false
    /// The find running in this terminal (see TerminalFind.swift).
    var findSession: TerminalFindSession?
    /// The width of one cell, as the caret had it over a single-width character.
    var lastCellWidth: CGFloat?
    /// Called when the find's matches or current match change.
    public var onFindStatus: ((TerminalFindStatus) -> Void)?
    var settingsFindStyle: FindHighlightStyle { settings.findHighlight }

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
        Self.watchWheel()
        Self.watchInput()
        // Notifications from programs (OSC 9, 777, 99) and their status (OSC 7501, coding agents) —
        // never while old output is replayed.
        for code in [9, 777, 99, 7501] {
            getTerminal().registerOscHandler(code: code) { [weak self] payload in
                guard let self, !self.replayingEarlier else { return }
                self.session?.terminalOSC(code: code, payload: Array(payload))
            }
        }
        // Tether's own markers in the recording (size, commands). In earlier output shown again
        // (a tab restored after Tether reopened) a command's marker is where its line is: the
        // command marks come back with it, so ⌘↑ and ⇧⌘↑ find the commands on screen.
        getTerminal().registerOscHandler(code: 7771) { [weak self] payload in
            guard let self, self.replayingEarlier else { return }
            self.noteReplayedMark(payload)
        }
        SteadyCaret.prepare(self)
        installHistoryScroller()
        noteShown(false)      // made for a tab not on screen yet (restored in the background)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Lets go of everything set from outside (the tab closed: see `TerminalRegistry.remove`).
    func releaseCallbacks() {
        discardHistory(force: true)
        onFiles = nil
        onRemoteFiles = nil
        onRemoteDrop = nil
        onClick = nil
        onThemeChange = nil
        onReachedHistoryLimit = nil
        onFindStatus = nil
        historyReader = nil
        onHistoryLoaded = nil
        onBrowsingHistory = nil
        onCommandSelection = nil
        findSession = nil
    }

    // MARK: Settings

    public func apply(settings: AppSettings) {
        self.settings = settings
        let newFont = settings.terminalFont
        // Another font lays the history view out again: back to the live terminal first.
        if newFont != font, isBrowsingHistory { returnToLive() }
        if newFont != font { setFont(newFont) }
        applyTheme()
        optionAsMetaKey = settings.optionAsMeta
        syncMouseReporting()
        getTerminal().setCursorStyle(settings.swiftTermCursor)
        resizeScrollback(scrollbackLimit)
        history?.applyLook()
        KeyboardRouter.shared.mappings = settings.keyMappings
        drawFind()
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

    public override func mouseDown(with event: NSEvent) {
        onClick?()
        clearCommandSelection()
        dropStaleMouseTracking()
        super.mouseDown(with: event)
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
        let pasteboard = sender.draggingPasteboard
        if onRemoteDrop != nil, pasteboard.availableType(from: [Self.remoteFilesType]) != nil { return .copy }
        return onFiles != nil && carriesFiles(pasteboard) ? .copy : []
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    /// Dropped files upload; so do file promises (the screenshot thumbnail, Photos, Mail).
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        // Rows from the file manager: by server and path (their files are never asked for here).
        if let onRemoteDrop, pasteboard.availableType(from: [Self.remoteFilesType]) != nil {
            let data = (pasteboard.pasteboardItems ?? []).compactMap { $0.data(forType: Self.remoteFilesType) }
            if !data.isEmpty, onRemoteDrop(data) { return true }
        }
        guard let onFiles else { return false }
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
        // Before Finder's files: once copies made for Finder are there, the clipboard holds both,
        // and the server's own files come first (on the same server their paths are typed).
        if let onRemoteFiles, NSPasteboard.general.types?.contains(Self.remoteFilesType) == true, onRemoteFiles() { return }
        if let onFiles, let files = PasteboardFiles.filesToPaste(from: NSPasteboard.general) {
            onFiles(files)
            return
        }
        pasting = true
        defer { pasting = false }
        super.paste(sender)
    }

    /// The clipboard type of files copied in the file manager (`RemoteClipboard`).
    static let remoteFilesType = NSPasteboard.PasteboardType("com.tether.remote-files")

    private var pasting = false
    /// What is sent now comes from the user (a key, a paste); tests set it to say so.
    var sendsAreTyping: Bool?
    private var isUserInput: Bool {
        sendsAreTyping ?? (pasting || NSApp.currentEvent?.type == .keyDown)
    }

    // MARK: TerminalSink

    /// Output from the remote side, with Terminal.app's handling of screen clears (see
    /// `feedKeepingScrollback`). ⌘K (`clearBuffer`) still clears everything.
    public func feed(_ bytes: ArraySlice<UInt8>) {
        let bytes = images.filter(bytes)
        lastOutputAt = ProcessInfo.processInfo.systemUptime
        defer { if pendingTypedAhead != nil { resolveTypedAhead() } }
        // A tab off screen draws nothing: its output is fed in batches (a few times a second), so a
        // busy hidden terminal costs one pass through the emulator per batch instead of per read.
        if batchesWhileHidden, window == nil {
            hiddenOutput.append(contentsOf: bytes)
            if hiddenOutput.count >= 256 << 10 { flushHiddenOutput() } else if !hiddenFlushQueued {
                hiddenFlushQueued = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.flushHiddenOutput() }
            }
            return
        }
        flushHiddenOutput()
        feedNow(bytes)
    }

    /// Output of an earlier run, drawn only (see `TerminalSink.showEarlierOutput`).
    public func showEarlierOutput(_ bytes: ArraySlice<UInt8>) {
        flushHiddenOutput()
        showedEarlierOutput = true
        replayingEarlier = true
        // The recording says where the user typed (its command marks and typed clears), not this
        // terminal's keyboard: its clears are judged by those, apart from the live output's.
        let live = ruleContext
        ruleContext = ScrollbackRule.Context(keepRedraws: settings.keepRedrawnFrames, readsMarkers: true)
        defer {
            replayingEarlier = false
            ruleContext = live
            ruleContext.typed()
        }
        feedNow(ImageSequenceFilter.filtered(Array(bytes))[...])
    }

    /// The earlier output shown is only the end of a longer recording.
    public func earlierOutputIsPartial() { earlierOutputCut = true }

    /// Tether is about to clear the screen to draw it again (a re-attach): kept, as typed clears are.
    public func screenWillBeRedrawn() {
        flushHiddenOutput()     // a program's clear held back must not take this one's place
        ruleContext.typed()
    }

    /// Return was pressed (or a command typed while away was sent): a mark on the cursor's line.
    /// Returns whether one was made (none on the line of the last one, or on a full screen).
    @discardableResult
    private func markCommandAtCursor() -> Bool {
        defer { inputStart = nil; typedOnLine = false; typedText = ""; typedAhead = false }
        // Return alone with nothing before the cursor (no prompt, nothing typed): pressed while a
        // program's output goes on, not a command. (Typed ahead of the prompt it is one.)
        guard !isAlternateScreen, getTerminal().getCursorLocation().x > 0 || typedOnLine else { return false }
        // On the line's first row: a command longer than the terminal is wide wrapped below it.
        let line = lineStart(at: promptLine)
        guard markEntries.last?.line != line else { return false }
        let column = inputColumn(onLine: line)
        let time = session?.noteCommand(column: column)
        markEntries.append(MarkEntry(line: line, time: time, column: column))
        if markEntries.count > 5000 { markEntries.removeFirst(markEntries.count - 5000) }
        return time != nil
    }

    /// Where typing started on the line starting at row `line`, in cells from its start (nil:
    /// typing started on another line, or nothing was typed here).
    private func inputColumn(onLine line: Int) -> Int? {
        guard let start = inputStart, start.row >= line, lineStart(at: start.row) == line else { return nil }
        return (start.row - line) * getTerminal().cols + start.column
    }

    /// The user is about to send `data`: the first key on a line notes where the cursor is (the
    /// end of the prompt). Ctrl+C and Return end the line.
    private func noteInput(_ data: ArraySlice<UInt8>) {
        guard !isAlternateScreen else { inputStart = nil; return }
        if inputStart == nil {
            let t = getTerminal()
            inputStart = (promptLine, t.getCursorLocation().x)
            typedAhead = ProcessInfo.processInfo.systemUptime - lastOutputAt < Self.busyBeforeTyping && !(data.first == 0x0d)
        }
        // Up to the first Return: typed on the line being run.
        let line = data.prefix(while: { $0 != 0x0d })
        if line.contains(where: { $0 != 0x0a }) { typedOnLine = true }
        if var text = typedText {
            var bytes: [UInt8] = []
            for b in line {
                if b == 0x7f || b == 0x08 {
                    if !bytes.isEmpty { bytes.removeLast() } else if !text.isEmpty { text.removeLast() }
                } else if b >= 0x20 { bytes.append(b) } else { typedText = nil; break }
            }
            if typedText != nil { typedText = text + String(decoding: bytes, as: UTF8.self) }
        }
        if data.contains(0x03) { inputStart = nil; typedOnLine = false; typedText = ""; typedAhead = false }
    }

    /// Whether the line starting at row `line` ends in `text` after a prompt (something that is
    /// not part of a word right before it): where a shell shows a command typed.
    private func showsCommand(_ text: String, onLine line: Int) -> Bool {
        commandColumn(text, onLine: line) != nil
    }

    /// Where `text` starts on the line starting at row `line`, when the line ends in it after a prompt.
    private func commandColumn(_ text: String, onLine line: Int) -> Int? {
        let shown = BufferSearch.lineText(in: getTerminal(), row: line).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        guard shown.hasSuffix(text), shown.count > text.count, let before = shown.dropLast(text.count).last,
              !before.isLetter, !before.isNumber, shown.dropLast(text.count).contains(where: { !$0.isWhitespace }) else { return nil }
        return shown.count - text.count
    }

    /// A command typed ahead of a program's output: once the shell shows a line ending in it
    /// (after a prompt) where Return was pressed or below, it is marked there; after
    /// `typedAheadWait` (or `giveUp`), where Return was pressed.
    private func resolveTypedAhead(giveUp: Bool = false) {
        guard let pending = pendingTypedAhead else { return }
        let t = getTerminal()
        let trimmed = t.buffer.totalLinesTrimmed
        let cursor = promptLine
        // From the line Return was pressed on (the shell echoing it there just after: typed fast)
        // — there only after a prompt, which a program's output line is not.
        var row = max(pending.row, trimmed)
        var found: (line: Int, column: Int)?
        while row <= cursor, found == nil {
            let start = lineStart(at: row)
            if let column = commandColumn(pending.text, onLine: start) { found = (start, column) }
            row = wrappedRows(from: start).upperBound + 1
        }
        let expired = ProcessInfo.processInfo.systemUptime - pending.since >= Self.typedAheadWait
        guard found != nil || giveUp || expired else { return }
        pendingTypedAhead = nil
        let line = found?.line ?? lineStart(at: max(pending.row, trimmed))
        guard line >= trimmed, line < cursor || found != nil, !isAlternateScreen, markEntries.last.map({ $0.line < line }) ?? true else { return }
        // Lines from it to the cursor's, for the recording (where the cursor is when it is noted).
        var up = 0, at = lineStart(at: cursor)
        while at > line, up < 10_000 { at = lineStart(at: at - 1); up += 1 }
        let time = session?.noteCommand(column: found?.column, up: up)
        markEntries.append(MarkEntry(line: line, time: time, column: found?.column))
        if markEntries.count > 5000 { markEntries.removeFirst(markEntries.count - 5000) }
    }

    public func heldCommandSent() {
        typedOnLine = true
        markCommandAtCursor()
        ruleContext.typed()
    }

    /// A command's marker (`mark=<ms>`) in earlier output being shown: a mark at the cursor's line.
    private func noteReplayedMark(_ payload: ArraySlice<UInt8>) {
        guard !isAlternateScreen else { return }
        let text = String(decoding: payload, as: UTF8.self)
        guard text.hasPrefix("mark="), let mark = RecordingIndex.parseMark(Array(text.utf8).dropFirst(5)) else { return }
        let time = mark.time
        let t = getTerminal()
        // Return pressed during output, as an earlier version noted it (its markers say no column).
        guard mark.column != nil || t.getCursorLocation().x > 0 else { return }
        // The cursor's scroll-invariant row (not through `bufferLineCount`: this runs while feeding).
        var end = t.buffer.totalLinesTrimmed, hi = end + 4_000_000
        while end < hi {
            let mid = (end + hi) / 2
            if t.getScrollInvariantLine(row: mid) != nil { end = mid + 1 } else { hi = mid }
        }
        let line = lineStart(at: end - t.rows + t.getCursorLocation().y, linesUp: mark.up)
        guard markEntries.last.map({ $0.line < line }) ?? true, !markEntries.contains(where: { $0.time == time }) else { return }
        markEntries.append(MarkEntry(line: line, time: time, column: mark.column))
        if markEntries.count > 5000 { markEntries.removeFirst(markEntries.count - 5000) }
    }

    /// While earlier output is fed: what it asks of the terminal is not done.
    private(set) var replayingEarlier = false

    /// Set for the app's tab views (`TerminalRegistry`); a view used on its own feeds at once.
    var batchesWhileHidden = false
    private var hiddenOutput: [UInt8] = []
    private var hiddenFlushQueued = false

    /// Feeds what a hidden tab has waiting (also before anything reads the screen).
    public func flushHiddenOutput() {
        hiddenFlushQueued = false
        guard !hiddenOutput.isEmpty else { return }
        let bytes = hiddenOutput
        hiddenOutput = []
        feedNow(bytes[...])
    }

    private func feedNow(_ bytes: ArraySlice<UInt8>) {
        // A clear can arrive cut in two by the network (`ESC[` now, `3J` next): the start is held
        // back until the rest comes (or 50 ms later), so the scrollback rule always sees it whole.
        textVersion &+= 1
        scrollerNeedsUpdate()
        var chunk = heldEscape + Array(bytes)
        heldEscape = []
        if let cut = Self.partialEraseStart(chunk) {
            heldEscape = Array(chunk[cut...])
            chunk.removeSubrange(cut...)
            let held = heldEscape
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.heldEscape == held, !held.isEmpty else { return }
                self.heldEscape = []
                self.textVersion &+= 1
                self.ruleContext.keepRedraws = self.settings.keepRedrawnFrames
                self.coalescingScrolls { self.feedKeepingScrollback(held[...], programsMayClear: self.settings.programsMayClearScrollback,
                                                                    context: &self.ruleContext,
                                                                    cleared: { [weak self] in self?.noteClear() }) }
            }
        }
        if !chunk.isEmpty {
            if !isAlternateScreen, Self.entersAlternateScreen(chunk) {
                var held = holdPlaces()
                held.atBottom = true        // the program's screen ends at the bottom
                placesBeforeFullScreen = held
            }
            syncMouseReporting()
            coalescingScrolls {
                ruleContext.keepRedraws = settings.keepRedrawnFrames
                feedKeepingScrollback(chunk[...], programsMayClear: settings.programsMayClearScrollback,
                                      context: &ruleContext, cleared: { [weak self] in self?.noteClear() })
            }
            syncMouseReporting()
        }
    }

    /// SwiftTerm reports a scroll for every line that scrolls (a fast `yes` is tens of thousands per
    /// read), and each report moves the scroller and runs `scrolled(source:position:)`: during a
    /// feed they are held, and the last position is reported once afterwards.
    private var feeding = false
    private var scrolledWhileFeeding = false

    private func coalescingScrolls(_ body: () -> Void) {
        guard !feeding else { body(); return }
        feeding = true
        body()
        feeding = false
        if scrolledWhileFeeding {
            scrolledWhileFeeding = false
            super.scrolled(source: getTerminal(), yDisp: getTerminal().buffer.yDisp)
        }
    }

    public override func scrolled(source terminal: Terminal, yDisp: Int) {
        if feeding { scrolledWhileFeeding = true; return }
        super.scrolled(source: terminal, yDisp: yDisp)
    }

    /// This terminal's own choice (View ▸ Allow Mouse Reporting, ⌘R); nil follows Settings.
    public var mouseReportingChoice: Bool? {
        didSet { syncMouseReporting() }
    }

    /// Whether programs in this terminal may use the mouse, as the menu shows it.
    public var mouseReportingAllowed: Bool { mouseReportingChoice ?? settings.allowMouseReporting }

    /// SwiftTerm drops the selection on every output and line feed while mouse reporting is
    /// allowed — whether or not the program asked for the mouse — so text selected in the history
    /// vanished as soon as a command printed again. Reporting is only allowed while a program has
    /// turned mouse tracking on (vim, htop, tmux with `mouse on`), the only time it reports
    /// anything anyway; otherwise a selection stays while output streams.
    private func syncMouseReporting() {
        let tracking = getTerminal().mouseMode != .off
        if !tracking { mouseTrackingSince = nil } else if mouseTrackingSince == nil { mouseTrackingSince = Date() }
        let wanted = mouseReportingAllowed && tracking
        if allowMouseReporting != wanted { allowMouseReporting = wanted }
    }

    /// When a program turned mouse tracking on (nil: off).
    private var mouseTrackingSince: Date?

    /// When the shell was last seen waiting at its prompt (nil: a program runs, or it cannot be
    /// told), set by the app from what it knows about the terminal (tmux, the command watcher).
    public var shellSeenAt: (() -> Date?)?

    /// Mouse tracking left on by a program that has ended goes before the wheel or a click is
    /// handled: the wheel scrolls the history again and clicks select (see `StaleMouseTracking`).
    func dropStaleMouseTracking() {
        guard StaleMouseTracking.isStale(trackingSince: mouseTrackingSince, shellSeenAt: shellSeenAt?(),
                                         alternateScreen: isAlternateScreen, userChoice: mouseReportingChoice) else { return }
        feed(byteArray: StaleMouseTracking.reset[...])
        syncMouseReporting()
    }

    // MARK: Clears and a taller terminal

    /// The scroll-invariant row at the top of the screen right after the last clear: what is above
    /// it was cleared away into the scrollback.
    private var clearTop: Int?

    private func noteClear() {
        let t = getTerminal()
        clearTop = ScrollbackRule.lineCount(t) - t.rows
    }

    /// The terminal getting taller pulls lines back down from the scrollback (like xterm). After a
    /// clear those are the cleared screen, and the prompt would move down mid-screen: they go back up.
    private func keepClearedScreenUp() {
        let t = getTerminal()
        guard let clearTop, !t.isCurrentBufferAlternate, t.buffer.scrollTop == 0, t.buffer.scrollBottom == t.rows - 1 else { return }
        let top = ScrollbackRule.lineCount(t) - t.rows
        let pulled = clearTop - top
        let cursor = t.getCursorLocation()
        guard pulled > 0, cursor.y >= pulled else { return }
        textVersion &+= 1
        let scroll = "\u{1b}[\(t.rows);1H" + String(repeating: "\n", count: pulled) + "\u{1b}[\(cursor.y - pulled + 1);\(cursor.x + 1)H"
        feed(byteArray: Array(scroll.utf8)[...])
    }

    /// Resizes the terminal as a layout change does (for tests), keeping a cleared screen cleared.
    func resizeKeepingPrompt(cols: Int, rows: Int) {
        flushHiddenOutput()
        getTerminal().resize(cols: cols, rows: rows)
        keepClearedScreenUp()
    }

    /// Bytes held back by `feed` (the start of an erase sequence).
    private var heldEscape: [UInt8] = []

    /// Where an erase-in-display sequence starts but is cut off at the end of `bytes`
    /// (`ESC`, `ESC[`, `ESC[2`, `ESC[3`, `ESC[0`), or nil.
    static func partialEraseStart(_ bytes: [UInt8]) -> Int? {
        let n = bytes.count
        for length in (1...3).reversed() where n >= length {
            let tail = bytes[(n - length)...]
            guard tail.first == 0x1b else { continue }
            if length == 1 { return n - 1 }
            guard tail[tail.startIndex + 1] == 0x5b else { continue }
            if length == 2 { return n - 2 }
            if [0x30, 0x32, 0x33].contains(tail[tail.startIndex + 2]) { return n - 3 }
        }
        return nil
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
        noteShown(window != nil)
        if window != nil {
            // How long showing this tab held the main thread (until it turned again): a slow one is
            // noted in Console, so a tab switch that feels slow says how slow.
            let shown = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                let took = ProcessInfo.processInfo.systemUptime - shown
                if took > 0.1 {
                    Logger(subsystem: "io.github.whileendless.tether", category: "app")
                        .notice("Showing a tab took \(Int(took * 1000)) ms")
                }
            }
        }
        scrollerNeedsUpdate()
    }

    // MARK: Memory of tabs not on screen

    /// Lines a tab keeps in memory after a minute off screen, when its recording holds the rest
    /// (scrolling up reads them back, as for any older output). Every line of the scrollback costs
    /// about 24 bytes per column: 10,000 lines of a wide terminal are 30–50 MB, times every tab.
    static let hiddenScrollbackLines = 2_000
    private var shrunkWhileHidden = false
    private var shrinkWhileHidden: DispatchWorkItem?

    private var scrollbackLimit: Int {
        shrunkWhileHidden ? min(settings.scrollbackLines, Self.hiddenScrollbackLines) : settings.scrollbackLines
    }

    private func noteShown(_ shown: Bool) {
        shrinkWhileHidden?.cancel()
        shrinkWhileHidden = nil
        if shown {
            flushHiddenOutput()
            // Output that came while hidden, and the scrollback made smaller meanwhile: all of it again.
            if let findSession {
                findSession.changedFrom = nil
                findBufferChanged()
            }
            guard shrunkWhileHidden else { return }
            shrunkWhileHidden = false
            resizeScrollback(scrollbackLimit)     // room again; older lines come back from disk
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.shrinkHidden() }
        shrinkWhileHidden = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    func shrinkHidden() {
        flushHiddenOutput()
        // Off screen for a minute while scrolled back: back to the live end (then kept small).
        if isBrowsingHistory { returnToLive() }
        guard window == nil, hasHistoryOnDisk, !selection.active,
              settings.scrollbackLines > Self.hiddenScrollbackLines else { return }
        shrunkWhileHidden = true
        resizeScrollback(scrollbackLimit)
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
        // The history view is measured with it (its lines wrap as these do): back to live first.
        if isBrowsingHistory { returnToLive() }
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
        // A history view kept for going back has its places at the old cells: let go of. One still
        // reading is measured again too (the same font, other cells on another screen).
        discardHistory()
        history?.font = newFont
        reportFontResize()
    }

    /// A new font changes the grid at once, so the program must hear the new size at once too:
    /// waiting (the resize debounce, or a hidden tab until it is shown) leaves full-screen programs
    /// (vim, htop) drawn for the old size on the new grid. A tab not in a window still has the frame
    /// of its last layout, so its size is the real one — once it has been laid out at all.
    private func reportFontResize() {
        guard hasRealSize, bounds.width > 0, bounds.height > 0 else { return }
        let size = cellSize
        guard size.cols > 0, size.rows > 0 else { return }
        pendingResize?.cancel()
        pendingResize = nil
        needsDisplay = true
        if let last = lastSentSize, last == size { return }
        lastSentSize = size
        session?.terminalDidResize(cols: size.cols, rows: size.rows)
    }

    /// Widths this view was given (tests: a tab switch must not pass through other sizes).
    var frameWidthsSeen: [CGFloat] = []

    public override func setFrameSize(_ newSize: NSSize) {
        // A size of a few cells is a layout on its way (a host not sized yet), never one to show:
        // wrapping the whole scrollback for it, and back, would cost a moment and could push
        // lines out. The frame stays as it is until a real size comes. (`.zero` itself is
        // `setFont`'s: SwiftTerm only measures then.)
        if frame.width >= 40, newSize != .zero, newSize.width < 40 || newSize.height < 20 { return }
        if frameWidthsSeen.count < 64, newSize.width != frame.width { frameWidthsSeen.append(newSize.width) }
        // Another width wraps long lines differently: the command marks, the command jumped to and
        // the line at the top of the view stay on their text.
        // `setFont`'s measuring (to no size and back) changes no columns: nothing is looked through.
        guard newSize.width != frame.width, !isAlternateScreen, newSize != .zero, frame.size != .zero else {
            super.setFrameSize(newSize)
            keepClearedScreenUp()
            reportSizeIfNeeded()
            drawFind()
            return
        }
        flushHiddenOutput()
        let held = holdPlaces()
        super.setFrameSize(newSize)
        restorePlaces(held)
        keepClearedScreenUp()
        reportSizeIfNeeded()
        drawFind()
    }

    /// The command marks, the command jumped to, the line at the top and the last clear's place,
    /// as places in the text of the normal screen (see `ReflowPlaces`).
    private struct HeldPlaces {
        var places: ReflowPlaces
        var marks: Int
        var cols: Int
        var atBottom: Bool
        /// The last ⌘↑ / ⌘↓, when the view was still where it left it.
        var jump: JumpPlace?
    }

    private func holdPlaces() -> HeldPlaces {
        let t = getTerminal()
        let trimmed = t.buffer.totalLinesTrimmed
        let markRows = markEntries.map { $0.line - trimmed }
        let jump = currentJump
        let places = ReflowPlaces(self, rows: markRows + [jump?.line.map { $0 - trimmed } ?? -1, t.buffer.yDisp,
                                                          clearTop.map { $0 - trimmed } ?? -1])
        return HeldPlaces(places: places, marks: markRows.count, cols: t.cols,
                          atBottom: t.buffer.yDisp >= bufferLineCount - t.rows, jump: jump)
    }

    /// After the normal screen's lines were wrapped again for another width: the places held go
    /// back on their text.
    private func restorePlaces(_ held: HeldPlaces) {
        let cols = getTerminal().cols
        guard cols != held.cols else { return }
        let now = held.places.rows(in: self)
        // Lines a narrower width pushed out of the scrollback: counted (they are in the
        // recording, and scrolling up or Find goes on there), and a history view kept for the
        // seam with this terminal is made again.
        let dropped = cols < held.cols ? held.places.droppedRows(in: self) : 0
        if dropped > 0 {
            droppedByResize += dropped
            textVersion &+= 1
            discardHistory()
        }
        let newTrimmed = getTerminal().buffer.totalLinesTrimmed
        let n = held.marks
        markEntries = zip(markEntries, now.prefix(n)).compactMap { e, r in r.map { MarkEntry(line: $0 + newTrimmed, time: e.time, column: e.column) } }
        clearTop = clearTop == nil ? nil : now[n + 2].map { $0 + newTrimmed }
        blockSelection = nil
        if !held.atBottom, let top = now[n + 1] { scrollTo(row: top) }
        // The command jumped to is on its text again, and the view where it was: on from there.
        jumpPlace = held.jump.flatMap { j in
            if j.line == nil { return jumpPlace(line: nil, atBottom: true) }
            return now[n].map { jumpPlace(line: $0 + newTrimmed, atBottom: isScrolledToBottom) }
        }
    }

    /// Held as a full-screen program's screen comes up: SwiftTerm wraps the normal screen's lines
    /// again when the width changes meanwhile, out of sight, and they go back on their text when
    /// it ends.
    private var placesBeforeFullScreen: HeldPlaces?

    /// Whether `bytes` switch to a full-screen program's screen.
    static func entersAlternateScreen(_ bytes: [UInt8]) -> Bool {
        guard bytes.contains(0x1b) else { return false }
        return ["\u{1b}[?1049h", "\u{1b}[?1047h", "\u{1b}[?47h"].contains { bytes.firstRange(of: Array($0.utf8)) != nil }
    }

    public override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        guard !source.isCurrentBufferAlternate, let held = placesBeforeFullScreen else { return }
        placesBeforeFullScreen = nil
        restorePlaces(held)
    }

    public func screenCursorRow() -> Int? {
        flushHiddenOutput()
        let t = getTerminal()
        return t.isCurrentBufferAlternate ? nil : t.getCursorLocation().y
    }

    public func screenTail(maxRows: Int) -> (lines: [String], lastRow: Int)? {
        flushHiddenOutput()
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
        returnToLive()
        session?.send(bytes[...])
    }

    /// Every screen update: the cursor view is shown or hidden here (`SteadyCaret`), never taken out.
    ///
    /// A program that redraws all the time (a coding agent's spinner and status, `top`) is drawn
    /// about 15 times a second while nobody types here, about 5 while Tether or this window is not
    /// in front — instead of up to 60: drawing is most of what a terminal costs. Right after a key,
    /// a click or a scroll, and while the window is resized, every update is drawn at once.
    public override func setNeedsDisplay(_ invalidRect: NSRect) {
        let hold = Self.drawHold(for: window, lastInput: Self.lastInput)
        guard hold > 0 else {
            // What was held goes with it, not after it.
            let rect = heldDirty.map { $0.union(invalidRect) } ?? invalidRect
            heldDirty = nil
            super.setNeedsDisplay(rect)
            syncCaret()
            return
        }
        heldDirty = heldDirty.map { $0.union(invalidRect) } ?? invalidRect
        guard !heldFlushQueued else { return }
        heldFlushQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in self?.flushHeldDisplay() }
    }

    private var heldDirty: NSRect?
    private var heldFlushQueued = false

    private func flushHeldDisplay() {
        heldFlushQueued = false
        guard let rect = heldDirty else { return }
        heldDirty = nil
        super.setNeedsDisplay(rect)
        syncCaret()
    }

    /// When the user last typed, clicked or scrolled in Tether (system uptime).
    nonisolated(unsafe) static var lastInput: TimeInterval = 0
    /// Tests: the hold to use instead of the one worked out.
    nonisolated(unsafe) static var drawHoldOverride: TimeInterval?

    /// How long an update waits to be drawn (SwiftTerm already gathers them for a 60th of a second).
    static func drawHold(for window: NSWindow?, lastInput: TimeInterval) -> TimeInterval {
        if let drawHoldOverride { return drawHoldOverride }
        guard let window, window.isVisible, !window.inLiveResize else { return 0 }
        if ProcessInfo.processInfo.systemUptime - lastInput < 0.6 { return 0 }
        if NSApp?.isActive == true && window.isKeyWindow { return foregroundHold }
        return backgroundHold
    }

    /// Holds for about 15 and 5 drawings a second (SwiftTerm's own 60th of a second comes on top).
    /// Measured with `RenderCostProbe` (a coding agent's redraws): 35% CPU at 0.032 s, 31% at
    /// 0.066 s, 22% in the background; spinners still move smoothly at 15.
    static let foregroundHold: TimeInterval = 0.05
    static let backgroundHold: TimeInterval = 0.18

    private static var inputMonitor: Any?

    /// Notes the user's keys, clicks and scrolls (one watcher for every terminal).
    static func watchInput() {
        guard inputMonitor == nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseDragged,
                                                                   .rightMouseDown, .scrollWheel, .flagsChanged]) { event in
            lastInput = ProcessInfo.processInfo.systemUptime
            return event
        }
    }

    /// The program shows the cursor (SwiftTerm says so through these).
    private var cursorShown = true

    public override func showCursor(source: Terminal) {
        cursorShown = true
        super.showCursor(source: source)
        syncCaret()
    }

    public override func hideCursor(source: Terminal) {
        cursorShown = false
        super.hideCursor(source: source)
        syncCaret()
    }

    private func syncCaret() {
        guard window != nil else { return }
        let t = getTerminal()
        // Rows in the buffer, without feeding what a hidden tab holds back (`bufferLineCount` would).
        var lo = t.buffer.totalLinesTrimmed, hi = lo + 4_000_000
        while lo < hi {
            let mid = (lo + hi) / 2
            if t.getScrollInvariantLine(row: mid) != nil { lo = mid + 1 } else { hi = mid }
        }
        let row = lo - t.buffer.totalLinesTrimmed - t.rows + t.getCursorLocation().y
        SteadyCaret.sync(self, shown: cursorShown, onScreen: row >= t.buffer.yDisp && row < t.buffer.yDisp + t.rows)
    }

    /// Copy is offered for what is selected where the user sees it: here, in the recording shown
    /// over this terminal, or whole commands selected there (SwiftTerm looks at this view only).
    public override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return commandSelection != nil || (isBrowsingHistory ? history?.selection.active == true : selection.active)
        }
        if item.action == #selector(selectAllShown(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    /// Right click (or Control-click): Copy, Paste and Select All for what is shown — the
    /// recording while it is shown.
    public override func menu(for event: NSEvent) -> NSMenu? { editMenu() }

    func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = true
        for (title, action, key) in [("Copy", #selector(copy(_:)), "c"), ("Paste", #selector(paste(_:)), "v"),
                                     ("Select All", #selector(selectAllShown(_:)), "a")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    /// Select All from the menu: the recording's rows while it is shown, else this terminal's.
    @objc func selectAllShown(_ sender: Any?) {
        if isBrowsingHistory, let history { history.selectAll(sender); history.needsDisplay = true } else { selectAll(sender) }
    }

    /// ⌘C while browsing the recording copies what is selected there.
    public override func copy(_ sender: Any) {
        if commandSelection != nil { copyCommandSelection(); return }
        if isBrowsingHistory, let history, history.selection.active { history.copy(sender); return }
        super.copy(sender)
    }

    /// Clears the scrollback and screen locally (⌘K).
    public func clearBuffer() {
        flushHiddenOutput()
        // What was shown of the recording, a part on its way and commands jumped to or selected go.
        returnToLive()
        clearCommandSelection()
        historyJump = nil
        textVersion &+= 1
        feed(byteArray: Array("\u{1b}[H\u{1b}[2J\u{1b}[3J".utf8)[...])
        markEntries.removeAll()
        inputStart = nil
        jumpPlace = nil
        blockSelection = nil
        clearTop = nil
        showedEarlierOutput = false
        earlierOutputCut = false
        // Ask the shell to redraw its prompt.
        if session?.phase.isOnline == true { session?.send([0x0c][...]) }
    }

    // MARK: Scrolling, marks and selection (Terminal.app behaviour)

    /// Marks as current buffer rows (dropping those already trimmed from scrollback).
    var marks: [Int] {
        let trimmed = getTerminal().buffer.totalLinesTrimmed
        return markLines.map { $0 - trimmed }.filter { $0 >= 0 }
    }

    var isAlternateScreen: Bool { getTerminal().isCurrentBufferAlternate }

    func scrollPage(up: Bool) {
        let n = max(getTerminal().rows - 1, 1)
        // Already at the top: Page Up goes on into the recording.
        if up, getTerminal().buffer.yDisp == 0 { requestOlderHistory(); return }
        if up { scrollUp(lines: n) } else { scrollDown(lines: n) }
    }

    /// Scrolls to buffer row `row` for Tether (a find, ⌘↑): reaching the top this way is not the
    /// user going on into the recording, even right after a wheel step.
    func placeView(row: Int) {
        placingView = true
        defer { placingView = false }
        scrollTo(row: row)
    }

    func scrollToTop() { scrollTo(row: 0) }
    func scrollToBottom() { scrollTo(row: Int.max / 2) }

    /// Rows shown above a command jumped to (a little of what came before it).
    static let jumpContext = 2

    /// Where ⌘↑ / ⌘↓ go from in the live terminal.
    private enum JumpTarget { case line(Int), earlier, prompt, nowhere }

    /// The scroll-invariant row at the top of the view.
    private var topLine: Int { getTerminal().buffer.yDisp + getTerminal().buffer.totalLinesTrimmed }
    /// The view shows the live end (and follows the output).
    private var isScrolledToBottom: Bool { getTerminal().buffer.yDisp >= max(bufferLineCount - getTerminal().rows, 0) }
    /// The scroll-invariant row of the line being typed on.
    private var promptLine: Int { cursorRowInBuffer + getTerminal().buffer.totalLinesTrimmed }

    /// The last ⌘↑ / ⌘↓, while the view is still where it left it (see `JumpPlace`).
    private var currentJump: JumpPlace? {
        guard let j = jumpPlace, !isAlternateScreen else { return nil }
        // Another match chosen since (⌘G on the same screen): on from that one.
        guard j.match == findMatchOnScreen else { return nil }
        let top = topLine
        if j.top == top { return j }
        // Left at the live end, which follows the output: still there, with the command on screen.
        if j.atBottom, isScrolledToBottom, (j.line ?? top) >= top { return j }
        return nil
    }

    /// The scroll-invariant row of the find's current match, when it is on screen.
    private var findMatchOnScreen: Int? {
        guard let s = findSession, s.currentEarlier == nil, let c = s.current, s.matches.indices.contains(c) else { return nil }
        let row = s.matches[c].row, top = topLine
        return row >= top && row < top + getTerminal().rows ? row : nil
    }

    /// Where ⌘↑ / ⌘↓ go in the live terminal: on from the command last jumped to while the view is
    /// still there; else from what is on screen — the find's match, the line being typed on at the
    /// live end, or the top of the screen (scrolled back with the wheel, the scroller, ⌘↑ earlier).
    private func liveJumpTarget(up: Bool) -> JumpTarget {
        let trimmed = getTerminal().buffer.totalLinesTrimmed
        let prompt = promptLine
        let lines = markLines.filter { $0 >= trimmed && $0 < prompt }
        // ⌘↑ goes to the last command before `before`, ⌘↓ to the first after `after`.
        let before: Int, after: Int
        var atPrompt = false
        if let j = currentJump {
            if let line = j.line { (before, after) = (line, line) } else { (before, after, atPrompt) = (prompt, prompt, true) }
        } else if let match = findMatchOnScreen {
            (before, after) = (match + 1, match)          // the command it is in, or the next one
        } else if isScrolledToBottom {
            (before, after, atPrompt) = (prompt, prompt, true)
        } else {
            let anchor = topLine + Self.jumpContext       // where a command jumped to would be
            (before, after) = (anchor, anchor)
        }
        if up { return lines.last { $0 < before }.map(JumpTarget.line) ?? .earlier }
        return lines.first { $0 > after }.map(JumpTarget.line) ?? (atPrompt && isScrolledToBottom ? .nowhere : .prompt)
    }

    /// ⌘↑ / ⌘↓: jump to the previous/next command and briefly highlight it (Terminal.app's marks).
    func jumpToMark(up: Bool) {
        flushHiddenOutput()
        clearCommandSelection()
        // Pressed again while the last one's part of the recording is being read: on from that one.
        if let pending = pendingJump {
            if history?.loading == true {
                guard let index = exactIndex else { pendingJump = nil; beep(); return }
                let target = up ? pending - 1 : pending + 1
                guard target >= 0 else { beep(); return }
                go(toCommand: target, index: index, up: up)
                return
            }
            pendingJump = nil
        }
        if isBrowsingHistory { jumpInHistory(up: up); return }
        guard !isAlternateScreen else { beep(); return }    // a full-screen program has no commands
        switch liveJumpTarget(up: up) {
        case .line(let line): land(onLine: line)
        case .prompt: landOnPrompt()
        case .nowhere: beep()
        case .earlier:
            // Before the first command in memory: the one before it, in the recording.
            if let index = exactIndex, earlierMarks(index) > 0 {
                showCommand(at: earlierMarks(index) - 1, index: index, up: true)
            } else {
                beep()
            }
        }
    }

    /// Shows the command at scroll-invariant row `line` near the top, selects what was typed there
    /// (⌘C copies it) and highlights its line.
    private func land(onLine line: Int) {
        let trimmed = getTerminal().buffer.totalLinesTrimmed
        blockSelection = nil
        placeView(row: max(line - trimmed - Self.jumpContext, 0))
        jumpPlace = jumpPlace(line: line, atBottom: isScrolledToBottom)
        selectCommand(line: line, column: markEntries.last { $0.line == line }?.column)
        let rows = wrappedRows(from: line)
        highlight(rows: (rows.lowerBound - trimmed)...(rows.upperBound - trimmed))
        needsDisplay = true
    }

    /// After the last command: the line being typed on, as the last stop.
    private func landOnPrompt() {
        blockSelection = nil
        selection.selectNone()
        scrollToBottom()
        let row = cursorRowInBuffer
        highlight(rows: row...row)
        jumpPlace = jumpPlace(line: nil, atBottom: true)
    }

    /// ⇧⌘↑ / ⇧⌘↓: select whole commands (prompt line + output), like Terminal.app.
    /// - Without a selection: the command ⌘↑ / ⌘↓ would go to (from the prompt, ⇧⌘↑ the last one);
    ///   right after ⌘↑ / ⌘↓, the command jumped to.
    /// - With one: one command more upwards (⇧⌘↑) or downwards (⇧⌘↓).
    func selectToMark(up: Bool) {
        flushHiddenOutput()
        if commandSelection != nil || isBrowsingHistory {
            extendCommandSelection(up: up)
            return
        }
        guard !isAlternateScreen else { beep(); return }
        let trimmed = getTerminal().buffer.totalLinesTrimmed
        let prompt = promptLine
        let starts = markLines.filter { $0 >= trimmed && $0 < prompt }
        func blockEnd(_ start: Int) -> Int { max((starts.first { $0 > start } ?? prompt) - 1, start) }
        // Output went on: what of the selection left memory is not in it any more.
        if let current = blockSelection, current.lowerBound < trimmed {
            blockSelection = current.upperBound >= trimmed ? trimmed...current.upperBound : nil
            if blockSelection == nil { selection.selectNone() }
        }

        let range: ClosedRange<Int>?
        if let current = blockSelection {
            if up {
                range = starts.last { $0 < current.lowerBound }.map { $0...current.upperBound }
            } else {
                range = starts.first { $0 > current.upperBound }.map { current.lowerBound...blockEnd($0) }
            }
        } else if let line = currentJump?.line {
            range = line...blockEnd(line)
        } else if case .line(let line) = liveJumpTarget(up: up) {
            range = line...blockEnd(line)
        } else {
            range = nil
        }
        guard let range else {
            // Further back than memory: the selection goes on in the recording.
            if up, let index = exactIndex, earlierMarks(index) > 0 {
                let end: Int?
                if let current = blockSelection, let next = starts.first(where: { $0 > current.upperBound }) {
                    end = indexPosition(ofLiveMarkAt: next - trimmed, index: index)
                } else {
                    end = blockSelection == nil ? (starts.isEmpty ? nil : earlierMarks(index)) : nil
                }
                let first = blockSelection == nil && starts.isEmpty ? index.marks.count - 1 : earlierMarks(index) - 1
                setCommandSelection(CommandSelection(first: first, end: end), index: index)
                return
            }
            beep()
            return
        }
        blockSelection = range
        let rows = (range.lowerBound - trimmed)...(range.upperBound - trimmed)
        selection.setSelection(start: Position(col: 0, row: rows.lowerBound),
                               end: Position(col: getTerminal().cols, row: rows.upperBound))
        let screen = getTerminal().rows
        placeView(row: up || rows.count > screen ? max(rows.lowerBound - 1, 0) : max(rows.upperBound - screen + 2, 0))
        highlight(rows: rows)
        needsDisplay = true
    }

    // MARK: Commands beyond memory

    /// The recording's commands not in memory any more: those before the first mark here (the
    /// marks here are the recording's last ones).
    ///
    /// Matched by the time each was noted with: the two lists may differ (a mark here the recording
    /// merged with another, marks lost to a resize, a recording started again).
    private func earlierMarks(_ index: RecordingIndex) -> Int {
        let trimmed = getTerminal().buffer.totalLinesTrimmed
        let live = markEntries.filter { $0.line >= trimmed }
        for entry in live {
            if let time = entry.time, let i = index.marks.firstIndex(where: { $0.time == time }) { return i }
        }
        // Commands noted with a time, none of them in the index yet: all it has came before them.
        if live.contains(where: { $0.time != nil }) { return index.marks.count }
        return max(index.marks.count - marks.count, 0)
    }

    /// The place in the recording's index of the mark at buffer row `row` here.
    private func indexPosition(ofLiveMarkAt row: Int, index: RecordingIndex) -> Int? {
        let trimmed = getTerminal().buffer.totalLinesTrimmed
        if let time = markEntries.first(where: { $0.line - trimmed == row })?.time,
           let i = index.marks.firstIndex(where: { $0.time == time }) { return i }
        return marks.firstIndex(of: row).map { earlierMarks(index) + $0 }
    }

    /// The row here of the recording's command `position`, when it is in memory.
    private func liveRow(ofMark position: Int, index: RecordingIndex) -> Int? {
        guard index.marks.indices.contains(position) else { return nil }
        let time = index.marks[position].time
        let trimmed = getTerminal().buffer.totalLinesTrimmed
        if let e = markEntries.first(where: { $0.time == time && $0.line >= trimmed }) { return e.line - trimmed }
        // Marks here are known by their times: one not among them is not a command here.
        if markEntries.contains(where: { $0.time != nil }) { return nil }
        let live = position - earlierMarks(index)
        return marks.indices.contains(live) ? marks[live] : nil
    }

    /// The recording's command (its place in the index) jumped to while browsing, and the part
    /// shown and its top then: the next jump goes on from it while the view is still there.
    private var historyJump: (position: Int, top: Int, window: HistoryTerminalView.Window?, match: Int?)?
    /// The recording's command a jump is on its way to (its part being read): a press meanwhile
    /// goes on from it.
    private var pendingJump: Int?

    private func currentHistoryJump(_ index: RecordingIndex) -> Int? {
        guard let j = historyJump, let h = history, index.marks.indices.contains(j.position),
              h.shown == j.window, h.topInvariantRow == j.top, j.match == historyFindRow else { return nil }
        return j.position
    }

    /// The scroll-invariant row of the find's match selected in the history view, when on screen.
    private var historyFindRow: Int? {
        guard let h = history, findSession?.currentEarlier != nil, h.selection.active else { return nil }
        let t = h.getTerminal()
        let row = h.selection.start.row
        guard row >= t.buffer.yDisp, row < t.buffer.yDisp + t.rows else { return nil }
        return row + t.buffer.totalLinesTrimmed
    }

    /// The recording's command ⌘↑ / ⌘↓ go to while browsing (nil: none before; past the last one,
    /// `index.marks.count`): on from the one jumped to while the view is still there, else from
    /// what is on screen (the find's match, or the top of the view).
    private func historyJumpTarget(up: Bool, index: RecordingIndex) -> Int? {
        guard let h = history else { return nil }
        if let j = currentHistoryJump(index) { return up ? (j > 0 ? j - 1 : nil) : j + 1 }
        let before: Int, after: Int
        if let match = historyFindRow { (before, after) = (match + 1, match) } else {
            let anchor = h.topInvariantRow + Self.jumpContext
            (before, after) = (anchor, anchor)
        }
        return up ? h.command(before: before, in: index) : (h.command(after: after, in: index) ?? index.marks.count)
    }

    /// ⌘↑ / ⌘↓ while browsing: the previous or next command, read from the recording when it is not
    /// in the part shown; past the last one in the recording, the live terminal's.
    private func jumpInHistory(up: Bool) {
        guard let index = exactIndex, let target = historyJumpTarget(up: up, index: index) else { beep(); return }
        go(toCommand: target, index: index, up: up)
    }

    /// Goes to the recording's command `position` (its place in the index): in memory, the live
    /// terminal at it; past the last one, the line being typed on; else the recording at it.
    /// `up`: the direction gone in, to go on past a mark that ran no command (Return pressed
    /// while output went on, noted so by earlier versions).
    private func go(toCommand position: Int, index: RecordingIndex, up: Bool? = nil) {
        guard position >= 0 else { beep(); return }
        if position >= index.marks.count || position >= earlierMarks(index) {
            returnToLive()
            // A full-screen program came up meanwhile: its screen has no commands.
            guard !isAlternateScreen else { beep(); return }
            let trimmed = getTerminal().buffer.totalLinesTrimmed
            if position < index.marks.count, let row = liveRow(ofMark: position, index: index) {
                land(onLine: row + trimmed)
            } else if position < index.marks.count, let up, markEntries.contains(where: { $0.time != nil }) {
                go(toCommand: position + (up ? -1 : 1), index: index, up: up)      // not a command here
            } else if let line = firstUnrecordedLiveMark(index) {
                land(onLine: line)      // run here, not noted in the recording's index yet
            } else {
                landOnPrompt()
            }
            return
        }
        showCommand(at: position, index: index, up: up)
    }

    /// The first command in memory after the recording's last one (scroll-invariant line): one the
    /// index has not noted yet (it is written a moment after Return).
    private func firstUnrecordedLiveMark(_ index: RecordingIndex) -> Int? {
        let trimmed = getTerminal().buffer.totalLinesTrimmed
        let prompt = promptLine
        let lines = markLines.filter { $0 >= trimmed && $0 < prompt }
        guard let last = index.marks.indices.last, let row = liveRow(ofMark: last, index: index) else { return lines.first }
        return lines.first { $0 > row + trimmed }
    }

    /// Shows the recording's command `position` (in the index) near the top, read from the
    /// recording unless the part shown has it.
    private func showCommand(at position: Int, index: RecordingIndex, up: Bool? = nil, then: (() -> Void)? = nil) {
        guard index.marks.indices.contains(position) else { beep(); return }
        let mark = index.marks[position]
        // A mark the part shown says ran no command: on past it.
        if isBrowsingHistory, let h = history, !h.loading, let up, h.ranNoCommand(atIndexOffset: mark.offset) {
            go(toCommand: position + (up ? -1 : 1), index: index, up: up)
            return
        }
        if isBrowsingHistory, let h = history, !h.loading, let shown = h.commands.first(where: { h.indexOffset(of: $0.mark) == mark.offset }) {
            pendingJump = nil
            placeHistory(atRow: shown.row, position: position)
            then?()
            scrollerNeedsUpdate()
            return
        }
        // A part being read (scrolled ahead, or the last jump's): this command once it is in.
        if history?.loading == true {
            pendingJump = position
            pendingCommandJump = { [weak self] in self?.showCommand(at: position, index: index, up: up, then: then) }
            return
        }
        guard historyReader != nil, isBrowsingHistory || !isAlternateScreen else { beep(); return }
        let h = makeHistory()
        let asked = browseGeneration
        pendingJump = position
        h.show(offset: mark.offset, indexed: true) { [weak self] row in
            guard let self, self.browseGeneration == asked else { return }
            self.setBrowsing(true)
            // Pressed again meanwhile: that one is shown instead (it waits for this part).
            if self.pendingJump == position {
                self.pendingJump = nil
                if let up, h.ranNoCommand(atIndexOffset: mark.offset) {
                    self.go(toCommand: position + (up ? -1 : 1), index: index, up: up)
                    return
                }
                // On the command's line (where Return was pressed), as the part's commands have it.
                let line = h.commands.first { h.indexOffset(of: $0.mark) == mark.offset }?.row ?? row
                self.placeHistory(atRow: line, position: position)
            }
            then?()
        }
        if history?.loading != true, pendingJump == position { pendingJump = nil }     // it could not start
    }

    /// The history view with the command at its scroll-invariant row `row` near the top, its line
    /// highlighted.
    private func placeHistory(atRow row: Int, position: Int) {
        guard let h = history else { return }
        let trimmed = h.getTerminal().buffer.totalLinesTrimmed
        h.scrollTo(row: max(row - trimmed - Self.jumpContext, 0))
        h.selectCommand(line: row, column: exactIndex.flatMap { $0.marks.indices.contains(position) ? $0.marks[position].column : nil })
        h.needsDisplay = true
        historyJump = (position, h.topInvariantRow, h.shown, historyFindRow)
        let rows = h.wrappedRows(from: row)
        h.flashRows((rows.lowerBound - trimmed)...(rows.upperBound - trimmed))
    }

    /// Whole commands selected further back than memory: from the start of command `first` (its
    /// place in the recording's index) to the start of command `end`, or to the prompt (nil).
    /// Copying reads it from the recording, however long it is.
    struct CommandSelection: Equatable { var first: Int; var end: Int? }
    private(set) var commandSelection: CommandSelection?
    /// Called with a description of a selection in the recording (nil when there is none).
    public var onCommandSelection: ((String?) -> Void)?

    /// `focus`: the command to show (the one just added to the selection; its first by default).
    /// A selection still names commands of this recording (a new recording starts after a retry).
    private func isValid(_ sel: CommandSelection, in index: RecordingIndex) -> Bool {
        index.marks.indices.contains(sel.first) && (sel.end.map { index.marks.indices.contains($0) && $0 > sel.first } ?? true)
    }

    private func setCommandSelection(_ selectionValue: CommandSelection, index: RecordingIndex, focus: Int? = nil) {
        guard isValid(selectionValue, in: index) else { clearCommandSelection(); beep(); return }
        blockSelection = nil
        selection.selectNone()
        commandSelection = selectionValue
        let first = index.marks[selectionValue.first]
        let endLine = selectionValue.end.map { index.marks[$0].line } ?? index.lines
        let commands = (selectionValue.end ?? index.marks.count) - selectionValue.first
        let lines = max(endLine - first.line, 1)
        onCommandSelection?("\(commands) command\(commands == 1 ? "" : "s") selected · \(lines.formatted()) line\(lines == 1 ? "" : "s")")
        showCommand(at: focus ?? selectionValue.first, index: index) { [weak self] in self?.markCommandSelectionShown(index) }
    }

    /// The history view wrapped its lines again for another width: the selection follows its text.
    func historyReflowed() {
        if commandSelection != nil, let index = historyIndex?() { markCommandSelectionShown(index) }
    }

    /// Selects in the history view what of the selection it shows.
    private func markCommandSelectionShown(_ index: RecordingIndex) {
        guard let sel = commandSelection, isValid(sel, in: index), let h = history else { return }
        let trimmed = h.getTerminal().buffer.totalLinesTrimmed
        let startRow = h.commands.first { $0.mark.line == index.marks[sel.first].line }.map { $0.row - trimmed } ?? 0
        let endRow = sel.end.flatMap { e in h.commands.first { $0.mark.line == index.marks[e].line } }.map { $0.row - trimmed - 1 }
            ?? h.bufferRows - 1
        h.selection.setSelection(start: Position(col: 0, row: max(startRow, 0)),
                                 end: Position(col: h.getTerminal().cols, row: max(endRow, startRow)))
    }

    /// ⇧⌘↑ / ⇧⌘↓ with a selection in the recording: one command more upwards, or downwards.
    /// Browsing without one: the command jumped to, or the one ⌘↑ / ⌘↓ would go to.
    private func extendCommandSelection(up: Bool) {
        guard let index = exactIndex, !index.marks.isEmpty else { beep(); return }
        if let sel = commandSelection, !isValid(sel, in: index) { clearCommandSelection() }
        guard var sel = commandSelection else {
            guard let at = currentHistoryJump(index) ?? historyJumpTarget(up: up, index: index), at < index.marks.count else {
                beep()
                return
            }
            setCommandSelection(CommandSelection(first: at, end: at + 1 < index.marks.count ? at + 1 : nil), index: index)
            return
        }
        if up {
            guard sel.first > 0 else { beep(); return }
            sel.first -= 1
            setCommandSelection(sel, index: index)
        } else {
            guard let end = sel.end else { beep(); return }
            sel.end = end + 1 < index.marks.count ? end + 1 : nil
            setCommandSelection(sel, index: index, focus: end)      // the command just added
        }
    }

    func clearCommandSelection() {
        guard commandSelection != nil else { return }
        commandSelection = nil
        history?.selection.selectNone()
        onCommandSelection?(nil)
    }

    /// ⌘C with a selection in the recording: its text, read from the recording in the background
    /// (as the terminal showed it), however long.
    /// Receives copied text instead of the pasteboard (tests).
    var copiedTextSink: ((String) -> Void)?

    public func copyCommandSelection() {
        guard let sel = commandSelection, let index = exactIndex, let reader = historyReader else { return }
        guard isValid(sel, in: index) else { clearCommandSelection(); beep(); return }
        let start = index.marks[sel.first].offset
        let end = sel.end.map { index.marks[$0].offset } ?? index.lastLineStart
        let cols = getTerminal().cols
        onCommandSelection?("Copying…")
        _ = reader { [weak self] snap in
            let base = index.partLengths.isEmpty ? 0 : index.removedLength(firstPart: RecordingParts.parts(of: snap.url).first?.number)
            let bytes = snap.bytes(from: max(start - base, 0), to: max(end - base, 0))
            let text = ScreenText.lines(from: bytes, cols: cols).joined(separator: "\n")
            DispatchQueue.main.async {
                if let sink = self?.copiedTextSink { sink(text) } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                let lines = text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
                self?.onCommandSelection?("Copied \(lines.formatted()) line\(lines == 1 ? "" : "s")")
            }
        }
    }

    /// The current mark-based selection, as scroll-invariant rows (cleared when the user types or clicks).
    private var blockSelection: ClosedRange<Int>?
    /// Where the last ⌘↑ / ⌘↓ went — a command's scroll-invariant line, or nil: the line being typed
    /// on — and the view's top then (scroll-invariant, so output trimming old lines leaves it).
    /// The next jump goes on from there only while the view is still there and the find's match on
    /// screen is the same (see `currentJump`).
    private struct JumpPlace { var line: Int?; var top: Int; var atBottom: Bool; var match: Int? }
    private var jumpPlace: JumpPlace?
    private func jumpPlace(line: Int?, atBottom: Bool) -> JumpPlace {
        JumpPlace(line: line, top: topLine, atBottom: atBottom, match: findMatchOnScreen)
    }
    /// The buffer row of the command last jumped to, while the view is where that jump left it.
    var jumpCursor: Int? {
        get { currentJump?.line.map { $0 - getTerminal().buffer.totalLinesTrimmed } }
        set {
            jumpPlace = newValue.map { jumpPlace(line: $0 + getTerminal().buffer.totalLinesTrimmed, atBottom: isScrolledToBottom) }
        }
    }

    /// How many times a jump or selection had nowhere to go (tests).
    private(set) var beeps = 0
    private func beep() {
        beeps += 1
        NSSound.beep()
    }

    /// Briefly tints buffer rows so the user sees where a jump or selection landed.
    private func highlight(rows: ClosedRange<Int>) {
        flashRows(rows, width: historyScroller.isHidden ? nil : historyScroller.frame.minX)
    }

    // MARK: Search support

    /// Changes whenever the buffer's text may have changed (output, clears, replays), so text read
    /// for search can be kept while a terminal sits still: typing a query reads 50 idle tabs once.
    private var textVersion = 0
    private struct TextKey: Equatable { var version, trimmed, cols, rows: Int }
    private var cachedScrollback: (key: TextKey, value: (base: Int, lines: [String], logicalLines: Int))?
    private var cachedLogical: (key: TextKey, value: (trimmed: Bool, lines: [String], logicalLines: Int))?
    private var dropTextCache: DispatchWorkItem?

    private var textKey: TextKey {
        let t = getTerminal()
        return TextKey(version: textVersion, trimmed: t.buffer.totalLinesTrimmed, cols: t.cols, rows: t.rows)
    }

    /// Text kept for search is let go of half a minute after it was last asked for (it is a copy of
    /// the whole scrollback).
    private func keepTextCacheForAWhile() {
        dropTextCache?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.cachedScrollback = nil; self?.cachedLogical = nil }
        dropTextCache = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// All lines of the scrollback and screen as text, plus the scroll-invariant row of the first one.
    public func scrollbackText() -> (base: Int, lines: [String], logicalLines: Int) {
        flushHiddenOutput()
        let key = textKey
        if let cachedScrollback, cachedScrollback.key == key { keepTextCacheForAWhile(); return cachedScrollback.value }
        let value = readScrollbackText()
        cachedScrollback = (key, value)
        keepTextCacheForAWhile()
        return value
    }

    private func readScrollbackText() -> (base: Int, lines: [String], logicalLines: Int) {
        let t = getTerminal()
        let base = t.buffer.totalLinesTrimmed
        var lines: [String] = []
        var logical = 0
        var row = base
        while let line = t.getScrollInvariantLine(row: row) {
            lines.append(line.translateToString(trimRight: true, skipNullCellsFollowingWide: true) { t.getCharacter(for: $0) }
                .replacingOccurrences(of: "\0", with: " "))
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
        flushHiddenOutput()
        let key = textKey
        if let cachedLogical, cachedLogical.key == key { keepTextCacheForAWhile(); return cachedLogical.value }
        let value = readLogicalText()
        cachedLogical = (key, value)
        keepTextCacheForAWhile()
        return value
    }

    /// The last command run here, as the terminal holds it: from its line (the prompt and what was
    /// typed) to the end, wrapped rows joined. nil when no command is marked in memory.
    public func lastCommandText() -> [String]? {
        flushHiddenOutput()
        let t = getTerminal()
        guard let mark = markEntries.last, mark.line >= t.buffer.totalLinesTrimmed else { return nil }
        var lines: [String] = []
        var row = mark.line
        while let line = t.getScrollInvariantLine(row: row) {
            var text = line.translateToString(trimRight: false, skipNullCellsFollowingWide: true) { t.getCharacter(for: $0) }
                .replacingOccurrences(of: "\0", with: " ")
            if row > mark.line, line.isWrapped, !lines.isEmpty { lines[lines.count - 1] += text } else {
                while text.last == " " { text.removeLast() }
                lines.append(text)
            }
            row += 1
        }
        lines = lines.map { l in var s = Substring(l); while s.last == " " { s = s.dropLast() }; return String(s) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// Whether a command is marked in memory (`lastCommandText`).
    public var hasCommandInMemory: Bool { markEntries.last.map { $0.line >= getTerminal().buffer.totalLinesTrimmed } ?? false }

    private func readLogicalText() -> (trimmed: Bool, lines: [String], logicalLines: Int) {
        let t = getTerminal()
        let base = t.buffer.totalLinesTrimmed
        var lines: [String] = []
        var row = base
        while let line = t.getScrollInvariantLine(row: row) {
            let text = line.translateToString(trimRight: false, skipNullCellsFollowingWide: true) { t.getCharacter(for: $0) }
                .replacingOccurrences(of: "\0", with: " ")
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

    /// How many lines memory holds (as `logicalText` counts them: blank ones at the end left
    /// out) and the first 64 as text — without copying the whole scrollback, which a find in a
    /// long session would do on every look into the recording.
    func memoryLinesForFind() -> (count: Int, head: [String]) {
        flushHiddenOutput()
        let t = getTerminal()
        var row = t.buffer.totalLinesTrimmed
        var head: [String] = []
        var count = 0, lastWithText = 0
        var lineHasText = false
        while let line = t.getScrollInvariantLine(row: row) {
            if !line.isWrapped || count == 0 {
                if lineHasText { lastWithText = count }
                count += 1
                lineHasText = false
                if count <= 64 {
                    // The whole line, right-trimmed, as the recording's lines are compared with it.
                    var text = BufferSearch.lineText(in: t, row: row)
                    while let c = text.last, c == " " || c == "\0" { text.removeLast() }
                    head.append(text)
                }
            }
            if !lineHasText {
                for col in 0..<min(line.count, t.cols) {
                    let ch = t.getCharacter(for: line[col])
                    if ch != " " && ch != "\0" { lineHasText = true; break }
                }
            }
            row += 1
        }
        if lineHasText { lastWithText = count }
        return (lastWithText, Array(head.prefix(lastWithText)))
    }

    /// Scrolls to a scroll-invariant row and selects the given column range (e.g. a search match).
    public func reveal(invariantRow: Int, columns: Range<Int>?) {
        flushHiddenOutput()
        let row = invariantRow - getTerminal().buffer.totalLinesTrimmed
        guard row >= 0 else { NSSound.beep(); return }
        placeView(row: max(row - getTerminal().rows / 3, 0))
        if let columns, !columns.isEmpty {
            selection.setSelection(start: Position(col: columns.lowerBound, row: row),
                                   end: Position(col: columns.upperBound, row: row))
        }
        highlight(rows: row...row)
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    func selectAllText() {
        clearCommandSelection()
        if isBrowsingHistory, let history {
            history.selection.selectAll()
            history.needsDisplay = true
            return
        }
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
        // While browsing the recording these move what is on screen; End is the live end.
        case (116, []) where isBrowsingHistory, (116, [.command]) where isBrowsingHistory:
            if let h = history { h.scrollUp(lines: h.getTerminal().rows - 1); requestOlderHistory() }
        case (121, []) where isBrowsingHistory, (121, [.command]) where isBrowsingHistory:
            if let h = history { h.scrollDown(lines: h.getTerminal().rows - 1); requestNewerHistory() }
        case (115, []) where isBrowsingHistory, (115, [.command]) where isBrowsingHistory:
            scrollHistory(toLine: 0)
        case (119, []) where isBrowsingHistory, (119, [.command]) where isBrowsingHistory:
            returnToLive()
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
        findBufferChanged()
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

    /// Programs that animate their title (coding agents' spinners) change it many times a second,
    /// and every tab strip, sidebar and menu listing titles follows: a tab not on screen passes on
    /// its title at most once a second (the latest one).
    private var pendingTitle: String?
    private var lastTitleAt: TimeInterval = 0

    public func setTerminalTitle(source: TerminalView, title: String) {
        guard let session, !replayingEarlier else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if session.isOnScreen || now - lastTitleAt >= 1 {
            pendingTitle = nil
            lastTitleAt = now
            session.remoteTitle = title
            return
        }
        let queued = pendingTitle != nil
        pendingTitle = title
        guard !queued else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, 1 - (now - lastTitleAt))) { [weak self] in
            guard let self, let title = self.pendingTitle else { return }
            self.pendingTitle = nil
            self.lastTitleAt = ProcessInfo.processInfo.systemUptime
            self.session?.remoteTitle = title
        }
    }

    /// OSC 7 (`file://host/path`) from shells that report their working directory.
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard !replayingEarlier, let directory, let path = Self.reportedPath(directory) else { return }
        if !path.isEmpty, session?.reportedDirectory != path { session?.reportedDirectory = path }
    }

    /// The path in an OSC 7 report (`file://host/path`, percent-encoded — though some shells send
    /// spaces as they are). Never the raw `file://` text.
    static func reportedPath(_ report: String) -> String? {
        if let url = URL(string: report), url.scheme == "file", !url.path.isEmpty { return url.path }
        var rest = Substring(report)
        if rest.hasPrefix("file://") {
            rest = rest.dropFirst("file://".count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            rest = rest[slash...]
        }
        let path = String(rest).removingPercentEncoding ?? String(rest)
        return path.hasPrefix("/") ? path : nil
    }

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // The terminal also sends by itself (answers to a program's queries, focus reports when
        // the window or the history view takes the keyboard): only what the user typed or pasted
        // brings the live terminal back and counts as a command.
        guard !replayingEarlier else { return }       // answers to queries in earlier output
        guard isUserInput else { session?.send(data); return }
        returnToLive()          // typing while scrolled back into the recording: the live end again
        clearCommandSelection()
        historyJump = nil
        blockSelection = nil
        // Typed: the next ⌘↑ goes from the line being typed on (to the command just run), until scrolled.
        jumpPlace = jumpPlace(line: nil, atBottom: isScrolledToBottom)
        noteInput(data)
        let returns = data.contains(0x0d) && (session?.phase.isOnline == true || marksWhileOffline)
        if returns { resolveTypedAhead(giveUp: true) }       // the one before, where it was
        var marked = false
        if returns, typedAhead, let text = typedText?.trimmingCharacters(in: .whitespaces), !text.isEmpty, !isAlternateScreen,
           !showsCommand(text, onLine: lineStart(at: promptLine)) {
            // Typed while a program still printed: marked where the shell shows it, below.
            pendingTypedAhead = (text, promptLine, ProcessInfo.processInfo.systemUptime)
            inputStart = nil; typedOnLine = false; typedText = ""; typedAhead = false
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.typedAheadWait + 0.1) { [weak self] in self?.resolveTypedAhead() }
        } else if returns {
            marked = markCommandAtCursor()
        }
        if data.contains(0x0d) { inputStart = nil; typedOnLine = false; typedText = ""; typedAhead = false }
        // Each Return or Ctrl+L: a clear after it is the user's (what is on screen is kept above
        // it). The recording notes each one too (a command's mark counts for its Return), so it
        // keeps the same screens when it is shown again.
        let typed = data.reduce(0) { $0 + ($1 == 0x0d || $1 == 0x0c ? 1 : 0) }
        if typed > 0 {
            ruleContext.typed(typed)
            for _ in 0..<max(typed - (marked ? 1 : 0), 0) { session?.noteClearTyped() }
        }
        session?.send(data)
    }

    public func scrolled(source: TerminalView, position: Double) {
        drawFind()
        scrollerNeedsUpdate()
        let trimmed = hasOlderOutput
        // Older output is read back from disk as the user scrolls to the top (no visible break) —
        // only then: the view placed there by Tether (⌘↑, a find) or output trimming the top of
        // memory while you read is not you going on into the recording (that swapped what was on
        // screen for the recording's view, and the place moved).
        if position <= 0.0001 && trimmed && hasHistoryOnDisk && !placingView,
           ProcessInfo.processInfo.systemUptime - lastWheel < 0.6 {
            requestOlderHistory()
        }
        // At the top with nothing more to bring into memory (no recording): the window says the
        // rest is gone from the terminal.
        let atLimit = position <= 0.0001 && trimmed && !hasHistoryOnDisk
        if atLimit != atHistoryLimit {
            atHistoryLimit = atLimit
            onReachedHistoryLimit?(atLimit)
        }
    }

    // MARK: History beyond memory

    /// Runs a reader in the background on the session's recording, made current first (everything
    /// shown so far is in it), with how many bytes of output it held then. Returns false when
    /// there is no recording.
    public var historyReader: ((@escaping @Sendable (RecordingSnapshot) -> Void) -> Bool)?
    /// Where lines and commands are in the recording (`RecordingIndex`), as the recorder knows it.
    public var historyIndex: (() -> RecordingIndex?)?
    /// Older output can be read back: there is a reader and the session is recorded.
    public var hasHistoryOnDisk: Bool {
        historyReader != nil && (session == nil || session?.recordingURL != nil || historyIndex?() != nil)
    }
    /// Lines read back each time the edge of what is shown is reached while scrolling back.
    public var historyChunkLines = 10_000
    /// The most lines a terminal shows at once while scrolled back into the recording.
    public var historyMaxLines = 250_000
    /// The most memory that may take (about 20,000 lines at 120 columns).
    static let historyBudgetBytes = 64 << 20
    /// Called when a load of earlier output ends (shown or given up), for tests.
    var onHistoryLoaded: ((Bool) -> Void)?

    /// Rows in the buffer (scrollback and screen).
    var bufferLineCount: Int {
        flushHiddenOutput()
        let t = getTerminal()
        var lo = t.buffer.totalLinesTrimmed, hi = lo + 4_000_000
        while lo < hi {   // first invariant row without a line
            let mid = (lo + hi) / 2
            if t.getScrollInvariantLine(row: mid) != nil { lo = mid + 1 } else { hi = mid }
        }
        return lo - t.buffer.totalLinesTrimmed
    }

    /// Lines SwiftTerm let go of when the scrollback was made smaller: it drops them without
    /// counting them in `totalLinesTrimmed`, which would then claim nothing older exists.
    private var droppedByResize = 0

    /// Lines this terminal no longer holds (dropped from the top), all told.
    var linesDropped: Int { getTerminal().buffer.totalLinesTrimmed + droppedByResize }

    /// Whether output older than what is in memory exists (in the recording): lines dropped from
    /// memory, or — in a tab that came back after Tether reopened, showing only the end of its
    /// recording — a recording that holds more than memory does. Find and scrolling back look
    /// there then too.
    public var hasOlderOutput: Bool {
        if linesDropped > 0 { return true }
        guard showedEarlierOutput, hasHistoryOnDisk else { return false }
        guard let index = historyIndex?() else { return earlierOutputCut }
        return earlierOutputCut || index.lines + 1 > linesUpToCursor
    }

    /// Output of an earlier run was shown (the end of a recording that may hold more).
    private var showedEarlierOutput = false
    /// … and it was cut to its end (see `earlierOutputIsPartial`).
    private var earlierOutputCut = false

    /// Sets the scrollback size, noting the lines a smaller size drops (and moving the command
    /// marks with the lines they belong to, since SwiftTerm does not count those lines as trimmed).
    private func resizeScrollback(_ lines: Int) {
        let before = bufferLineCount
        getTerminal().changeScrollback(lines)
        let dropped = before - bufferLineCount
        guard dropped > 0 else { return }
        textVersion &+= 1           // the text kept for search is no longer what is here
        droppedByResize += dropped
        clearTop = clearTop.map { $0 - dropped }
        let trimmed = getTerminal().buffer.totalLinesTrimmed
        markEntries = markEntries.map { MarkEntry(line: $0.line - dropped, time: $0.time, column: $0.column) }.filter { $0.line >= trimmed }
        inputStart = nil
        jumpPlace = nil
        blockSelection = nil
        // Matches' rows moved up with the lines (not counted as trimmed): the current one keeps
        // its text, and everything is looked through again.
        if let findSession {
            let current = findSession.current.map { findSession.matches[$0] }
            findSession.matches = findSession.matches.compactMap { m in
                var m = m
                for i in m.segments.indices { m.segments[i].row -= dropped }
                return m.row >= trimmed ? m : nil
            }
            findSession.current = current.flatMap { c in
                findSession.matches.firstIndex { $0.segments.first?.columns == c.segments.first?.columns && $0.row == c.row - dropped }
            }
            findSession.changedFrom = nil
            findBufferChanged()
        }
    }

    /// The cursor's row in the buffer (scrollback and screen), wherever the view is scrolled.
    var cursorRowInBuffer: Int { bufferLineCount - getTerminal().rows + getTerminal().getCursorLocation().y }

    /// Lines as the program wrote them (wrapped rows joined) from the top of the buffer to the
    /// cursor: as many as the recording's last lines that hold what memory holds.
    var linesUpToCursor: Int {
        // Asked on every scroller update and drag step: counted again only when the text changed.
        let key = textKey
        if let cachedLinesUpToCursor, cachedLinesUpToCursor.key == key { return cachedLinesUpToCursor.value }
        let value = countLinesUpToCursor()
        cachedLinesUpToCursor = (key, value)
        return value
    }
    private var cachedLinesUpToCursor: (key: TextKey, value: Int)?

    private func countLinesUpToCursor() -> Int {
        let t = getTerminal()
        let first = t.buffer.totalLinesTrimmed
        let last = first + cursorRowInBuffer
        var count = 0
        var row = first
        while row <= last, let line = t.getScrollInvariantLine(row: row) {
            if !line.isWrapped || row == first { count += 1 }
            row += 1
        }
        return count
    }

    /// Complete lines above the cursor's: the recording's last line breaks before its end.
    var linesAboveCursor: Int { max(linesUpToCursor - 1, 0) }

    /// Rows a line takes here (long lines wrap), at least 1.
    var rowsPerLine: Double { max(1, Double(cursorRowInBuffer + 1) / Double(max(linesUpToCursor, 1))) }

    /// Rows a terminal holds at most while scrolled back: `historyMaxLines`, within a memory
    /// budget (a row costs about 24 bytes per column).
    var historyWindowLines: Int {
        min(historyMaxLines, max(settings.scrollbackLines, Self.historyBudgetBytes / (getTerminal().cols * 24 + 160)))
    }

    var programsMayClearScrollback: Bool { settings.programsMayClearScrollback }
    var keepsRedrawnFrames: Bool { settings.keepRedrawnFrames }
    /// What the scrollback rule remembers of this terminal's output and typing (see `ScrollbackRule.Context`).
    var ruleContext = ScrollbackRule.Context(keepRedraws: false, knowsTyping: true)
    var copiesOnSelect: Bool { settings.copyOnSelect }

    // MARK: Browsing the recording

    /// Shown over this terminal while scrolled back further than it holds (see
    /// `HistoryTerminalView`); kept for a while after, so going back and forth at the seam is instant.
    private(set) var history: HistoryTerminalView?
    /// The terminal shows earlier output from the recording, over the live terminal (which goes on
    /// underneath: typing, scrolling down to it, or *Back to Live* shows it again).
    public var isBrowsingHistory: Bool { history?.isHidden == false }
    /// Called when browsing starts or ends.
    public var onBrowsingHistory: ((Bool) -> Void)?
    private var historyLoadQueued = false
    /// Uptime before which no new start of browsing happens by itself (one just gave up).
    private var historyRetryAfter: TimeInterval = 0
    private var releaseHistory: DispatchWorkItem?

    /// What is on screen: the history while browsing, else this terminal.
    public var displayedTerminal: TerminalView { isBrowsingHistory ? history! : self }

    private func makeHistory() -> HistoryTerminalView {
        if let history { return history }
        let h = HistoryTerminalView(live: self)
        h.translatesAutoresizingMaskIntoConstraints = false
        h.isHidden = true
        addSubview(h, positioned: .below, relativeTo: historyScroller)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: leadingAnchor),
            h.trailingAnchor.constraint(equalTo: trailingAnchor),
            h.topAnchor.constraint(equalTo: topAnchor),
            h.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // Measured on this window's screen, as this terminal is (made without a window, it
        // measured on the main screen): the same columns.
        h.font = font
        h.onLoaded = { [weak self] ok in self?.onHistoryLoaded?(ok) }
        history = h
        return h
    }

    /// Counts returns to the live terminal: a read of the recording asked for before one does not
    /// take the view back into it when it finishes.
    private var browseGeneration = 0

    private func setBrowsing(_ on: Bool) {
        guard let history, history.isHidden == on else { return }
        history.isHidden = !on
        releaseHistory?.cancel()
        if !on {
            if window?.firstResponder === history { window?.makeFirstResponder(self) }
            // Its memory goes a while after leaving (back and forth at the seam stays instant).
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.history?.isHidden == true else { return }
                self.discardHistory()
            }
            releaseHistory = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
        }
        onBrowsingHistory?(on)
        scrollerNeedsUpdate()
        // The find's boxes for memory sit above the history view: hidden while it is shown, and
        // back over this terminal's text when it goes.
        drawFind()
    }

    /// Lets go of the history view and its lines (not while it is shown).
    func discardHistory(force: Bool = false) {
        guard let history, force || history.isHidden else { return }
        // A read under way: let go of it once it is done (unless the tab is going).
        if history.loading, !force {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                if self?.history?.isHidden == true { self?.discardHistory() }
            }
            return
        }
        history.removeFromSuperview()
        self.history = nil
    }

    /// The user is at the top of memory (or of what is shown while browsing): earlier output.
    /// Asked on reaching the top and again on every further step up there, so a start that could
    /// not happen then (the scroller held with the mouse) happens as soon as it can.
    func requestOlderHistory() {
        if isBrowsingHistory { history?.request(up: true); return }
        let t = getTerminal()
        guard hasHistoryOnDisk, hasOlderOutput, t.buffer.yDisp == 0, !isAlternateScreen,
              !historyLoadQueued, history?.loading != true else { return }
        historyLoadQueued = true
        let wait = NSEvent.pressedMouseButtons != 0 ? 0.25 : max(0, historyRetryAfter - ProcessInfo.processInfo.systemUptime)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.historyLoadQueued = false
            if NSEvent.pressedMouseButtons != 0 || ProcessInfo.processInfo.systemUptime < self.historyRetryAfter {
                self.requestOlderHistory()      // still dragging, or waiting: again shortly
                return
            }
            guard self.getTerminal().buffer.yDisp == 0 else { return }     // scrolled away meanwhile
            self.loadOlderHistory()
        }
    }

    /// While browsing, the bottom of what is shown: later output (or the live terminal).
    func requestNewerHistory() {
        if isBrowsingHistory { history?.request(up: false) }
    }

    /// Starts showing earlier output, from where this terminal's top is: the history view shows
    /// exactly what this terminal showed, with the recording before it. Returns whether it started.
    @discardableResult
    func loadOlderHistory() -> Bool { enterHistoryAtSeam() }

    /// Shows the recording just above what memory holds, the view where this terminal's was;
    /// `then` once it is shown. False when there is nothing to show.
    func enterHistoryAtSeam(then: ((HistoryTerminalView) -> Void)? = nil) -> Bool {
        flushHiddenOutput()
        let t = getTerminal()
        guard !isBrowsingHistory, !isAlternateScreen, hasOlderOutput, historyReader != nil, history?.loading != true else { return false }
        let h = makeHistory()
        let top = t.buffer.yDisp
        // The seam is where it was a moment ago (back and forth there): shown again as it is.
        if h.reaches(liveTop: linesDropped) {
            h.showLiveTop(offset: top)
            setBrowsing(true)
            then?(h)
            return true
        }
        // The top row continues a line whose first rows were dropped: how many of its rows are here.
        var partly: Int?
        if let first = t.getScrollInvariantLine(row: t.buffer.totalLinesTrimmed), first.isWrapped {
            var rows = 1
            while let next = t.getScrollInvariantLine(row: t.buffer.totalLinesTrimmed + rows), next.isWrapped { rows += 1 }
            partly = rows
        }
        let asked = browseGeneration
        h.enter(liveLines: linesAboveCursor, liveTopOffset: top, liveTopRows: partly) { [weak self] ok in
            guard let self, self.browseGeneration == asked else { return }
            if ok { self.setBrowsing(true); then?(h) } else { self.historyRetryAfter = ProcessInfo.processInfo.systemUptime + 2 }
        }
        return true
    }

    /// The history view reached the live terminal (or was left by typing): the live terminal again,
    /// scrolled to `row` (the same line the history showed) or to the bottom.
    func leaveHistory(scrollTo row: Int?) {
        guard isBrowsingHistory else { return }
        historyJump = nil
        clearCommandSelection()      // it was shown there
        findSession?.queuedEarlier = nil
        setBrowsing(false)
        if let row { scrollTo(row: row) } else { scrollToBottom() }
    }

    /// Back to the live end at once (typing, *Back to Live*).
    public func returnToLive() {
        // A part of the recording still being read is not shown when it arrives.
        browseGeneration &+= 1
        pendingScrollLine = nil
        pendingCommandJump = nil
        pendingJump = nil
        leaveHistory(scrollTo: nil)
    }

    /// Tether locks: the earlier output read back from the recording (decrypted, possibly many
    /// megabytes) is let go of now; it is read again when scrolled to after unlocking.
    public func releaseEarlierOutput() {
        returnToLive()
        discardHistory(force: true)
    }

    /// The Mac is short of memory: off screen, only the last lines stay (at once, not after a
    /// minute; the rest is in the recording), and copies kept for finding and a history view not
    /// shown are let go of. What is on screen stays as it is.
    func relieveMemory() {
        cachedScrollback = nil
        cachedLogical = nil
        discardHistory()
        guard window == nil else { return }
        shrinkWhileHidden?.cancel()
        shrinkWhileHidden = nil
        shrinkHidden()
    }

    /// Shows the recording around byte `offset` of its output (a search result in earlier output):
    /// the terminal browses from there, as if scrolled back to it. `done` gets the scroll-invariant
    /// row (in what is shown) of the line at `offset`, where a find can start. False when it
    /// cannot (a full-screen program is up, a load is under way, no recording).
    @discardableResult
    public func showRecording(at offset: Int, through: Int? = nil, done: @escaping (Int) -> Void) -> Bool {
        flushHiddenOutput()
        guard isBrowsingHistory || !isAlternateScreen, historyReader != nil, history?.loading != true else { return false }
        let h = makeHistory()
        let wasBrowsing = isBrowsingHistory
        let asked = browseGeneration
        h.show(offset: offset, through: through) { [weak self] row in
            guard let self, self.browseGeneration == asked else { return }
            if !wasBrowsing { self.setBrowsing(true) }
            done(row)
        }
        return true
    }

    /// A small spinner in the top right corner (next to the scroller) while a part of the recording
    /// is read and the view waits at its edge for it — nothing written over the terminal, and only
    /// when the read takes a while.
    private lazy var loadingPill: NSView = {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isHidden = true
        spinner.setAccessibilityLabel("Loading earlier output")
        spinner.toolTip = "Reading earlier output from the recording"
        return spinner
    }()

    func historyLoadingChanged() {
        guard let h = history else { return }
        let spinner = loadingPill as? NSProgressIndicator
        if !h.loading {
            spinner?.stopAnimation(nil)
            loadingPill.isHidden = true
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak h] in
            guard let self, let h, h.loading, h.waitsAtEdge, self.window != nil else { return }
            if self.loadingPill.superview !== self {
                self.addSubview(self.loadingPill)
                NSLayoutConstraint.activate([
                    self.loadingPill.trailingAnchor.constraint(equalTo: self.historyScroller.leadingAnchor, constant: -6),
                    self.loadingPill.topAnchor.constraint(equalTo: self.topAnchor, constant: 6),
                ])
            }
            self.loadingPill.isHidden = false
            spinner?.startAnimation(nil)
        }
    }

    /// ⌘↑ / ⌘↓ asked while a part of the recording was being read: done once it is in.
    private var pendingCommandJump: (() -> Void)?

    func historyWindowChanged() {
        if let jump = pendingCommandJump {
            pendingCommandJump = nil
            DispatchQueue.main.async { jump() }
        }
        showQueuedEarlierMatch()
        if let line = pendingScrollLine {
            pendingScrollLine = nil
            scrollHistory(toLine: line)
        }
        scrollerNeedsUpdate()
    }

    /// The history view was scrolled.
    func historyScrolled() { scrollerNeedsUpdate() }

    /// A part of the recording could not be shown: what waited for it is let go of (or tried now).
    func historyLoadFailed() {
        findSession?.queuedEarlier = nil
        pendingCommandJump = nil
        pendingJump = nil
        if let line = pendingScrollLine {
            pendingScrollLine = nil
            DispatchQueue.main.async { [weak self] in self?.scrollHistory(toLine: line) }
        }
    }

    /// The text of the first rows in memory (to find the same place in the history view).
    func firstRowsText(_ count: Int) -> [String] {
        let t = getTerminal()
        let base = t.buffer.totalLinesTrimmed
        return (0..<count).compactMap { t.getScrollInvariantLine(row: base + $0)?.translateToString(trimRight: true) }
    }

    // MARK: The whole-session scroller

    let historyScroller = HistoryScroller()
    /// The session line number of this terminal's first line in memory (from the last update).
    private var liveFirstLine = 0
    var liveFirstLineForMarks: Int { liveFirstLine }
    /// Where the scroller was dragged while a part of the recording was being read: shown next.
    private var pendingScrollLine: Int?
    /// Counts scroller moves, so a read that finishes after a later move is not shown.
    private var scrollGeneration = 0
    private var scrollerUpdateQueued = false

    private func installHistoryScroller() {
        HistoryScroller.hideNativeScroller(of: self)
        historyScroller.translatesAutoresizingMaskIntoConstraints = false
        addSubview(historyScroller)
        NSLayoutConstraint.activate([
            historyScroller.trailingAnchor.constraint(equalTo: trailingAnchor),
            historyScroller.topAnchor.constraint(equalTo: topAnchor),
            historyScroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            historyScroller.widthAnchor.constraint(equalToConstant: HistoryScroller.width),
        ])
        historyScroller.onScroll = { [weak self] line in self?.scrollHistory(toLine: line) }
    }

    /// The scroller follows scrolling and output, a few times a second at most.
    func scrollerNeedsUpdate() {
        guard window != nil, !scrollerUpdateQueued else { return }
        scrollerUpdateQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.updateHistoryScroller() }
    }

    /// The index of the recording, when it says exactly where lines are.
    var exactIndex: RecordingIndex? {
        guard hasHistoryOnDisk, let index = historyIndex?(), index.isExact else { return nil }
        return index
    }

    func updateHistoryScroller() {
        scrollerUpdateQueued = false
        let t = getTerminal()
        // A full-screen program's screen, or no index: the scroller stands for what is in memory.
        guard !isAlternateScreen || isBrowsingHistory, let index = exactIndex else {
            historyScroller.set(total: bufferLineCount, top: t.buffer.yDisp, visible: t.rows)
            return
        }
        let total = index.lines + 1
        let rpl = rowsPerLine
        liveFirstLine = max(total - linesUpToCursor, 0)
        if isBrowsingHistory, let h = history, let top = h.topLine {
            historyScroller.set(total: total, top: top, visible: h.visibleLines ?? Int(Double(t.rows) / h.rowsPerLine))
        } else {
            historyScroller.set(total: total, top: liveFirstLine + Int(Double(t.buffer.yDisp) / rpl), visible: Int(Double(t.rows) / rpl))
        }
    }

    /// Where history row `row` (scroll-invariant) is on the scroller, 0…1 (the knob's scale).
    func historyShare(ofRow row: Int, in h: HistoryTerminalView) -> CGFloat? {
        guard let index = exactIndex, let line = h.sessionLine(ofRow: row) else { return nil }
        return CGFloat(line / Double(index.lines + 1))
    }

    /// Shows the session from line `target` at the top: from memory when it is there, otherwise read
    /// from the recording (while one part is read, the latest position asked for comes next).
    func scrollHistory(toLine target: Int) {
        guard let index = exactIndex else { scrollTo(row: target); return }
        scrollGeneration &+= 1
        // A part is being read: the latest position (wherever it is) is shown once it is there.
        if history?.loading == true { pendingScrollLine = target; return }
        pendingScrollLine = nil
        let rows = getTerminal().rows
        if target >= liveFirstLine {
            let row = Int(Double(target - liveFirstLine) * rowsPerLine)
            if isBrowsingHistory { leaveHistory(scrollTo: max(row, 1)) } else { scrollTo(row: row) }
            scrollerNeedsUpdate()
            return
        }
        // Already in the part shown.
        if isBrowsingHistory, let h = history, !h.loading, let first = h.firstLine, target >= first {
            let invariant = h.row(ofSessionLine: Double(target)) ?? (Int(Double(target - first) * h.rowsPerLine) + h.firstRow)
            let row = invariant - h.getTerminal().buffer.totalLinesTrimmed
            if row >= 0, row <= h.bufferRows - rows {
                h.scrollTo(row: row)
                scrollerNeedsUpdate()
                return
            }
        }
        guard !isAlternateScreen || isBrowsingHistory, historyReader != nil else { return }
        let h = makeHistory()
        let checkpoint = index.checkpoint(forLine: target)
        let generation = scrollGeneration
        let asked = browseGeneration
        h.show(offset: checkpoint.offset, indexed: true, skipLines: target - checkpoint.line, atTop: true) { [weak self] _ in
            // Only if nothing was asked since (the scroller moved on, into memory perhaps).
            guard let self, self.scrollGeneration == generation, self.pendingScrollLine == nil,
                  self.browseGeneration == asked else { return }
            self.setBrowsing(true)
        }
    }

    /// Wheel and trackpad: at an edge, SwiftTerm reports no scroll (the row does not change), so
    /// further steps there ask for more (one watcher for every terminal).
    private static var wheelMonitor: Any?
    /// When the wheel or trackpad last scrolled this terminal (system uptime): only that is the
    /// user going on into the recording — a scroll elsewhere (another tab, another window) is not.
    var lastWheel: TimeInterval = 0
    /// Tether is scrolling the view (`placeView`).
    private(set) var placingView = false
    /// Height of what floats over the top of the terminal (the find bar): a match under it is
    /// scrolled into sight.
    public var findBarHeight: CGFloat = 0

    static func watchWheel() {
        guard wheelMonitor == nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.scrollingDeltaY != 0, let window = event.window,
                  let hit = window.contentView?.hitTest(window.contentView!.convert(event.locationInWindow, from: nil)) else { return event }
            var view: NSView? = hit
            while let v = view, !(v is TetherTerminalView) {
                if let history = v as? HistoryTerminalView, history.holdsWheel(event) { return nil }
                view = v.superview
            }
            if let terminal = view as? TetherTerminalView {
                terminal.lastWheel = ProcessInfo.processInfo.systemUptime    // the user scrolling this terminal
                terminal.dropStaleMouseTracking()
                // After SwiftTerm has handled the step (the view may just have reached an edge).
                let up = event.scrollingDeltaY > 0
                DispatchQueue.main.async { if up { terminal.requestOlderHistory() } else { terminal.requestNewerHistory() } }
            }
            return event
        }
    }

    /// Number of lines dropped from memory so far (still available in the recording).
    public var trimmedLineCount: Int { getTerminal().buffer.totalLinesTrimmed }

    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "ftp"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Uptime of the last bell acted on: a stream of BEL characters (`cat` of a binary file) rings
    /// once per moment, not once per character.
    private var lastBell: TimeInterval = 0

    public func bell(source: TerminalView) {
        guard !replayingEarlier else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastBell >= 0.2 else { return }
        lastBell = now
        session?.bellRang()
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
        guard !replayingEarlier, NSApp.isActive, let window, window.isKeyWindow, window.firstResponder === self,
              let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func clipboardRead(source: TerminalView) -> Data? { nil }

    public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) { findBufferChanged() }

    private func flash() {
        let l = CALayer()
        l.frame = bounds
        l.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        layer?.addSublayer(l)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { l.removeFromSuperlayer() }
    }
}

extension TerminalView {
    /// The first row (scroll-invariant) of the line whose row `row` is: rows it wrapped onto are
    /// marked as such.
    func lineStart(at row: Int) -> Int {
        let t = getTerminal()
        var start = row
        while start > t.buffer.totalLinesTrimmed, row - start < 1000, t.getScrollInvariantLine(row: start)?.isWrapped == true { start -= 1 }
        return start
    }

    /// The first row of the line `n` lines above the one row `row` is on (rows it wrapped onto
    /// are not lines).
    func lineStart(at row: Int, linesUp n: Int) -> Int {
        var start = lineStart(at: row)
        for _ in 0..<max(n, 0) where start > getTerminal().buffer.totalLinesTrimmed { start = lineStart(at: start - 1) }
        return start
    }

    /// The rows (scroll-invariant) of the line starting at row `row`: it and those it wrapped onto.
    func wrappedRows(from row: Int) -> ClosedRange<Int> {
        let t = getTerminal()
        var end = row
        while end - row < 1000, t.getScrollInvariantLine(row: end + 1)?.isWrapped == true { end += 1 }
        return row...end
    }

    static let flashLayerName = "tether.flash"

    /// Selects the command on the line starting at scroll-invariant row `line`: from `column` cells
    /// into it (where typing started, after the prompt; the line's start when not known) to its
    /// last character, rows it wrapped onto included. Nothing typed there: nothing is selected.
    @discardableResult
    func selectCommand(line: Int, column: Int?) -> Bool {
        let t = getTerminal()
        let cols = max(t.cols, 1)
        let trimmed = t.buffer.totalLinesTrimmed
        let rows = wrappedRows(from: line)
        let startRow = line + (column ?? 0) / cols, startColumn = (column ?? 0) % cols
        var end: (row: Int, column: Int)?
        for row in rows.reversed() {
            guard let l = t.getScrollInvariantLine(row: row) else { continue }
            if let c = (0..<min(l.count, cols)).last(where: { c in
                let ch = t.getCharacter(for: l[c])
                return ch != " " && ch != "\0" && l[c].width > 0
            }) {
                end = (row, c + 1)
                break
            }
        }
        guard startRow <= rows.upperBound, let end, (end.row, end.column) > (startRow, startColumn) else {
            selection.selectNone()
            return false
        }
        selection.setSelection(start: Position(col: startColumn, row: startRow - trimmed),
                               end: Position(col: end.column, row: end.row - trimmed))
        return true
    }

    /// Briefly tints buffer rows so the user sees where a jump or selection landed.
    func flashRows(_ rows: ClosedRange<Int>, width: CGFloat? = nil) {
        let t = getTerminal()
        // Rows are drawn from the top at the font's cell height; the view is a little taller (what
        // is left below the last row), so its height divided by the rows would drift downwards.
        let caret = caretFrame.size.height
        let rowHeight = caret > 0 ? caret : bounds.height / CGFloat(max(t.rows, 1))
        let top = t.getTopVisibleRow()
        let first = max(rows.lowerBound - top, 0)
        let last = min(rows.upperBound - top, t.rows - 1)
        guard last >= first, rowHeight > 0 else { return }
        let width = width ?? bounds.width
        let layerRect = NSRect(x: 0, y: bounds.maxY - CGFloat(last + 1) * rowHeight,
                               width: width, height: CGFloat(last - first + 1) * rowHeight)
        let l = CALayer()
        l.name = Self.flashLayerName
        l.frame = isFlipped ? NSRect(x: 0, y: CGFloat(first) * rowHeight, width: width,
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
}
