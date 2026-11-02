import Foundation
import TmuxControl

/// Drives one tmux control-mode client: routes pane output, encodes input,
/// and restores the screen when (re)attaching.
@MainActor
final class TmuxDriver {
    private enum Pending {
        case ignore
        case paneInfo
        case capture(info: TmuxPaneInfo, fullHistory: Bool)
        /// Output printed while disconnected: the last `rows` of history + the screen.
        case catchUp(info: TmuxPaneInfo, anchor: HistoryCatchUp.Anchor, rows: Int)
        /// The same look again with wrapped lines joined: what is added comes as the lines they were.
        case catchUpJoined(info: TmuxPaneInfo, anchor: HistoryCatchUp.Anchor, rows: [[UInt8]], resume: HistoryCatchUp.Resume)
        case activity
        case foreground
        /// The window's size now (it may follow another client of the session).
        case windowSize
    }

    private var parser = TmuxControlParser()
    private var pending: [Pending] = []
    private var seenFirstReply = false
    private var paneID: String?
    private var bufferedOutput: [(String, [UInt8])] = []
    private var restoring = false
    private let legacyResize: Bool
    private let historyLines: Int
    /// True when attaching to a session that already has content (re-attach / restore).
    private let isReattach: Bool
    /// True when the local terminal is empty and should receive tmux history as well.
    private let terminalIsEmpty: Bool

    /// Writes raw bytes to the ssh process.
    var write: (String) -> Void = { _ in }
    /// Displays bytes in the terminal.
    var display: ([UInt8]) -> Void = { _ in }
    /// Redraws the screen without recording it (it repeats what is already recorded).
    var refresh: ([UInt8]) -> Void = { _ in }
    /// Called once the pane is known and the screen restored.
    var onReady: () -> Void = {}
    /// What a re-attach did, for the Connection Log ("Added 120 lines printed while away").
    var note: (String) -> Void = { _ in }
    /// Called just before the driver clears the screen to draw the pane again (a re-attach): the
    /// clear is Tether's, not the program's, so what was on screen stays in the scrollback.
    var willRedraw: () -> Void = {}
    /// Called on %exit.
    var onExit: (String?) -> Void = { _ in }
    /// Reports the foreground command and working directory of the pane (for automatic tab titles)
    /// and the round-trip time of the request (network latency to the server).
    var onActivity: (_ command: String, _ path: String, _ rtt: TimeInterval) -> Void = { _, _, _ in }
    /// The terminal's real size; nil while it is not known yet (the view sends it once laid out).
    var size: () -> (cols: Int, rows: Int)? = { (80, 24) }
    /// The local screen's last used rows, to find where to continue after a reconnect.
    var screenTail: () -> HistoryCatchUp.Anchor? = { nil }
    /// Whether the local terminal shows its alternate screen now.
    var localOnAlternateScreen: () -> Bool = { false }
    /// The most history a catch-up may fetch (what the server keeps for Tether's sessions).
    var catchUpLimit = 100_000
    /// First catch-up attempt: this many history rows (enough unless a lot was printed meanwhile).
    static let catchUpProbe = 1_000
    /// Second attempt, before everything the server kept: a whole history can be many megabytes,
    /// which takes minutes over a slow link.
    static let catchUpStep = 10_000

    /// How many history rows the next catch-up asks for after `rows` did not reach the last thing
    /// seen locally; nil when the server has no more.
    static func nextCatchUp(after rows: Int, available: Int) -> Int? {
        guard rows < available else { return nil }
        return rows < catchUpStep ? min(catchUpStep, available) : available
    }

    /// Questions to tmux, in the order they were sent: tmux answers in that order. A question that
    /// timed out keeps its place (without a continuation) so its late answer is not taken for the
    /// next one's.
    private var foregroundQueries: [(id: Int, continuation: CheckedContinuation<String?, Never>?)] = []
    private var nextQueryID = 0

    private(set) var exited = false
    private(set) var ready = false
    /// The size last given to tmux, and one that came in before the driver was ready (a window
    /// still settling while a tab re-attaches): sent once ready, never dropped.
    private var sentSize: (cols: Int, rows: Int)?
    private var pendingSize: (cols: Int, rows: Int)?

