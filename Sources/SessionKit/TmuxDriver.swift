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
        case activity
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
    /// Called once the pane is known and the screen restored.
    var onReady: () -> Void = {}
    /// Called on %exit.
    var onExit: (String?) -> Void = { _ in }
    /// Reports the foreground command and working directory of the pane (for automatic tab titles)
    /// and the round-trip time of the request (network latency to the server).
    var onActivity: (_ command: String, _ path: String, _ rtt: TimeInterval) -> Void = { _, _, _ in }
    /// Size provider.
    var size: () -> (cols: Int, rows: Int) = { (80, 24) }

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
        if ProcessInfo.processInfo.environment["TETHER_TMUX_DEBUG"] != nil { print("TMUX>", command, terminator: "") }
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
            if (firstTime && isReattach) || switched {
                restoring = true
                let full = firstTime && terminalIsEmpty && !info.alternateScreen
                send(TmuxCommands.capturePane(pane: info.paneID, historyLines: full ? historyLines : 0, join: full),
                     expect: .capture(info: info, fullHistory: full))
            } else {
                flushBuffered()
                markReady()
            }
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
