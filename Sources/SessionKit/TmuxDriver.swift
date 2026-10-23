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
    /// Size provider.
    var size: () -> (cols: Int, rows: Int) = { (80, 24) }
    /// The local screen's last used rows, to find where to continue after a reconnect.
    var screenTail: () -> HistoryCatchUp.Anchor? = { nil }
    /// The most history a catch-up may fetch (what the server keeps for Tether's sessions).
    var catchUpLimit = 100_000
    /// First catch-up attempt: this many history rows (enough unless a lot was printed meanwhile).
    static let catchUpProbe = 1_000

    private var foregroundQueries: [CheckedContinuation<String?, Never>] = []

    private(set) var exited = false
    private(set) var ready = false

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
            let (cols, rows) = size()
            send(TmuxCommands.resize(cols: cols, rows: rows, legacySyntax: legacyResize))
            if firstTime && isReattach && !terminalIsEmpty && !info.alternateScreen, let anchor = screenTail() {
                // Reconnected: add what the pane printed meanwhile, then continue live.
                restoring = true
                let rows = min(info.historySize, Self.catchUpProbe)
                send(TmuxCommands.capturePane(pane: info.paneID, historyLines: max(rows, 1), join: false),
                     expect: .catchUp(info: info, anchor: anchor, rows: rows))
            } else if (firstTime && isReattach) || switched {
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
            if !foregroundQueries.isEmpty { foregroundQueries.removeFirst().resume(returning: text) }
        case .activity:
            let rtt = activitySentAt.map { Date().timeIntervalSince($0) } ?? 0
            activitySentAt = nil
            guard success, let line = lines.first else { return }
            let text = String(decoding: line, as: UTF8.self)
            let parts = text.split(separator: "\t", maxSplits: 1).map(String.init)
            onActivity(parts.first ?? "", parts.count > 1 ? parts[1] : "", rtt)
        case .capture(let info, let fullHistory):
            restoreScreen(info: info, lines: success ? lines : [], fullHistory: fullHistory)
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
        onReady()
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
        out += Array("\u{1b}[0m\u{1b}[\(info.cursorY + 1);\(info.cursorX + 1)H".utf8)
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
    func query(_ format: String) async -> String? {
        guard ready, !exited, let paneID else { return nil }
        return await withCheckedContinuation { cont in
            foregroundQueries.append(cont)
            send("display-message -p -t \(paneID) '\(format)'\n", expect: .foreground)
        }
    }

    /// Ends waiting questions (the connection is gone).
    func answerForegroundQueries(_ value: String?) {
        let waiting = foregroundQueries
        foregroundQueries = []
        waiting.forEach { $0.resume(returning: value) }
    }

    /// Asks tmux what is running in the pane. Cheap: answered from tmux's own state.
    func requestActivity() {
        guard ready, !exited, let paneID, activitySentAt == nil else { return }
        activitySentAt = Date()
        send("display-message -p -t \(paneID) '#{pane_current_command}\t#{pane_current_path}'\n", expect: .activity)
    }

    func resize(cols: Int, rows: Int) {
        guard ready, !exited else { return }
        send(TmuxCommands.resize(cols: cols, rows: rows, legacySyntax: legacyResize))
    }

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