    /// Whether the session was created by Tether (only then are its options adjusted).
    private let ownSession: Bool
    /// When the oldest unanswered activity request was sent (for stall detection and latency), in
    /// system uptime: time the Mac slept does not count.
    private(set) var activitySentAt: TimeInterval?

    init(version: String, isReattach: Bool, terminalIsEmpty: Bool, historyLines: Int, ownSession: Bool) {
        self.ownSession = ownSession
        let parts = version.split(separator: ".").compactMap { Int($0.prefix(while: \.isNumber)) }
        let major = parts.first ?? 3, minor = parts.count > 1 ? parts[1] : 0
        legacyResize = major == 3 && minor < 2
        self.isReattach = isReattach
        self.terminalIsEmpty = terminalIsEmpty
        self.historyLines = historyLines
    }

    func receive(_ bytes: some Sequence<UInt8>) {
        // tmux sends output a line at a time: the active pane's consecutive lines go to the terminal
        // as one piece (one pass through the filters, the recording and the emulator instead of
        // hundreds). Any other event first gets what came before it, so the order never changes.
        var run: [UInt8] = []
        for event in parser.feed(bytes) {
            if case .output(let pane, let data) = event, let paneID, pane == paneID, !restoring {
                run.append(contentsOf: data)
                continue
            }
            if !run.isEmpty { display(run); run.removeAll(keepingCapacity: true) }
            handle(event)
        }
        if !run.isEmpty { display(run) }
    }

    private func send(_ command: String, expect: Pending = .ignore) {
        guard !command.isEmpty else { return }
        let lines = command.split(separator: "\n", omittingEmptySubsequences: true).count
        pending.append(expect)
        if lines > 1 { pending.append(contentsOf: Array(repeating: .ignore, count: lines - 1)) }
        #if DEBUG
        // Debug builds only: the commands include typed input (send-keys), which can be a password.
        if ProcessInfo.processInfo.environment["TETHER_TMUX_DEBUG"] != nil { print("TMUX>", command, terminator: "") }
        #endif
        write(command)
    }

    private func handle(_ event: TmuxEvent) {
        switch event {
        case .passthrough(let bytes):
            display(bytes)
        case .enteredControlMode:
            send(TmuxCommands.paneInfo, expect: .paneInfo)
            if ownSession { send(TmuxCommands.hidePaneBorderStatus) }
        case .output(let pane, let data):
            if let paneID {
                if pane == paneID && !restoring { display(data) }
                else if pane == paneID { bufferedOutput.append((pane, data)) }
            } else {
                bufferedOutput.append((pane, data))
            }
        case .commandReply(_, let success, let lines):
            handleReply(success: success, lines: lines)
        case .exit(let reason):
            exited = true
            answerForegroundQueries(nil)
            onExit(reason)
        case .notification(let name, _):
            if ready, name == "session-window-changed" || name == "window-pane-changed" {
                // The user switched panes inside tmux; follow the active one.
                send(TmuxCommands.paneInfo, expect: .paneInfo)
            }
            if ready, name == "layout-change" { checkWindowSizeSoon() }
        case .leftControlMode:
            break
        }
    }

