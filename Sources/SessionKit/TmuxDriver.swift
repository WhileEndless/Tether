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
        case activity
        case foreground
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
    /// Called on %exit.
    var onExit: (String?) -> Void = { _ in }
    /// Reports the foreground command and working directory of the pane (for automatic tab titles)
    /// and the round-trip time of the request (network latency to the server).
    var onActivity: (_ command: String, _ path: String, _ rtt: TimeInterval) -> Void = { _, _, _ in }
    /// The terminal's real size; nil while it is not known yet (the view sends it once laid out).
    var size: () -> (cols: Int, rows: Int)? = { (80, 24) }
    /// The local screen's last used rows, to find where to continue after a reconnect.
    var screenTail: () -> HistoryCatchUp.Anchor? = { nil }
    /// The most history a catch-up may fetch (what the server keeps for Tether's sessions).
    var catchUpLimit = 100_000
    /// First catch-up attempt: this many history rows (enough unless a lot was printed meanwhile).
    static let catchUpProbe = 1_000

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
    /// When the oldest unanswered activity request was sent (for stall detection and latency).
    private(set) var activitySentAt: Date?

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
        for event in parser.feed(bytes) { handle(event) }
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
        case .foreground:
            let text = success ? lines.first.map { String(decoding: $0, as: UTF8.self) } : nil
            if !foregroundQueries.isEmpty { foregroundQueries.removeFirst().continuation?.resume(returning: text) }
        case .activity:
            let rtt = activitySentAt.map { Date().timeIntervalSince($0) } ?? 0
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
            if success, let start = HistoryCatchUp.resumeIndex(captured: plain, anchor: anchor.lines) {
                let out = HistoryCatchUp.output(captured: lines, from: start, anchorRow: anchor.lastRow,
                                                height: info.height, cursor: (info.cursorX, info.cursorY))
                display(out.stream)
                refresh(out.redraw)
            } else if success, rows < min(info.historySize, catchUpLimit) {
                // More was printed than the first look covered: fetch everything the server kept.
                let all = min(info.historySize, catchUpLimit)
                send(TmuxCommands.capturePane(pane: info.paneID, historyLines: all, join: false),
                     expect: .catchUp(info: info, anchor: anchor, rows: all))
                return
            } else if success, !lines.isEmpty {
                // The last thing seen locally is gone from the server's history (cleared, or older than
                // it keeps): add all it has, marked, rather than lose it.
                let out = HistoryCatchUp.output(captured: lines, from: 0, anchorRow: anchor.lastRow,
                                                height: info.height, cursor: (info.cursorX, info.cursorY),
                                                notice: "[Tether] Output from the server while disconnected (earlier lines may repeat):")
                display(out.stream)
                refresh(out.redraw)
            } else {
                restoreScreen(info: info, lines: [], fullHistory: false)
            }
            restoring = false
            bufferedOutput.removeAll() // the capture already contains this output
            markReady()
        }
    }

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

    /// Draws the pane's screen again, row by row, over what the terminal shows: no clear (which
    /// would keep the wrong frame in the scrollback) and nothing recorded (the recording has it).
    private func redrawScreen(info: TmuxPaneInfo, lines: [[UInt8]]) {
        var out: [UInt8] = []
        if info.alternateScreen { out += Array("\u{1b}[?1049h".utf8) }
        let visible = Array(lines.suffix(info.height))
        for row in 0..<info.height {
            out += Array("\u{1b}[\(row + 1);1H\u{1b}[0m\u{1b}[2K".utf8)
            if row < visible.count { out += visible[row] }
        }
        out += Array("\u{1b}[0m".utf8)
        out += Array(info.modes.sequence(cursorX: info.cursorX, cursorY: info.cursorY, height: info.height).utf8)
        refresh(out)
    }

    private func restoreScreen(info: TmuxPaneInfo, lines: [[UInt8]], fullHistory: Bool) {
        var out: [UInt8] = []
        let esc: UInt8 = 0x1b
        if info.alternateScreen {
            out += Array("\u{1b}[?1049h".utf8)
        }
        if fullHistory {
            // History goes into scrollback; the last `height` lines form the visible screen.
            for (i, line) in lines.enumerated() {
                out += line
                if i < lines.count - 1 { out += [0x0d, 0x0a] }
            }
        } else {
            out += [esc] + Array("[H".utf8) + [esc] + Array("[2J".utf8)
            let visible = lines.suffix(info.height)
            for (i, line) in visible.enumerated() {
                out += Array("\u{1b}[\(i + 1);1H".utf8)
                out += line
            }
        }
        // The program's terminal modes (mouse, bracketed paste, hidden cursor, …) and the cursor.
        out += Array("\u{1b}[0m".utf8)
        out += Array(info.modes.sequence(cursorX: info.cursorX, cursorY: info.cursorY, height: info.height).utf8)
        display(out)
    }

    // MARK: Input

    func sendInput(_ bytes: some Collection<UInt8>) {
        guard let paneID, !exited else { return }
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
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.expireQuery(id)
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
        activitySentAt = Date()
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