    private func handleReply(success: Bool, lines: [[UInt8]]) {
        // tmux answers the command that started the client before ours. If the first reply is
        // empty while we are waiting for pane info, it is that initial block.
        if !seenFirstReply {
            seenFirstReply = true
            if case .paneInfo = pending.first, lines.isEmpty { return }
        }
        guard !pending.isEmpty else { return }
        let kind = pending.removeFirst()
        switch kind {
        case .ignore:
            break
        case .paneInfo:
            guard success, let line = lines.first, let info = TmuxPaneInfo(line: String(decoding: line, as: UTF8.self)) else {
                // Could not identify the pane; fall back to showing everything.
                paneID = bufferedOutput.first?.0
                flushBuffered()
                markReady()
                return
            }
            let firstTime = paneID == nil
            let switched = !firstTime && paneID != info.paneID
            paneID = info.paneID
            // Only a real size: a guessed one would resize the window, and its programs would
            // redraw twice (Claude Code and other TUIs then leave parts of the old frame behind).
            // Without one (a tab restored in the background), the screen restored now is drawn
            // again once the real size is known (`resize`).
            if let s = size() {
                if sentSize.map({ $0 != s }) ?? true { sendSize(s) }
            } else if firstTime {
                screenNeedsRedraw = true
            }
            if firstTime && isReattach && !terminalIsEmpty && !info.alternateScreen, let anchor = screenTail() {
                // Reconnected: add what the pane printed meanwhile, then continue live.
                restoring = true
                let rows = min(info.historySize, Self.catchUpProbe)
                send(TmuxCommands.capturePane(pane: info.paneID, historyLines: max(rows, 1), join: false),
                     expect: .catchUp(info: info, anchor: anchor, rows: rows))
            } else if (firstTime && isReattach) || switched || redrawRequested {
                redrawing = redrawRequested
                redrawRequested = false
                restoring = true
                let full = firstTime && terminalIsEmpty && !info.alternateScreen
                send(TmuxCommands.capturePane(pane: info.paneID, historyLines: full ? historyLines : 0, join: full),
                     expect: .capture(info: info, fullHistory: full))
            } else {
                flushBuffered()
                markReady()
            }
        case .windowSize:
            guard success, let line = lines.first else { return }
            let p = String(decoding: line, as: UTF8.self).split(separator: " ").compactMap { Int($0) }
            guard p.count == 2 else { return }
            windowSizeChanged(cols: p[0], rows: p[1])
        case .foreground:
            let text = success ? lines.first.map { String(decoding: $0, as: UTF8.self) } : nil
            if !foregroundQueries.isEmpty { foregroundQueries.removeFirst().continuation?.resume(returning: text) }
        case .activity:
            let rtt = activitySentAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
            activitySentAt = nil
            guard success, let line = lines.first else { return }
            let text = String(decoding: line, as: UTF8.self)
            let parts = text.split(separator: "\t", maxSplits: 1).map(String.init)
            onActivity(parts.first ?? "", parts.count > 1 ? parts[1] : "", rtt)
        case .capture(let info, let fullHistory):
            if redrawing {
                redrawing = false
                if success { redrawScreen(info: info, lines: lines) }
            } else {
                restoreScreen(info: info, lines: success ? lines : [], fullHistory: fullHistory)
            }
            restoring = false
            bufferedOutput.removeAll() // the capture already contains this output
            markReady()
        case .catchUp(let info, let anchor, let rows):
            let plain = lines.map(HistoryCatchUp.plainText)
            if success, let resume = HistoryCatchUp.resume(captured: plain, anchor: anchor.lines) {
                // Something to add: asked once more with wrapped lines joined (one more round trip).
                if resume.index < lines.count {
                    // Output that came before this answer is in it; what comes from now on is kept
                    // (see `.catchUpJoined`).
                    bufferedOutput.removeAll()
                    send(TmuxCommands.capturePane(pane: info.paneID, historyLines: max(rows, 1), join: true),
                         expect: .catchUpJoined(info: info, anchor: anchor, rows: lines, resume: resume))
                    return
                }
                addCaughtUp(info: info, anchor: anchor, rows: lines, joined: nil, resume: resume)
            } else if success, let more = Self.nextCatchUp(after: rows, available: min(info.historySize, catchUpLimit)) {
                // More was printed than this look covered: look further back, in steps.
                send(TmuxCommands.capturePane(pane: info.paneID, historyLines: more, join: false),
                     expect: .catchUp(info: info, anchor: anchor, rows: more))
                return
            } else if success, !lines.isEmpty {
                // The last thing seen locally is gone from the server's history (cleared, or older than
                // it keeps): its last lines are added, marked — not all of it again, which may repeat
                // a hundred thousand lines already shown (the recording keeps everything).
                let kept = Array(lines.suffix(Self.catchUpFallbackLines + info.height))
                let out = HistoryCatchUp.output(captured: kept, from: 0, anchorRow: anchor.lastRow, cursorRow: anchor.cursorRow,
                                                height: info.height, cursor: (info.cursorX, info.cursorY),
                                                notice: "[Tether] Output from the server while disconnected (its last \(kept.count) lines; earlier lines may repeat):")
                display(out.stream)
                refresh(out.redraw + modes(info))
                note("Re-attached: the last line seen was no longer in tmux's history; added its last \(kept.count) of \(lines.count) lines")
            } else {
                if !success { note("Re-attached, but tmux did not send what was printed while away") }
                restoreScreen(info: info, lines: [], fullHistory: false)
            }
            restoring = false
            bufferedOutput.removeAll() // the capture already contains this output
            markReady()
        case .catchUpJoined(let info, let anchor, let rows, let resume):
            let joinedUsed = addCaughtUp(info: info, anchor: anchor, rows: rows, joined: success ? lines : nil, resume: resume)
            restoring = false
            // The joined capture already contains what came meanwhile. Without it (it did not line
            // up: more was printed between the two answers), that output follows as it came.
            if joinedUsed { bufferedOutput.removeAll() } else { flushBuffered() }
            markReady()
        }
    }

    /// Adds what was printed while away (from `resume` on): as the lines tmux joined when they
    /// line up with its rows, row by row otherwise; then the screen as tmux has it.
    /// Returns whether the joined lines were used.
    @discardableResult
    private func addCaughtUp(info: TmuxPaneInfo, anchor: HistoryCatchUp.Anchor, rows lines: [[UInt8]],
                             joined: [[UInt8]]?, resume: HistoryCatchUp.Resume) -> Bool {
        let plain = lines.map(HistoryCatchUp.plainText)
        let tail = joined.flatMap { HistoryCatchUp.joinedLines(rows: plain, joined: $0, from: resume.index) }
        let out = HistoryCatchUp.output(captured: tail ?? lines, from: tail == nil ? resume.index : 0, anchorRow: anchor.lastRow, cursorRow: anchor.cursorRow,
                                        height: info.height, cursor: (info.cursorX, info.cursorY),
                                        replacingAnchorRow: resume.replacesLastRow, screen: lines)
        display(out.stream)
        // The program's terminal modes too: after a relaunch the terminal starts without them
        // (a shell's bracketed paste, an agent's mouse), and a paste would run line by line.
        refresh(out.redraw + modes(info))
        // The screen's empty rows below the output are not lines that were printed.
        let used = (plain.lastIndex { !$0.allSatisfy(\.isWhitespace) } ?? -1) + 1
        let added = max(used - resume.index, 0)
        note(added == 0 ? "Re-attached: nothing was printed while away"
             : "Re-attached: added \(added) line\(added == 1 ? "" : "s") printed while away")
        return tail != nil
    }

    /// At most this many lines are added when the last line seen is not found in the server's history.
    static let catchUpFallbackLines = 1_000

    /// The pane's terminal modes as they are on the server (mouse, bracketed paste, keys, cursor):
    /// those left on locally first switched off, then the pane's own set again.
    private func modes(_ info: TmuxPaneInfo) -> [UInt8] {
        Array((Self.modesOff + info.modes.sequence(cursorX: info.cursorX, cursorY: info.cursorY, height: info.height)).utf8)
    }

    /// Mouse reporting, bracketed paste, focus reports and application keys off.
    static let modesOff = "\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[?1015l\u{1b}[?2004l\u{1b}[?1004l\u{1b}[?1l\u{1b}>"

    private func flushBuffered() {
        let items = bufferedOutput
        bufferedOutput.removeAll()
        for (pane, data) in items where pane == paneID { display(data) }
    }

    private func markReady() {
        guard !ready else { return }
        ready = true
        // The terminal may have changed size while the screen was being restored.
        if let s = size() ?? pendingSize, sentSize.map({ $0 != s }) ?? true { sendSize(s) }
        pendingSize = nil
        onReady()
    }

    private func sendSize(_ s: (cols: Int, rows: Int)) {
        sentSize = s
        send(TmuxCommands.resize(cols: s.cols, rows: s.rows, legacySyntax: legacyResize))
    }

    // MARK: Another client of the session

    /// The window's size when it is not the one this terminal gave tmux: another client of the
    /// session (another computer, another terminal) was used last, and tmux (`window-size latest`,
    /// its default) sized the window for that one. The pane is then drawn at its size; rows of the
    /// local terminal outside it are cleared rather than left showing an old frame.
    private(set) var otherClientSize: (cols: Int, rows: Int)?
    /// The window was already asked back for this terminal since the last change of size.
    private var sizeClaimed = false
    private var sizeCheck = 0

    /// Asks the window's size once the layout has settled (a window being resized here sends
    /// several changes in a row, each answered with the size given just before).
    private func checkWindowSizeSoon() {
        sizeCheck += 1
        let check = sizeCheck
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, check == self.sizeCheck, self.ready, !self.exited, let paneID = self.paneID else { return }
            self.send("display-message -p -t \(paneID) '#{window_width} #{window_height}'\n", expect: .windowSize)
        }
    }

    private func windowSizeChanged(cols: Int, rows: Int) {
        guard let own = sentSize else { return }
        let other = (cols, rows) == (own.cols, own.rows) ? nil : (cols: cols, rows: rows)
        let before = otherClientSize
        guard other.map({ o in before.map { $0 != o } ?? true }) ?? (before != nil) else { return }
        otherClientSize = other
        sizeClaimed = false
        if let other {
            note("The session's window follows another client of it (\(other.cols)×\(other.rows), this terminal \(own.cols)×\(own.rows)); "
                 + "typing here or showing the tab sizes it for this terminal again")
        } else if before != nil {
            note("The session's window has this terminal's size again")
        }
        // The screen as tmux has it now, rows outside the pane cleared: no half-overwritten old frame.
        redrawRequested = true
        send(TmuxCommands.paneInfo, expect: .paneInfo)
    }

    /// The user is at this terminal (typed, or showed the tab): the window is sized for it again,
    /// as tmux does for the client typed into last. Never on its own (output, reports): two
    /// computers showing the session would otherwise take it from each other without end.
    func claimSize() {
        guard ready, !exited, otherClientSize != nil, !sizeClaimed, let paneID else { return }
        sizeClaimed = true
        // `select-window` makes this the session's latest client (sending keys does not); the
        // current window stays current, nothing else changes.
        send("select-window -t \(paneID)\n")
        if let s = size() ?? sentSize { sendSize(s) }
    }

    /// Draws the pane's screen again, row by row, over what the terminal shows: no clear (which
    /// would keep the wrong frame in the scrollback) and nothing recorded (the recording has it).
    private func redrawScreen(info: TmuxPaneInfo, lines: [[UInt8]]) {
        var out: [UInt8] = []
        // The local screen follows the pane's: a program that ended meanwhile leaves the alternate one.
        out += Array(screenSwitch(info).utf8)
        let visible = Array(lines.suffix(info.height))
        // Rows wider than the terminal (a pane sized for a wider client) are cut, not wrapped: a
        // wrap on the last row would scroll a line of this frame into the scrollback.
        out += Array("\u{1b}[?7l".utf8)
        // A terminal shorter than the pane: its rows only (more would all land on its last row).
        for row in 0..<min(info.height, size()?.rows ?? info.height) {
            out += Array("\u{1b}[\(row + 1);1H\u{1b}[0m\u{1b}[2K".utf8)
            if row < visible.count { out += visible[row] }
        }
        // A terminal taller than the pane (the window follows another client): the rows below it
        // are not the pane's, whatever an earlier frame left there.
        if let rows = size()?.rows ?? sentSize?.rows, rows > info.height {
            out += Array("\u{1b}[\(info.height + 1);1H\u{1b}[0m\u{1b}[J".utf8)
        }
        out += Array("\u{1b}[0m\u{1b}[?7h".utf8)
        out += Array(info.modes.sequence(cursorX: info.cursorX, cursorY: info.cursorY, height: info.height).utf8)
        refresh(out)
    }

    /// Into the alternate screen when the pane is on it; out of it only when the local terminal is
    /// on it and the pane is not (a program that ended while away).
    private func screenSwitch(_ info: TmuxPaneInfo) -> String {
        info.alternateScreen ? "\u{1b}[?1049h" : (localOnAlternateScreen() ? "\u{1b}[?1049l" : "")
    }

    private func restoreScreen(info: TmuxPaneInfo, lines: [[UInt8]], fullHistory: Bool) {
        var out: [UInt8] = []
        let esc: UInt8 = 0x1b
        // The local screen follows the pane's: a program that ended while away (vim, htop) leaves
        // the alternate screen — the shell's output belongs in the scrollback again.
        out += Array(screenSwitch(info).utf8)
        if fullHistory {
            // History goes into scrollback; the last `height` lines form the visible screen.
            for (i, line) in lines.enumerated() {
                out += line
                if i < lines.count - 1 { out += [0x0d, 0x0a] }
            }
        } else {
            willRedraw()
            out += [esc] + Array("[H".utf8) + [esc] + Array("[2J".utf8)
            let visible = lines.suffix(info.height)
            for (i, line) in visible.enumerated() {
                out += Array("\u{1b}[\(i + 1);1H".utf8)
                out += line
            }
        }
        // The program's terminal modes (mouse, bracketed paste, hidden cursor, …) and the cursor.
        out += Array("\u{1b}[0m".utf8)
        out += modes(info)
        display(out)
    }

    // MARK: Input

    /// `byUser`: typed (not a report the terminal sends by itself): the window is sized for this
    /// terminal again first when another client had it (`claimSize`).
    func sendInput(_ bytes: some Collection<UInt8>, byUser: Bool = false) {
        guard let paneID, !exited else { return }
        if byUser { claimSize() }
        send(TmuxCommands.sendKeys(pane: paneID, bytes: bytes))
    }

    /// The program in the pane's foreground right now (asked fresh, not the periodic value): before a
    /// password is typed, it tells whether something really waits for one or a shell would receive it.
    func foregroundCommand() async -> String? {
        await query("#{pane_current_command}")
    }

    /// A tmux format asked fresh for the pane (e.g. `#{pane_tty}`). Only fixed formats are passed.
    /// nil when tmux does not answer within `timeout`.
    func query(_ format: String, timeout: Duration = .seconds(2)) async -> String? {
        guard ready, !exited, let paneID else { return nil }
        let id = nextQueryID
        nextQueryID += 1
        return await withCheckedContinuation { cont in
            foregroundQueries.append((id, cont))
            send("display-message -p -t \(paneID) '\(format)'\n", expect: .foreground)
            // Held until it has answered: a driver gone meanwhile must not leave its asker waiting.
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                self.expireQuery(id)
            }
        }
    }

    /// Answers a question that took too long with nil; its place in the queue stays.
    private func expireQuery(_ id: Int) {
        guard let i = foregroundQueries.firstIndex(where: { $0.id == id }),
              let continuation = foregroundQueries[i].continuation else { return }
        foregroundQueries[i].continuation = nil
        continuation.resume(returning: nil)
    }

    /// Ends waiting questions (the connection is gone: no answers will come).
    func answerForegroundQueries(_ value: String?) {
        let waiting = foregroundQueries
        foregroundQueries = []
        waiting.forEach { $0.continuation?.resume(returning: value) }
    }

    /// Asks tmux what is running in the pane. Cheap: answered from tmux's own state.
    func requestActivity() {
        guard ready, !exited, let paneID, activitySentAt == nil else { return }
        activitySentAt = ProcessInfo.processInfo.systemUptime
        send("display-message -p -t \(paneID) '#{pane_current_command}\t#{pane_current_path}'\n", expect: .activity)
    }

    func resize(cols: Int, rows: Int) {
        guard !exited else { return }
        guard ready else {
            pendingSize = (cols, rows)
            return
        }
        if sentSize.map({ $0 != (cols, rows) }) ?? true { sendSize((cols, rows)) }
        // The screen was restored before the terminal had its real size: it is taken from tmux
        // again now, at this size. tmux sends no SIGWINCH when its window already had this size,
        // so a program such as Claude Code would not redraw it by itself.
        if screenNeedsRedraw {
            screenNeedsRedraw = false
            redrawRequested = true
            send(TmuxCommands.paneInfo, expect: .paneInfo)
        }
    }

    /// The screen was restored without a real size (`resize` draws it again).
    private var screenNeedsRedraw = false
    /// The capture asked for is that redraw.
    private var redrawing = false
    /// The next pane info is for drawing the screen again (`screenNeedsRedraw`).
    private var redrawRequested = false

    /// Ends the tmux session from inside, over the existing connection.
    func killSession(_ name: String) {
        guard !exited else { return }
        send(TmuxCommands.killSession("=" + name))
    }

    func detach() {
        guard !exited else { return }
        send(TmuxCommands.detach)
    }
}
