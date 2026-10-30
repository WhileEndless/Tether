import AppKit
import Observation
import SwiftTerm
import TetherCore
import SSHTransport
import RecordingKit
import TerminalText

/// Session-level settings captured when a session (re)starts.
public struct SessionConfiguration: Sendable {
    public var ssh: SSHOptions
    public var autoReconnect: Bool
    public var maxReconnectAttempts: Int
    public var reconnectBaseDelay: Double
    public var reconnectMaxDelay: Double
    public var historyLinesOnReattach: Int
    public var serverHistoryLines: Int
    public var recordingEnabled: Bool
    public var stallTimeout: Double
    public var detectPasswordPrompts: Bool

    public init(settings: AppSettings) {
        ssh = SSHOptions(settings: settings)
        autoReconnect = settings.autoReconnect
        maxReconnectAttempts = settings.maxReconnectAttempts
        reconnectBaseDelay = max(settings.reconnectBaseDelay, 0.5)
        reconnectMaxDelay = max(settings.reconnectMaxDelay, settings.reconnectBaseDelay)
        historyLinesOnReattach = settings.historyLinesOnReattach
        serverHistoryLines = settings.serverHistoryLines
        recordingEnabled = settings.recordingEnabled
        stallTimeout = max(settings.stallTimeout, 3)
        detectPasswordPrompts = settings.detectPasswordPrompts
    }
}

/// One terminal tab: an ssh process, its persistence backend and its lifecycle.
///
/// Lifecycle:
/// `connecting` → `online` ⇄ `waiting` (connection lost, retrying, history visible, input blocked)
/// → `dead` (remote session confirmed gone or exited; read-only forever, archived).
@MainActor
@Observable
public final class TerminalSession: Identifiable {
    public let id: UUID
    public var descriptor: SessionDescriptor
    public private(set) var phase: SessionPhase = .connecting {
        didSet { if phase != oldValue { onStateChange?(self) } }
    }
    public private(set) var persistence: ActivePersistence = .unknown {
        didSet { if persistence != oldValue { applyRecordingInterval() } }
    }

    /// Output a tmux or screen session keeps on the server too may wait longer in memory before
    /// it is written (see `SessionRecorder.keptOnServerInterval`).
    private func applyRecordingInterval() {
        // Only tmux gives its history back on re-attach (`HistoryCatchUp`); screen redraws its screen only.
        recorder?.setBatchInterval(persistence == .tmux ? SessionRecorder.keptOnServerInterval : SessionRecorder.batchInterval)
    }

    /// The recording was continued from an earlier run (`continueRecording`).
    @ObservationIgnored private var continuedRecording = false

    /// Recordings holding more output than this are not continued after a relaunch (a new one
    /// starts): continuing reads the whole recording once, to index it.
    static let continuedRecordingLimit = 128 * 1024 * 1024

    /// A tab restored after a relaunch goes on with the recording it wrote before, instead of
    /// starting a new one: its history (scrolling back, ⌘↑, find) reaches back past the relaunch,
    /// and nothing is recorded twice. The terminal is first shown the end of that recording (as it
    /// was when Tether quit, not recorded again); on re-attach only what tmux printed meanwhile is
    /// added (`HistoryCatchUp`). Call before `restore`/`restoreSuspended`; `done` runs on the main
    /// thread once it is ready (also when the recording cannot be continued).
    public func continueRecording(_ url: URL, done: @escaping @MainActor () -> Void) {
        let config = configurationProvider()
        guard recorder == nil, config.recordingEnabled, !descriptor.isPrivate else { done(); return }
        let key = RecordingCrypto.key
        let limit = Self.continuedRecordingLimit
        Task { [weak self] in
            // On the maintenance queue: no pass (compression, masking, the storage limit) can move or
            // remove the file between deciding to continue it and marking it in use.
            let opened = await RecordingStore.perform { () -> (SessionRecorder, [UInt8]?)? in
                let fm = FileManager.default
                // Output it holds (parts as their names say, the file as it is): indexing reads it all.
                let main = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                let output = RecordingParts.parts(of: url).reduce(main) { $0 + $1.length }
                // With encryption on, a recording in plain text is not added to (a new, encrypted one
                // starts); an encrypted one needs its key, so not while Tether is locked.
                guard fm.fileExists(atPath: url.path), output <= limit, !RecordingStore.isActive(url),
                      !RecordingCrypto.encryptNew || RecordingCrypto.isEncrypted(url),
                      let recorder = SessionRecorder(existing: url, key: key) else { return nil }
                return (recorder, RecordingReader.tail(of: url, lines: 2_000, key: key))
            }
            if let self, let (recorder, tail) = opened, self.recorder == nil, !phase.isDead {
                self.recorder = recorder
                continuedRecording = true
                applyRecordingInterval()
                if let tail, !tail.isEmpty {
                    showEarlierOutput(tail)
                    // As many lines as were asked for (or as much as is read at most): more before it.
                    let breaks = tail.reduce(0) { $0 + ($1 == 0x0a ? 1 : 0) }
                    if breaks >= 1_999 || tail.count >= RecordingReader.tailMaxBytes - 1024 { sink?.earlierOutputIsPartial() }
                }
            } else {
                opened?.0.close()
            }
            done()
        }
    }

    /// Output from an earlier run, shown again: not recorded, and a full-screen program that was
    /// open then is left (the server says what is there now).
    func showEarlierOutput(_ bytes: [UInt8]) {
        guard let sink else { return }
        sink.showEarlierOutput(Array("\u{1b}[0m".utf8)[...] + bytes[...])
        if sink.screenTail(maxRows: 1) == nil { sink.showEarlierOutput(Array("\u{1b}[?1049l".utf8)[...]) }
        // Modes a program had set then are not in force now (the server says what is, on re-attach):
        // mouse reports, bracketed paste, application keys, a scroll region, line-drawing characters,
        // a hidden cursor. The scroll region is reset without moving the cursor.
        sink.showEarlierOutput(Array(("\u{1b}[0m\u{1b}7\u{1b}[r\u{1b}8\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1005l"
            + "\u{1b}[?1006l\u{1b}[?1015l\u{1b}[?2004l\u{1b}[?1l\u{1b}>\u{1b}[?25h\u{1b}[?7h\u{1b}(B\u{1b})B\u{0f}").utf8)[...])
        fedAnything = true
    }
    /// Title reported by the remote program (OSC 0/2 or a screen/tmux name sequence).
    public var remoteTitle: String = ""
    /// What is running in the session (tmux only): foreground command and working directory.
    public private(set) var activity: (command: String, path: String)? {
        didSet { if activity?.command != oldValue?.command { onStateChange?(self) } }
    }
    /// When tmux last said the shell itself is in front (waiting at its prompt); nil while a program
    /// runs, or when it cannot tell (see `foregroundName`).
    @ObservationIgnored public private(set) var shellSeenAt: Date?
    /// Called when the phase or the foreground program changes (to watch what runs in the terminal).
    @ObservationIgnored public var onStateChange: ((TerminalSession) -> Void)?
    /// The program in the foreground, as tmux reports it every 2 s (nil when it cannot tell:
    /// screen, plain shells, Windows, or no answer yet).
    public var foregroundName: String? {
        guard persistence == .tmux, let command = activity?.command, !command.isEmpty else { return nil }
        return command
    }
    /// Step-by-step progress while connecting or re-attaching (nil once online).
    public private(set) var progress: ConnectionProgress?
    /// A password prompt currently waiting in the terminal (sudo, su, ssh, …), if any.
    public private(set) var passwordPrompt: PasswordPrompt?
    @ObservationIgnored private var promptDetector = PasswordPromptDetector()
    /// Set by the app while this session's terminal is the visible tab of a window.
    @ObservationIgnored public var isOnScreen = false

    /// Something in the terminal wants the user: a program's notification (OSC 9/777/99) or the
    /// bell. Shown on the tab until it is looked at.
    public enum Attention: Equatable, Sendable {
        case bell
        case message(TerminalNotification)
    }
    public private(set) var attention: Attention?
    /// Called for each notification or bell (to post a system notification).
    @ObservationIgnored public var onAttention: ((TerminalSession, Attention) -> Void)?
    @ObservationIgnored private var notificationParser = TerminalNotificationParser()

    /// An OSC sequence that may be a notification (9, 777 or 99) or a program's status (7501),
    /// from the terminal emulator.
    public func terminalOSC(code: Int, payload: [UInt8]) {
        if code == 7501 {
            guard let status = ProgramStatus.parse(payload) else { return }
            if status == .query {
                if agentStatusEnabled { send(ProgramStatus.reply[...]) }
            } else if case .update(_, _, _, let app) = status, let activity = status.activity {
                let kind = app.flatMap { AgentKind(program: $0) } ?? agent?.kind ?? foregroundName.flatMap { AgentKind(program: $0) } ?? .other
                agentReported(kind: kind, activity: activity, at: Date())
            }
            return
        }
        guard let n = notificationParser.parse(code: code, payload: payload) else { return }
        raiseAttention(.message(n))
    }

    // MARK: Output activity

    /// Output arrived in the last moments (not the echo of typing, not a replay): the command in
    /// the terminal is visibly doing something. Changes only when it starts or stops.
    public private(set) var outputActive = false
    /// How long without output before `outputActive` goes back to false (Settings ▸ Tabs).
    @ObservationIgnored public var outputQuietDelay: TimeInterval = 3
    @ObservationIgnored private var lastOutputAt = Date.distantPast
    @ObservationIgnored private(set) var lastInputAt = Date.distantPast
    @ObservationIgnored private var quietCheck: DispatchWorkItem?
    @ObservationIgnored private var passthrough = TmuxPassthrough()

    private func noteOutput() {
        guard progress == nil, phase.isOnline else { return }
        let now = Date()
        guard now.timeIntervalSince(lastInputAt) > 0.15 else { return }       // the echo of typing
        lastOutputAt = now
        if !outputActive { outputActive = true }
        guard quietCheck == nil else { return }                              // one check at a time
        scheduleQuietCheck(after: outputQuietDelay)
    }

    private func scheduleQuietCheck(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.quietCheck = nil
            let quiet = Date().timeIntervalSince(self.lastOutputAt)
            if quiet >= self.outputQuietDelay { if self.outputActive { self.outputActive = false } }
            else { self.scheduleQuietCheck(after: self.outputQuietDelay - quiet) }
        }
        quietCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Coding agents

    /// A coding agent running in this terminal and where it stands (from OSC 7501, or the agent's
    /// status file read by the host probe; the newest report wins).
    public struct AgentState: Equatable, Sendable {
        public var kind: AgentKind
        public var activity: AgentActivity
        public var updated: Date
    }
    public private(set) var agent: AgentState?
    /// The time of the newest report, also when it changed nothing shown (not observed).
    @ObservationIgnored private var agentUpdatedQuietly = Date.distantPast
    /// Whether agents' status is followed (Settings ▸ Monitoring and the host's choice; set by the app).
    @ObservationIgnored public var agentStatusEnabled = true
    /// Whether an agent waiting for the user, or finishing, marks the tab and notifies (Settings).
    @ObservationIgnored public var notifyAgentWaiting = true
    @ObservationIgnored public var notifyAgentDone = false

    /// An agent's status, from any source. Older than what is known: ignored. Going into
    /// "waiting" marks the tab and notifies once.
    public func agentReported(kind: AgentKind, activity: AgentActivity, at date: Date) {
        if agent != nil, agentUpdatedQuietly > date { return }
        let before = agent?.activity
        // Only what is shown (the agent and its state) is published: a newer report saying the same
        // (every few seconds while an agent works) must not redraw every tab and sidebar row.
        if let agent, agent.kind == kind, agent.activity == activity {
            agentUpdatedQuietly = date
        } else {
            agent = AgentState(kind: kind, activity: activity, updated: date)
            agentUpdatedQuietly = date
        }
        switch activity {
        case .waiting(let why) where !(before?.isWaiting ?? false) && notifyAgentWaiting:
            raiseAttention(.message(TerminalNotification(title: kind.title, body: "\(kind.title) \(why)")))
        case .done where before == .working && notifyAgentDone:
            raiseAttention(.message(TerminalNotification(title: kind.title, body: "\(kind.title) is done")))
        default:
            break
        }
    }

    /// No agent runs in the terminal any more.
    public func agentEnded() {
        if agent != nil { agent = nil }
    }

    /// The bell rang in this terminal.
    public func bellRang() {
        raiseAttention(.bell)
    }

    /// The tab was looked at.
    public func clearAttention() {
        if attention != nil { attention = nil }
    }

    private func raiseAttention(_ a: Attention) {
        // A message says more than a bell that follows it (Claude Code may send both).
        if case .message = attention, a == .bell {} else { attention = a }
        onAttention?(self, a)
    }
    /// Called when a new password prompt appears (to fill a saved password automatically).
    @ObservationIgnored public var onPasswordPrompt: ((TerminalSession, PasswordPrompt) -> Void)?
    /// Whether to look for password prompts (from the settings; updated on connect and by the app).
    @ObservationIgnored public var detectPrompts = true
    /// The tmux/screen session this tab wanted to attach to no longer exists on the server.
    public private(set) var remoteSessionGone = false
    /// Opened to attach to an existing server session (from the sidebar list).
    public var openedForAttach = false
    /// Which shared connection to the host this session uses (see `SSHOptions.controlSlot`).
    public var controlSlot = 0
    @ObservationIgnored private var holdingGate: String?

    private func sshOptions(_ config: SessionConfiguration) -> SSHOptions {
        var o = config.ssh
        o.controlSlot = controlSlot
        return o
    }

    /// Lets the next queued connection to this host go ahead.
    private func releaseGate() {
        guard let key = holdingGate else { return }
        holdingGate = nil
        Task { await ConnectionGate.shared.release(key) }
    }

    /// Waits until it is this session's turn to log in to the host (see `ConnectionGate`).
    private func waitForGate(_ key: String) async -> Bool {
        let owned = await ConnectionGate.shared.acquire(key)
        if owned { holdingGate = key }
        if Task.isCancelled || intentionalStop { releaseGate(); return false }
        if !owned { ConnectionLog.shared.notice("Went ahead without waiting longer for another sign-in to this host", .signIn, host: key, tab: logTab) }
        return true
    }

    /// The host's platform as detected when connecting (Windows hosts get PowerShell, no persistence).
    public private(set) var platform: RemotePlatform = .posix

    /// Round-trip latency to the server, as shown in the UI. Updated only when what is displayed
    /// would change (10 ms steps, quality) or every 30 s, so frequent samples do not redraw views.
    public private(set) var latency = LatencyStats()
    @ObservationIgnored private var latencyStore = LatencyStats()
    @ObservationIgnored private var latencyPublishedAt = Date.distantPast
    /// Last directory reported by the shell (tmux pane path or OSC 7).
    public var currentDirectory: String? {
        if let p = activity?.path, !p.isEmpty { return p }
        return reportedDirectory
    }
    /// Directory reported through OSC 7 by shells that support it.
    public var reportedDirectory: String?
    /// Last error text from ssh, useful while waiting.
    public private(set) var lastError: String?
    /// Whether the session has been online at least once.
    public private(set) var wasOnline = false
    public private(set) var startedAt = Date()
    public private(set) var endedAt: Date?
    /// The local recording of this session.
    public var recordingURL: URL? { recorder?.url }

    /// The recording, with everything buffered written out first (for search and history).
    public func flushedRecordingURL() -> URL? {
        recorder?.flushNow()
        return recorder?.url
    }

    /// Runs `reader` in the background on the recording as it is now (everything shown so far:
    /// what is on disk and what the recorder still keeps in memory), without making it write
    /// early. False when nothing is recorded.
    public func readRecording(_ reader: @escaping @Sendable (RecordingSnapshot) -> Void) -> Bool {
        guard let recorder else { return false }
        recorder.snapshot(then: reader)
        return true
    }

    /// The recording as it is now (see `readRecording`), nil when nothing is recorded.
    public func currentRecording() async -> RecordingSnapshot? {
        guard let recorder else { return nil }
        return await withCheckedContinuation { done in recorder.snapshot { done.resume(returning: $0) } }
    }

    /// Ctrl+L was typed: noted in the recording (invisibly), so what was on screen before the clear
    /// that follows is kept when the recording is shown again, as it was in the terminal.
    public func noteClearTyped() {
        recorder?.append(ScrollbackRule.typedMarker)
    }

    /// The user ran a command (Return at a prompt): its place and time go into the recording.
    /// Returns the time it is noted with (it identifies the command in the recording's index),
    /// nil when nothing is recorded.
    @discardableResult
    public func noteCommand(column: Int? = nil, up: Int = 0) -> Date? {
        guard let recorder else { return nil }
        let time = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
        recorder.markCommand(at: time, column: column, up: up)
        // Only tmux gives output back after a crash: elsewhere a command's output is written soon.
        if persistence != .tmux { recorder.writeSoon(within: 5) }
        return time
    }

    /// Where lines and commands are in the recording (nil when nothing is recorded).
    public var recordingIndex: RecordingIndex? { recorder?.index }

    /// Writes the recording's buffered output to disk without blocking the main thread.
    public func flushRecording() async {
        guard let recorder else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in recorder.flush { _ in done.resume() } }
    }

    /// The recording and how much output it holds right now (everything shown so far).
    public func recordingSnapshot() -> (url: URL, length: Int)? {
        recorder.map { ($0.url, $0.flushedLength()) }
    }

    /// Called whenever the session ends, archived or not.
    @ObservationIgnored public var onEnded: ((TerminalSession) -> Void)?
    /// Called when the session becomes dead (to archive it).
    @ObservationIgnored public var onDeath: ((TerminalSession) -> Void)?
    /// Called when the negotiated persistence backend becomes known, so the session can be
    /// saved immediately and re-attached even if the app is killed.
    @ObservationIgnored public var onPersistenceKnown: ((TerminalSession) -> Void)?
    /// Called every time the session comes online (first connect and every reconnect).
    @ObservationIgnored public var onOnline: ((TerminalSession) -> Void)?
    /// Without connection sharing, this tab's ssh signs in itself: its sign-in is told which
    /// connection it is for (see `SharedConnections.onSignInStarted`).
    private func bindOwnSignIn(_ options: SSHOptions) {
        guard !options.usesSharedConnection, !descriptor.target.isLocal, let identity = signInIdentity,
              let token = askPassEnv["TETHER_ASKPASS_TOKEN"] else { return }
        SharedConnections.onSignInStarted?(token, identity)
    }

    @ObservationIgnored private var signInIdentity: String?

    /// Ends its tmux/screen session on the server as soon as it is connected (see
    /// `SessionManager.endWhenConnected`).
    public var endWhenConnected = false

    /// Ends this tab's tmux/screen session on the server through the shared connection (signing in
    /// once for the server if needed), without attaching to it. Whether it worked (or was gone).
    public func endRemoteSession() async -> Bool {
        let script = persistence == .tmux
            ? RemoteScript(#"tmux kill-session -t "=$1" 2>/dev/null; tmux has-session -t "=$1" 2>/dev/null && exit 1; exit 0"#)
            : RemoteScript(#"screen -S "$1" -X quit >/dev/null 2>&1; exit 0"#)
        let executor = RemoteExecutor(target: descriptor.target, options: sshOptions(configurationProvider()))
        let r = await executor.run(script, arguments: [descriptor.remoteSessionName], timeout: 60, purpose: "command")
        return r.succeeded
    }

    /// Whether the user ended the shell themselves a moment ago (`exit`, `logout`, Ctrl-D): then a
    /// shell that ends is no surprise. Only those words are followed — nothing else typed is kept.
    @ObservationIgnored private var endingWord = ""
    /// Something other than the start of `exit` / `logout` was typed on this line.
    @ObservationIgnored private var lineIsOther = false
    @ObservationIgnored private var userEndedAt: Date?

    private func noteEnding(_ bytes: ArraySlice<UInt8>) {
        for b in bytes {
            if b == 0x04 { userEndedAt = Date(); endingWord = ""; lineIsOther = false; continue }
            if b == 0x0d || b == 0x0a || b == 0x03 {
                if b != 0x03, !lineIsOther, endingWord == "exit" || endingWord == "logout" { userEndedAt = Date() }
                endingWord = ""
                lineIsOther = false
                continue
            }
            guard !lineIsOther else { continue }
            let next = endingWord + String(UnicodeScalar(b))
            if "exit".hasPrefix(next) || "logout".hasPrefix(next) { endingWord = next } else { endingWord = ""; lineIsOther = true }
        }
    }

    var endedByUser: Bool { userEndedAt.map { Date().timeIntervalSince($0) < 10 } ?? false }

    /// Why a shell or tmux session on the server ended although nobody ended it: asked over the
    /// connection that is still there, in one short look (memory, an idle limit, the kernel's
    /// out-of-memory killer, a restart). nil when nothing tells.
    private func diagnoseUnexpectedEnd(code: Int32?) async -> String? {
        var hints: [String] = []
        if let code, code > 128, code < 160 {
            let names: [Int32: String] = [1: "SIGHUP", 2: "SIGINT", 9: "SIGKILL", 15: "SIGTERM"]
            hints.append("ended by signal \(names[code - 128] ?? String(code - 128))")
        }
        guard !descriptor.target.isLocal, !PlatformCache.shared.isDevice(descriptor.target.key), !platform.isWindows else {
            return hints.isEmpty ? nil : hints.joined(separator: "; ")
        }
        let executor = RemoteExecutor(target: descriptor.target, options: sshOptions(configurationProvider()))
        let r = await executor.run(RemoteScript(ServerDiagnosis.script), timeout: 8, purpose: "monitor")
        if r.succeeded { hints += ServerDiagnosis.hints(from: r.output) }
        return hints.isEmpty ? nil : hints.joined(separator: "; ")
    }

    /// Ends the tab because its shell or tmux session ended on the server; when nobody ended it, the
    /// reason found (low memory, an idle limit, …) is said and logged.
    private func finishEnded(_ base: String, code: Int32?) {
        guard !endedByUser else { finish(reason: base, archive: true); return }
        let host = descriptor.target.key
        Task { [weak self] in
            let hint = await self?.diagnoseUnexpectedEnd(code: code)
            guard let self, !self.phase.isDead else { return }
            let reason = hint.map { base + " — " + $0 } ?? base
            ConnectionLog.shared.problem("A session ended on the server without being asked to", .tab, host: host, tab: self.logTab, detail: reason)
            self.finish(reason: reason, archive: true)
        }
    }

    // MARK: Typing while the connection is away

    /// What was typed while the connection was away: sent once the tab is back in the same tmux or
    /// screen session. A tab whose shell ended (no tmux or screen) sends none of it — it could run
    /// in a fresh shell somewhere else — and nothing typed while a password is asked for is kept.
    public private(set) var heldInput: [UInt8] = []
    /// Back, but what was held waited too long to be sent without asking (`sendHeldInput`).
    public private(set) var heldInputNeedsConfirmation = false
    @ObservationIgnored private var heldSince: Date?
    public static let heldInputLimit = 4096
    /// Held longer than this when the tab is back: asked about instead of sent.
    public static let heldInputAutoSendAge: TimeInterval = 30

    private func holdInput(_ bytes: ArraySlice<UInt8>) {
        // Ctrl-C while away: what was held is dropped (as it would cancel a line in the shell).
        if bytes.contains(0x03) { discardHeldInput(); return }
        guard passwordPrompt == nil, persistence == .tmux || persistence == .screen,
              heldInput.count + bytes.count <= Self.heldInputLimit else { NSSound.beep(); return }
        if heldInput.isEmpty { heldSince = Date() }
        heldInput.append(contentsOf: bytes)
    }

    public func discardHeldInput() {
        heldInput = []
        heldSince = nil
        heldInputNeedsConfirmation = false
    }

    /// Sends what was typed while away (after the user confirmed, or at once when it is fresh).
    public func sendHeldInput() {
        guard phase.isOnline, !heldInput.isEmpty else { return }
        let bytes = heldInput
        discardHeldInput()
        ConnectionLog.shared.info("Sent \(bytes.count) characters typed while the connection was away", .tab, host: descriptor.target.key, tab: logTab)
        if bytes.contains(0x0d) { sink?.heldCommandSent() }
        if let tmux { tmux.sendInput(bytes[...]) } else { process?.send(data: bytes[...]) }
    }

    /// The tab is online again: back in the same session (tmux/screen) — held input goes now, or is
    /// asked about when it waited long; a new shell gets none of it.
    private func deliverHeldInput() {
        guard !heldInput.isEmpty else { return }
        guard persistence == .tmux || persistence == .screen else {
            ConnectionLog.shared.notice("Text typed while away was not sent: the shell had ended", .tab, host: descriptor.target.key, tab: logTab)
            discardHeldInput()
            return
        }
        if let heldSince, Date().timeIntervalSince(heldSince) <= Self.heldInputAutoSendAge {
            sendHeldInput()
        } else {
            heldInputNeedsConfirmation = true
        }
    }

    /// The tab lost its connection and is back: when and why (shown for a few seconds).
    public struct Drop: Sendable, Equatable {
        public var date: Date
        public var reason: String
    }
    public private(set) var recentRecovery: Drop?
    /// Why it last lost its connection while online (cleared once it is back and that was shown).
    @ObservationIgnored private var lastDrop: Drop?

    /// Notes why a tab that was working lost its connection.
    private func noteDrop(_ reason: String) {
        guard wasOnline, lastDrop == nil else { return }
        lastDrop = Drop(date: Date(), reason: Self.readableReason(reason))
    }

    /// ssh's last words as a short reason for people (the log keeps the full text).
    nonisolated static func readableReason(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("debug") && !$0.hasPrefix("Warning: Permanently added") }
        return lines.last.map { String($0) } ?? "the connection ended"
    }

    /// The server stopped answering this tab (its shared connection should be checked).
    @ObservationIgnored public var onStall: ((TerminalSession) -> Void)?
    /// The network is away or the Mac is asleep (set by `SessionManager`): no stall is judged, and
    /// when it ends the clock starts afresh.
    public var connectivityHeld = false {
        didSet { if oldValue && !connectivityHeld { heldUntil = ProcessInfo.processInfo.systemUptime } }
    }
    @ObservationIgnored private var heldUntil: TimeInterval = 0
    /// Session refusals on the current slot since the last time this tab was online.
    @ObservationIgnored private var refusedOnThisSlot = 0
    /// Called when ssh needs a configuration refresh before reconnecting.
    @ObservationIgnored public var configurationProvider: () -> SessionConfiguration

    @ObservationIgnored public private(set) var sink: TerminalSink?
    @ObservationIgnored private var process: LocalProcess?
    @ObservationIgnored private var bridge: ProcessBridge?
    @ObservationIgnored private var tmux: TmuxDriver?
    @ObservationIgnored private var markerBuffer: [UInt8] = []
    @ObservationIgnored private var markerResolved = false
    /// The bootstrap never answered and the tab was taken as a plain session (see
    /// `watchForMissingMarker`): until `guessedUntil`, a marker that still comes is honoured.
    @ObservationIgnored private var guessedPlain = false
    @ObservationIgnored private var guessedUntil = Date.distantPast
    @ObservationIgnored private var onlineBeforeGuess = false
    /// Output arrived from the ssh process of this attempt (not an earlier one).
    @ObservationIgnored private var receivedThisAttempt = false
    /// Bytes received while restoring the screen, shown in the progress.
    @ObservationIgnored private var restoredBytes = 0
    @ObservationIgnored private var restoreShownAt = Date.distantPast
    /// The plain shell's process id on the host, as the bootstrap (or PowerShell) reported it.
    @ObservationIgnored private var shellPid: Int?
    /// Windows: the unique part of the PowerShell command line this tab started (see `WindowsShell`).
    @ObservationIgnored private var windowsShellTag: String?
    @ObservationIgnored private var recorder: SessionRecorder?
    /// The size last noted in the recording (`display`).
    @ObservationIgnored private var recordedSize: (recording: URL, cols: Int, rows: Int)?
    @ObservationIgnored private var bytesSinceSizeMarker = 0
    @ObservationIgnored private var recordedEscapes = EscapeState()
    @ObservationIgnored private(set) var attempt = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// The coming launch is one the user asked for (Retry, Reconnect Now): it tries even when
    /// another tab's attempt to the server failed while it waited for its turn.
    @ObservationIgnored private var askedByUser = false
    @ObservationIgnored private var askPassEnv: [String: String] = [:]
    @ObservationIgnored private var stderrTail = ""
    @ObservationIgnored private var intentionalStop = false
    @ObservationIgnored private var tmuxExitReason: String??
    @ObservationIgnored private var fedAnything = false
    @ObservationIgnored private var titleFilter = TitleSequenceFilter()
    @ObservationIgnored private var activityTask: Task<Void, Never>?

    public init(descriptor: SessionDescriptor, configuration: @escaping () -> SessionConfiguration) {
        id = descriptor.id
        self.descriptor = descriptor
        configurationProvider = configuration
    }

    // MARK: Public API

    /// Whether a program is a shell (at its prompt), see `ShellNames`.
    public static func isShell(_ program: String) -> Bool { ShellNames.contains(program) }

    /// The program in the foreground of the terminal right now, when tmux can tell (nil otherwise:
    /// screen, plain shells, or no answer within 2 s).
    public func foregroundCommand() async -> String? {
        await tmuxQuery("#{pane_current_command}")
    }

    /// The process in the terminal's foreground, as the host sees it: the program, the real user who
    /// started it, and its arguments. For a password prompt this says whose password is meant —
    /// `sudo` asks for its caller's, `su` for its target user's (both prompts may just say
    /// "Password:", as on macOS). nil when tmux or `ps` cannot tell.
    public func foregroundProcess() async -> ForegroundProcess? {
        guard let command = await foregroundCommand(), !command.isEmpty,
              let tty = await tmuxQuery("#{pane_tty}"), !tty.isEmpty else { return nil }
        let name = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        let executor = RemoteExecutor(target: descriptor.target, options: sshOptions(configurationProvider()))
        let r = await executor.run(script: #"ps -t "$1" -o stat=,ruser=,args= 2>/dev/null"#, arguments: [name], timeout: 5, purpose: "monitor")
        guard r.succeeded, let found = ForegroundProcess.parse(ps: r.output, command: command) else { return nil }
        return found
    }

    /// Where this terminal's shell runs on the host, to find the command running in it. nil while
    /// offline or when it cannot be told (an old bootstrap, an unanswered tmux question).
    public func shellAnchor() async -> ShellAnchor? {
        guard phase.isOnline else { return nil }
        switch persistence {
        case .tmux:
            return await tmuxQuery("#{pane_pid}").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { .posix(pid: $0) }
        case .screen:
            return .screen(session: descriptor.remoteSessionName)
        case .plain:
            if platform.isWindows { return windowsShellTag.map { .windows(commandTag: $0) } }
            return shellPid.map { .posix(pid: $0) }
        case .unknown:
            return nil
        }
    }

    /// The shell's working directory now: asked from tmux (the pane's current path) when it can
    /// tell, otherwise the last one the shell reported (OSC 7). nil when unknown.
    public func workingDirectory() async -> String? {
        if persistence == .tmux, phase.isOnline, let path = await tmuxQuery("#{pane_current_path}"), !path.isEmpty {
            return path
        }
        return currentDirectory
    }

    /// The name of the program in front in a tmux pane (zsh, vim, ssh …); nil when unknown.
    public func tmuxForegroundCommand() async -> String? {
        guard persistence == .tmux, phase.isOnline else { return nil }
        return await tmuxQuery("#{pane_current_command}")?.trimmingCharacters(in: .whitespaces)
    }

    private func tmuxQuery(_ format: String) async -> String? {
        guard let tmux else { return nil }
        return await tmux.query(format, timeout: .seconds(2))
    }

    /// Tab title: a custom name if the user set one, otherwise derived from what is running.
    /// A coding agent runs in the tab and has a session name (`Claude Code: Fix login bug`); set by
    /// the app from the last look at the host's tmux sessions, nil when none runs.
    public var agentTitle: String?

    public var displayTitle: String {
        if descriptor.customTitle { return descriptor.title }
        let host = descriptor.target.displayName
        if let agentTitle, !agentTitle.isEmpty { return "\(agentTitle) — \(host)" }
        if let activity, !activity.command.isEmpty {
            if Self.isShell(activity.command) {
                let dir = (activity.path as NSString).lastPathComponent
                return dir.isEmpty ? host : "\(host): \(Self.abbreviate(activity.path, dir))"
            }
            return "\(activity.command) — \(host)"
        }
        let t = remoteTitle.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? host : t
    }

    /// The tab as the Connection Log names it: its title, and the tmux or screen session it shows.
    var logTab: String {
        persistence == .plain || descriptor.remoteSessionName.isEmpty ? displayTitle
            : "\(displayTitle) (\(descriptor.remoteSessionName))"
    }

    private static func keptBy(_ mode: PersistenceMode) -> String {
        switch mode {
        case .auto: "kept running by tmux or screen when the server has one"
        case .tmux: "kept running by tmux"
        case .screen: "kept running by GNU screen"
        case .off: "plain shell"
        }
    }

    /// When the current attempt to connect began (for "connected in 2.1 s").
    @ObservationIgnored private var attemptBegan = Date()

    private static func abbreviate(_ path: String, _ last: String) -> String {
        if path.range(of: #"^/(home|Users)/[^/]+$"#, options: .regularExpression) != nil || path == "/root" { return "~" }
        return last
    }

    public func attach(sink: TerminalSink) {
        self.sink = sink
    }

    /// Starts a brand-new session (creates the remote tmux/screen session if needed).
    public func start() {
        launch(attachOnly: false)
    }

    /// Restores a session saved before the app quit: only re-attaches, never creates.
    public func restore(previous: ActivePersistence) {
        persistence = previous
        restoredFromDisk = true
        launch(attachOnly: true)
    }

    /// User input from the terminal view. Dropped unless the session can accept it.
    /// True once a command was typed and sent in this session (any non-blank line + Return).
    public private(set) var hasRunCommands = false
    @ObservationIgnored private var typedOnLine = false

    /// The tmux/screen session on the server may hold work: this tab was online, or it was restored
    /// or opened to attach to a session that already existed there.
    public var mayHoldServerWork: Bool { wasOnline || restoredFromDisk || openedForAttach }

    /// Nothing worth keeping: no command was run here, nothing is running in it, and it was not
    /// re-attached to an existing session (which may hold earlier work). Closing it needs no question.
    public var isUnused: Bool {
        if hasRunCommands || restoredFromDisk || openedForAttach { return false }
        if let command = activity?.command, !command.isEmpty, !Self.isShell(command) { return false }
        return true
    }

    public func send(_ bytes: ArraySlice<UInt8>) {
        lastInputAt = Date()
        noteEnding(bytes)
        if !hasRunCommands {
            for b in bytes {
                if b == 0x0d || b == 0x0a { if typedOnLine { hasRunCommands = true }; typedOnLine = false }
                else if b > 0x20 && b != 0x7f { typedOnLine = true }
            }
        }
        if passwordPrompt != nil, bytes.contains(0x0d) || bytes.contains(0x0a) || bytes.contains(0x03) {
            passwordPrompt = nil
            promptDetector.reset()
        }
        switch phase {
        case .online:
            if let tmux { tmux.sendInput(bytes) } else { process?.send(data: bytes) }
        case .connecting:
            // Allow typing a password or answering a host-key prompt during login.
            if tmux == nil { process?.send(data: bytes) }
        case .waiting:
            holdInput(bytes)
        case .suspended, .dead:
            NSSound.beep()
        }
    }

    public func terminalDidResize(cols: Int, rows: Int) {
        guard let process, process.running else { return }
        var size = winsize(ws_row: UInt16(clamping: max(rows, 1)), ws_col: UInt16(clamping: max(cols, 1)), ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
        tmux?.resize(cols: cols, rows: rows)
    }

    /// Disconnects on purpose while keeping the tmux/screen session running on the server.
    /// Only meaningful for persistent sessions (a plain shell would end).
    public var canSuspend: Bool {
        (phase.isOnline || { if case .waiting = phase { true } else { false } }())
            && (persistence == .tmux || persistence == .screen)
    }

    public func suspend() {
        guard canSuspend else { return }
        retryTask?.cancel()
        activityTask?.cancel()
        intentionalStop = true
        tmux?.detach()
        let process = self.process
        self.process = nil
        tmux = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { process?.terminate() }
        AskPassBridge.shared.revoke(environment: askPassEnv)
        recorder?.mark("Disconnected (suspended) \(Date().formatted(date: .omitted, time: .standard))")
        if persistence != .tmux {   // tmux: keep the screen as it was (see showLostNotice)
            display(Array("\r\n\u{1b}[2m[Tether] Disconnected. The session keeps running on the server.\u{1b}[0m\r\n".utf8))
        }
        attempt = 0
        phase = .suspended
    }

    /// Marks a restored session as suspended without connecting (it was suspended when the app quit).
    public func restoreSuspended(previous: ActivePersistence) {
        persistence = previous
        restoredFromDisk = true
        phase = .suspended
    }

    /// Re-attaches a suspended session.
    public func resume() {
        guard phase.isSuspended else { return }
        phase = .waiting(attempt: 0, nextRetry: nil)
        launch(attachOnly: true)
    }

    /// Retry immediately (used by the "Reconnect now" button and on network changes).
    /// A login of this tab needed the user while the tab was not in front, and its question went
    /// unanswered until ssh gave up. It waits to be shown instead of retrying on a timer: unanswered
    /// logins every few minutes help nobody and fill the server's log (fail2ban and similar may ban).
    public private(set) var waitsForUser = false

    /// Why automatic retries stopped until the user presses Reconnect: the server refused the sign-in
    /// (a wrong or changed password, a key it no longer takes) or the user cancelled the prompt.
    /// Retrying on a timer would only ask again and again — or send the same wrong password.
    public private(set) var retryPausedReason: String?
    /// Set by the bootstrap's `unreachable` marker, read when its process ends.
    private var unreachableReason: String?

    public func pauseRetries(_ reason: String) {
        guard !phase.isOnline, !phase.isDead else { return }
        retryPausedReason = reason
        lastError = reason
        if case .waiting(let attempt, _) = phase {
            retryTask?.cancel()
            retryTask = nil
            phase = .waiting(attempt: attempt, nextRetry: nil)
        }
    }

    /// ssh's words for a sign-in the server refused (not a network problem that may pass).
    public nonisolated static func isRefusedSignIn(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("permission denied (") || m.contains("too many authentication failures")
            || m.contains("host key verification failed") || m.contains("no more authentication methods")
    }

    /// See `waitsForUser`: a retry already scheduled is called off, and failed attempts schedule
    /// no more until the tab is shown.
    public func waitForUser() {
        guard !phase.isOnline, !phase.isDead else { return }
        waitsForUser = true
        if case .waiting(let attempt, let next?) = phase, next > Date() {
            retryTask?.cancel()
            retryTask = nil
            phase = .waiting(attempt: attempt, nextRetry: nil)
            lastError = "Needs your password — click the tab to sign in"
        }
    }

    /// The tab is shown: a login that waited for the user starts now (and may ask).
    public func shownToUser() {
        guard waitsForUser else { return }
        waitsForUser = false
        reconnectNow()
    }

    /// Starts the attempt again from the beginning: an attempt under way (an ssh waiting on a
    /// connection that went dead) is stopped first. Used by Retry through `SessionManager.retryNow`.
    public func restartAttempt() {
        if phase.isDead { retryAfterFailure(); return }
        guard !phase.isOnline else { return }
        waitsForUser = false
        retryPausedReason = nil
        retryTask?.cancel()
        retryTask = nil
        connectTask?.cancel()
        connectingAttempt = nil
        releaseGate()
        if let p = process {
            intentionalStop = true
            p.terminate()
            process = nil
            tmux = nil
            AskPassBridge.shared.revoke(environment: askPassEnv)
            intentionalStop = false
        }
        ConnectionLog.shared.info("Tab tries again now (asked)", .tab, host: descriptor.target.key, tab: logTab)
        askedByUser = true
        launch(attachOnly: wasOnline || restoredFromDisk)
    }

    /// A check of this tab's connection is under way: the card says so.
    public func noteConnectionCheck(_ checking: Bool) {
        if checking {
            progress?.detail = "Checking the connection to \(descriptor.target.displayName)…"
        } else if progress?.detail.hasPrefix("Checking the connection") == true {
            progress?.detail = "Connecting to \(descriptor.target.displayName)"
        }
    }

    public func reconnectNow() {
        guard case .waiting = phase else { return }
        // An attempt is already running (its login or its terminal): a second one would leave two
        // ssh processes feeding this terminal.
        guard process == nil, !connecting else { waitsForUser = false; retryPausedReason = nil; return }
        waitsForUser = false
        retryPausedReason = nil
        retryTask?.cancel()
        retryTask = nil
        // A connection that only looks alive is the probe's business (SessionManager): closing it
        // here because a quick check was slow dropped every other tab on it, and they all signed in
        // again.
        launch(attachOnly: wasOnline || restoredFromDisk)
    }

    /// Ends the session. For tmux/screen, `killRemote` decides whether the remote session
    /// keeps running (detach) or is terminated.
    public func close(killRemote: Bool) {
        intentionalStop = true
        connectTask?.cancel()
        retryTask?.cancel()
        activityTask?.cancel()
        if killRemote, let tmux { tmux.killSession(descriptor.remoteSessionName) }
        if killRemote, persistence == .tmux || persistence == .screen {
            let name = descriptor.remoteSessionName
            let target = descriptor.target
            let options = sshOptions(configurationProvider())
            let script = persistence == .tmux
                ? "tmux kill-session -t \"=$1\" 2>/dev/null"
                : "screen -S \"$1\" -X quit 2>/dev/null"
            Task.detached {
                _ = await RemoteExecutor(target: target, options: options).run(script: script, arguments: [name], timeout: 10)
            }
        }
        if let tmux, !killRemote { tmux.detach() }
        // Give the kill/detach command a moment to reach the server before dropping the connection.
        let process = self.process
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { process?.terminate() }
        // Nothing was done in it: keep no recording, only the fact that it was opened.
        if wasOnline && isUnused {
            recorder?.discard()
            recorder = nil
            finish(reason: "Opened — closed without running anything", archive: true)
            return
        }
        finish(reason: killRemote ? "Closed by user" : "Detached by user", archive: wasOnline)
    }

    /// Marks the session dead without touching the remote side (e.g. app quitting with plain shells).
    public func abandon() {
        intentionalStop = true
        connectTask?.cancel()
        retryTask?.cancel()
        process?.terminate()
        recorder?.close()
    }

    // MARK: Launching

    /// Starts (or restarts) the connection. For remote hosts with connection sharing, the shared
    /// connection is opened first as its own step, so every stage (connect, sign in) can be shown;
    /// the terminal then attaches to it instantly.
    private func launch(attachOnly: Bool) {
        let config = configurationProvider()
        let asked = askedByUser
        askedByUser = false
        detectPrompts = config.detectPasswordPrompts
        intentionalStop = false
        markerBuffer = []
        markerResolved = false
        shellPid = nil
        tmux = nil
        tmuxExitReason = nil
        stderrTail = ""
        if !wasOnline && !attachOnly { phase = .connecting }
        pendingAttachOnly = attachOnly
        attemptBegan = Date()
        if !descriptor.target.isLocal {
            let how = [attachOnly ? "re-attaching" : "new session", Self.keptBy(descriptor.persistence),
                       attempt > 0 ? "try \(attempt + 1)" : nil, controlSlot > 0 ? "connection \(controlSlot + 1)" : nil,
                       sshOptions(config).useControlMaster ? nil : "connection sharing off"].compactMap { $0 }
            ConnectionLog.shared.info(wasOnline ? "Tab reconnecting" : "Tab connecting", .tab, host: descriptor.target.key, tab: logTab,
                                      detail: how.joined(separator: " · "))
        }

        if recorder == nil, config.recordingEnabled, !descriptor.isPrivate {
            recorder = SessionRecorder(targetKey: descriptor.target.key, sessionID: id)
            applyRecordingInterval()
        }

        var p = ConnectionProgress()
        p.includesRestore = attachOnly && persistence != .plain
        p.attempt = attempt
        if case .adhoc(_, _, _, let jump?, _) = descriptor.target { p.hops = jump.split(separator: ",").map(String.init) }
        p.detail = descriptor.target.isLocal ? "Starting a local shell" : "Connecting to \(descriptor.target.displayName)"
        progress = p

        connectTask?.cancel()
        let target = descriptor.target
        guard !target.isLocal, sshOptions(config).useControlMaster else {
            platform = target.isLocal ? .posix : (PlatformCache.shared.cached(target.key) ?? .posix)
            if target.isLocal { startTerminal(attachOnly: attachOnly, options: sshOptions(config)); return }
            // Without a shared connection every tab is its own login: start them one at a time
            // (the gate is released once this one is online or has failed).
            let began = attemptBegan
            connectTask = Task { [weak self] in
                guard let self else { return }
                // A host never seen: one short question first, so a network device gets a plain
                // login and no shell script (with a shared connection this happens below). Before
                // taking the gate: the question waits for logins in progress, this one included.
                if !PlatformCache.shared.isKnown(target.key) {
                    self.progress?.detail = "Checking the server's shell"
                    let executor = RemoteExecutor(target: target, options: self.sshOptions(config))
                    self.platform = await executor.resolvedPlatform()
                    guard !Task.isCancelled, !self.intentionalStop else { return }
                }
                guard await self.waitForGate(target.key) else { return }
                // Another tab to this server failed while this one waited for its turn: one more
                // attempt now would only wait out the same timeout (a hundred tabs, a hundred
                // timeouts in a row). That failure counts for this tab too, and it joins the
                // server's next round.
                if !asked, let failed = HostRetryClock.shared.failedSince(began, host: target.key) {
                    self.releaseGate()
                    self.sharedServerFailure(failed.why)
                    return
                }
                // Each tab signs in by itself here: as the same connection, so a password typed for
                // one answers the others (Signing In Again).
                self.signInIdentity = await SharedConnections.shared.identity(of: target, options: self.sshOptions(config))
                guard !Task.isCancelled, !self.intentionalStop else { self.releaseGate(); return }
                self.startTerminal(attachOnly: attachOnly, options: self.sshOptions(config))
            }
            return
        }
        let attemptID = UUID()
        connectingAttempt = attemptID
        connectTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.connectingAttempt == attemptID { self.connectingAttempt = nil } }
            let options = self.sshOptions(config)
            // Another tab to this host already waited in vain for a password: no new sign-in (and
            // no new question) until this tab is shown — unless the connection is there anyway.
            if self.waitsForUser, !(await SharedConnections.shared.isUp(target, options: options)) {
                guard !Task.isCancelled, !self.intentionalStop else { return }
                self.scheduleReconnect()
                return
            }
            // One sign-in per host: every tab, file window and transfer that wants it now waits for
            // the same one, and the terminal then runs as a client of that connection only.
            let signIn = SharedConnections.SignIn(purpose: "connect", sessionID: self.id) { [weak self] line in
                Task { @MainActor in self?.progress?.ingest(line) }
            }
            let outcome = await SharedConnections.shared.prepare(target, options: options, signIn: signIn)
            guard !Task.isCancelled, !self.intentionalStop else { return }
            let ready: SSHOptions
            switch outcome {
            case .ready(let o, let reused):
                ready = o
                if reused { self.progress?.detail = "Using the existing connection" }
            case .needsUser(let message):
                self.connectionFailed(message)
                return
            case .failed(let message, let log):
                // Another tab's sign-in failed for this one too: its lines tell why.
                if self.progress?.log.isEmpty ?? true { log.forEach { self.progress?.ingest($0) } }
                if self.waitsForUser { self.scheduleReconnect() } else { self.connectionFailed(message) }
                return
            }
            self.progress?.detail = "Checking the server's shell"
            self.platform = await RemoteExecutor(target: target, options: ready).resolvedPlatform()
            guard !Task.isCancelled, !self.intentionalStop else { return }
            self.startTerminal(attachOnly: attachOnly, options: ready)
        }
    }

    /// True when the session ended because it could not connect (not because the remote shell ended).
    public private(set) var endedByConnectionFailure = false

    /// Tries the same session again after it gave up connecting. Re-attaches to its tmux/screen
    /// session if it had one, instead of starting a new session.
    public func retryAfterFailure() {
        guard phase.isDead, endedByConnectionFailure else { return }
        endedByConnectionFailure = false
        waitsForUser = false
        retryPausedReason = nil
        endedAt = nil
        recorder = nil      // the old one was closed; a new recording starts
        attempt = 0
        lastError = nil
        phase = wasOnline || restoredFromDisk ? .waiting(attempt: 0, nextRetry: nil) : .connecting
        askedByUser = true
        launch(attachOnly: wasOnline || restoredFromDisk)
    }

    /// Opening the shared connection failed: show why, then retry or give up.
    private func connectionFailed(_ fallback: String) {
        ConnectionLog.shared.problem("Tab could not connect", .tab, host: descriptor.target.key, tab: logTab, detail: progress?.failure ?? fallback)
        if progress?.failure == nil { progress?.failure = "Could not connect (\(fallback))." }
        let message = progress?.failure ?? fallback
        lastError = message
        let permanent = progress.map { p in p.log.contains { Self.isPermanentFailure($0) } } ?? false
        let unreachable = ConnectionProgress.isUnreachable(fallback)
            || (progress.map { p in p.log.contains { ConnectionProgress.isUnreachable($0) } } ?? false)
        // A new tab gives up after a few failures that will not pass by themselves; a server that
        // does not answer is waited for like any other (it may come back), in the server's rounds.
        if (!wasOnline && !pendingAttachOnly && (permanent || (attempt >= 2 && !unreachable))) || progress?.hostKeyChange != nil {
            endedByConnectionFailure = true
            noteIfUnreachable(([fallback] + (progress?.log ?? [])).joined(separator: "\n"), why: message)
            finish(reason: message, archive: false)
            return
        }
        if progress.map({ p in p.log.contains { Self.isRefusedSignIn($0) } }) == true {
            retryPausedReason = "The server did not accept the sign-in. Check the password or key, then press Reconnect."
        }
        scheduleReconnect(unreachable: unreachable)
    }

    /// Runs the terminal process: ssh (attaching to the shared connection) with the bootstrap command.
    private func startTerminal(attachOnly: Bool, options: SSHOptions) {
        let config = configurationProvider()
        resetAttempt()
        progress?.step = .startSession
        progress?.detail = descriptor.target.isLocal ? "Starting a local shell" : "Starting the session on the server"

        if !descriptor.target.isLocal, PlatformCache.shared.isDevice(descriptor.target.key) {
            startPlainLogin(attachOnly: attachOnly, options: options, windows: false)
            return
        }
        if platform.isWindows {
            startPlainLogin(attachOnly: attachOnly, options: options, windows: true)
            return
        }
        let mode: PersistenceMode
        switch persistence {
        case .tmux: mode = .tmux
        case .screen: mode = .screen
        case .plain: mode = .off
        case .unknown: mode = descriptor.persistence
        }
        let remote = RemoteBootstrap.command(mode: mode, sessionName: descriptor.remoteSessionName,
                                             attachOnly: attachOnly, size: sink?.cellSize ?? (80, 24),
                                             directory: attachOnly ? nil : descriptor.initialDirectory,
                                             historyLimit: config.serverHistoryLines)
        let local = descriptor.target.isLocal
        let executable = local ? "/bin/sh" : options.sshBinary
        let args = local ? ["-c", remote] : options.interactiveArguments(target: descriptor.target, remoteCommand: remote)

        AskPassBridge.shared.revoke(environment: askPassEnv)
        // "prefer" makes password prompts appear as a native sheet (with keychain support),
        // which also works while input is blocked during a reconnect. Never for local shells: every
        // program started there could use the token to ask Tether for saved secrets.
        askPassEnv = local ? [:] : AskPassBridge.shared.environment(targetKey: descriptor.target.key, purpose: "terminal", mode: "prefer", sessionID: id)
        bindOwnSignIn(options)

        // Without `$TMUX`: started from inside tmux (a terminal, a test run), local sessions would
        // otherwise be created on that outer server, and ending them could end it.
        var env = ChildEnvironment.base
        for key in ["SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "TETHER_ASKPASS_SOCKET", "TETHER_ASKPASS_TOKEN"] { env[key] = nil }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Tether"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        for (k, v) in askPassEnv { env[k] = v }

        let bridge = ProcessBridge(owner: self)
        self.bridge = bridge
        let process = LocalProcess(delegate: bridge, dispatchQueue: .main)
        bridge.process = process
        self.process = process
        if local { env["PATH"] = ChildEnvironment.local["PATH"] }
        // A Finder-launched app runs in "/": local shells start in the home folder like Terminal.app.
        process.startProcess(executable: executable, args: args,
                             environment: env.map { "\($0.key)=\($0.value)" }, execName: local ? "sh" : "ssh",
                             currentDirectory: local ? (descriptor.initialDirectory ?? NSHomeDirectory()) : nil)
        AskPassBridge.shared.bindToken(askPassEnv, pid: process.shellPid)
        if !local { watchForMissingMarker(process) }
        if !local, options.usesSharedConnection { watchForSilentStart(process) }
    }

    /// A terminal that gets nothing at all for a while over a connection that only looks alive (its
    /// link died without anything noticing — no keep-alives, by default): the connection is checked,
    /// and closed if dead, so the tab signs in afresh instead of waiting for ever.
    private func watchForSilentStart(_ started: LocalProcess) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.process === started, !self.receivedThisAttempt, !self.phase.isDead, !self.intentionalStop,
                  !self.connectivityHeld, !AskPassBridge.shared.isAsking(environment: self.askPassEnv) else { return }
            ConnectionLog.shared.notice("Tab heard nothing from the server for 15 s; checking its connection", .tab, host: self.descriptor.target.key, tab: self.logTab)
            self.onStall?(self)
        }
    }

    /// The server never answered the bootstrap, yet something is on the screen and nothing asks
    /// for a password: a device that ignores the command it was given and shows its own command
    /// line, or a menu. After a while the tab is used as it is (a plain session) instead of waiting
    /// for ever behind "Connecting".
    /// Re-attaching to a known tmux/screen session is never guessed: only a slow server or link keeps
    /// its answer away, and a guess would show tmux's control stream as text and end in "Shell exited".
    private func watchForMissingMarker(_ started: LocalProcess) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.process === started, !self.markerResolved, !self.phase.isDead, !self.intentionalStop else { return }
            let guess = Self.shouldGuessPlain(
                reattachingPersistent: self.pendingAttachOnly && (self.persistence == .tmux || self.persistence == .screen),
                receivedThisAttempt: self.receivedThisAttempt,
                quietFor: Date().timeIntervalSince(self.lastReceivedAt),
                promptShown: self.passwordPrompt != nil,
                asking: AskPassBridge.shared.isAsking(environment: self.askPassEnv))
            guard guess else {
                self.watchForMissingMarker(started)          // still busy (a slow profile, a prompt): look again
                return
            }
            self.markerResolved = true
            self.guessedPlain = true
            self.guessedUntil = Date().addingTimeInterval(120)
            self.onlineBeforeGuess = self.wasOnline
            self.handleMarker(.plain)
        }
    }

    /// A restricted shell's refusal of the start-up script (`rbash: /dev/null: restricted: cannot
    /// redirect output`, `rbash: exec: restricted`).
    nonisolated static func isRestrictedShell(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains(": restricted") && (lower.contains("redirect") || lower.contains("exec") || lower.contains("cd:")
                                                  || lower.contains("cannot specify") || lower.contains("cannot modify"))
    }

    /// Whether a terminal whose bootstrap has not answered is taken as a plain session now: only when
    /// this attempt's ssh showed something, then nothing for 5 s, and nothing asks for a password.
    nonisolated static func shouldGuessPlain(reattachingPersistent: Bool, receivedThisAttempt: Bool,
                                             quietFor: TimeInterval, promptShown: Bool, asking: Bool) -> Bool {
        !reattachingPersistent && receivedThisAttempt && quietFor >= 5 && !promptShown && !asking
    }

    /// The server printed text before Tether's start-up check answered, then went quiet: it most
    /// likely waits for something typed in the terminal — a question or notice to accept at login,
    /// a forced password change, a menu or program the server runs instead of a shell. The terminal
    /// is then shown instead of the connection card (which would hide the question).
    public private(set) var serverWaitsInTerminal = false
    @ObservationIgnored private var serverWaitCheck = 0

    private func watchForServerWaiting() {
        serverWaitCheck += 1
        let check = serverWaitCheck
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, check == self.serverWaitCheck, !self.markerResolved, !self.phase.isDead,
                  Date().timeIntervalSince(self.lastReceivedAt) >= 1.9 else { return }
            if !self.serverWaitsInTerminal { self.serverWaitsInTerminal = true }
        }
    }

    /// Forgets what an earlier ssh process of this tab received.
    private func resetAttempt() {
        serverWaitsInTerminal = false
        serverWaitCheck += 1
        receivedThisAttempt = false
        guessedPlain = false
        restoredBytes = 0
        restoreShownAt = .distantPast
    }

    /// A login without Tether's bootstrap: PowerShell on Windows, or — for a network device or
    /// limited shell — the device's own command line, exactly as `ssh host` gives it. Neither can be
    /// kept running by tmux or screen.
    private func startPlainLogin(attachOnly: Bool, options: SSHOptions, windows: Bool) {
        resetAttempt()
        if attachOnly {
            if windows {
                progress?.failure = "Windows sessions end when the connection drops."
                progress?.hint = "Windows has no tmux or screen to keep the shell running. Open a new session to continue."
            } else {
                progress?.failure = "Sessions on this device end when the connection drops."
                progress?.hint = "A network device or limited shell has no tmux or screen to keep it running. Open a new session to continue."
            }
            intentionalStop = true
            finish(reason: windows ? "The Windows shell ended with the connection" : "The device's session ended with the connection",
                   archive: wasOnline)
            return
        }
        var command: String?
        if windows {
            let shell = WindowsShell(platform: platform, directory: descriptor.initialDirectory)
            windowsShellTag = shell.tag
            command = shell.command
        }
        let args = options.interactiveArguments(target: descriptor.target, remoteCommand: command)
        AskPassBridge.shared.revoke(environment: askPassEnv)
        askPassEnv = AskPassBridge.shared.environment(targetKey: descriptor.target.key, purpose: "terminal", mode: "prefer", sessionID: id)
        bindOwnSignIn(options)
        var env = ChildEnvironment.base
        env["TERM"] = "xterm-256color"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        for (k, v) in askPassEnv { env[k] = v }
        let bridge = ProcessBridge(owner: self)
        self.bridge = bridge
        let process = LocalProcess(delegate: bridge, dispatchQueue: .main)
        bridge.process = process
        self.process = process
        process.startProcess(executable: options.sshBinary, args: args,
                             environment: env.map { "\($0.key)=\($0.value)" }, execName: "ssh")
        AskPassBridge.shared.bindToken(askPassEnv, pid: process.shellPid)
        if options.usesSharedConnection { watchForSilentStart(process) }
        markerResolved = true
        progress?.detail = windows ? "Starting PowerShell" : "Opening the device's command line"
        handleMarker(.plain)
    }

    /// Cancels a connection attempt in progress.
    public func cancelConnecting() {
        connectTask?.cancel()
        close(killRemote: false)
    }

    @ObservationIgnored private var connectTask: Task<Void, Never>?
    /// The shared connection is being prepared for this tab (its terminal starts after that).
    @ObservationIgnored private var connectingAttempt: UUID?
    private var connecting: Bool { connectingAttempt != nil }

    @ObservationIgnored private var pendingAttachOnly = false
    @ObservationIgnored private var restoredFromDisk = false

    // MARK: Process callbacks

    @ObservationIgnored private var lastReceivedAt = Date()
    /// The same in system uptime (sleep does not count), for stall detection.
    @ObservationIgnored private var lastReceivedUptime = ProcessInfo.processInfo.systemUptime

    /// Whether `p` is the process the tab runs now.
    fileprivate func isCurrent(_ p: LocalProcess?) -> Bool { p != nil && p === process }

    fileprivate func processOutput(_ slice: ArraySlice<UInt8>) {
        lastReceivedAt = Date()
        lastReceivedUptime = ProcessInfo.processInfo.systemUptime
        receivedThisAttempt = true
        if progress?.step == .restore { noteRestored(slice.count) }
        if guessedPlain, Date() > guessedUntil { guessedPlain = false; markerBuffer = [] }
        if !markerResolved || guessedPlain {
            markerBuffer.append(contentsOf: slice)
            if let found = RemoteBootstrap.extractMarker(from: markerBuffer) {
                markerResolved = true
                markerBuffer = []
                if guessedPlain {
                    // The server answered after all (slowly): it was not a plain session.
                    guessedPlain = false
                    wasOnline = onlineBeforeGuess
                }
                shellPid = found.fields["pid"].flatMap(Int.init)
                display(found.before)
                handleMarker(found.marker)
                if !found.after.isEmpty { routeOutput(found.after[...]) }
            } else {
                let hold = RemoteBootstrap.pendingPrefixLength(markerBuffer)
                let emit = Array(markerBuffer.dropLast(hold))
                markerBuffer = Array(markerBuffer.suffix(hold))
                if !markerResolved {
                    rememberStderr(emit)
                    if emit.contains(where: { $0 > 0x20 && $0 < 0x7f }) { watchForServerWaiting() }
                }
                display(emit)
            }
            return
        }
        routeOutput(slice)
    }

    /// Shows how much of the screen and history has arrived, at most twice a second.
    private func noteRestored(_ count: Int) {
        restoredBytes += count
        guard restoredBytes >= 64 << 10, Date().timeIntervalSince(restoreShownAt) >= 0.5 else { return }
        restoreShownAt = Date()
        let amount = ByteCountFormatter.string(fromByteCount: Int64(restoredBytes), countStyle: .file)
        progress?.detail = "Restoring screen and history — \(amount) received"
    }

    private func routeOutput(_ slice: ArraySlice<UInt8>) {
        if let tmux { tmux.receive(slice) } else { display(Array(slice)) }
    }

    private func handleMarker(_ marker: RemoteBootstrap.Marker) {
        serverWaitsInTerminal = false
        switch marker {
        case .tmux:
            progress?.detail = pendingAttachOnly ? "Re-attaching to the tmux session" : "Starting tmux (control mode)"
            if progress?.includesRestore == true { progress?.step = .restore; progress?.detail = "Restoring screen and history" }
        case .screen:
            progress?.detail = "Attaching GNU screen"
        case .plain:
            progress?.detail = "Starting the shell (no tmux or screen on the server)"
        default: break
        }
        switch marker {
        case .unreachable(let why):
            // The session is not taken for ended (the tab stays, and comes back after a relaunch):
            // the tab waits for the user, with why.
            unreachableReason = why
            ConnectionLog.shared.notice("Could not ask about the session; not treating it as ended", .tab,
                                        host: descriptor.target.key, tab: logTab, detail: why)
        case .gone:
            remoteSessionGone = true
            progress?.failure = "The session no longer exists on the server."
            progress?.hint = "It was ended there (or the server restarted). Open a new session to continue."
            intentionalStop = true
            finish(reason: "The remote session no longer exists", archive: true)
        case .plain:
            persistence = .plain
            becameOnline()
        case .screen:
            persistence = .screen
            becameOnline()
        case .tmux(let version):
            persistence = .tmux
            let driver = TmuxDriver(version: version, isReattach: pendingAttachOnly || wasOnline,
                                    terminalIsEmpty: !fedAnything, historyLines: configurationProvider().historyLinesOnReattach,
                                    ownSession: descriptor.remoteSessionName.hasPrefix("tether-"))
            driver.write = { [weak self] text in self?.process?.send(data: Array(text.utf8)[...]) }
            driver.display = { [weak self] bytes in self?.display(bytes) }
            driver.refresh = { [weak self] bytes in self?.sink?.feed(bytes[...]) }
            driver.size = { [weak self] in self?.realSize }
            driver.screenTail = { [weak self] in
                guard let sink = self?.sink else { return nil }
                return sink.screenTail(maxRows: 12).map {
                    HistoryCatchUp.Anchor(lines: $0.lines, lastRow: $0.lastRow, cursorRow: sink.screenCursorRow())
                }
            }
            driver.catchUpLimit = max(configurationProvider().serverHistoryLines, TmuxDriver.catchUpProbe)
            driver.onReady = { [weak self] in self?.becameOnline() }
            driver.willRedraw = { [weak self] in
                // Noted in the recording as well: shown again, it keeps that screen too.
                self?.sink?.screenWillBeRedrawn()
                self?.recorder?.append(ScrollbackRule.typedMarker)
            }
            driver.note = { [weak self] message in
                guard let self else { return }
                ConnectionLog.shared.info(message, .tab, host: self.descriptor.target.key, tab: self.logTab)
            }
            driver.onExit = { [weak self] reason in self?.tmuxExitReason = .some(reason) }
            driver.onActivity = { [weak self] command, path, rtt in
                guard let self else { return }
                if self.activity?.command != command || self.activity?.path != path {
                    self.activity = (command, path)
                }
                // When the question was asked: the shell was in front then (or later).
                self.shellSeenAt = Self.isShell(command) ? Date(timeIntervalSinceNow: -rtt) : nil
                if rtt > 0 { self.recordLatency(rtt) }
            }
            tmux = driver
        case .unknown:
            persistence = .plain
            becameOnline()
        }
    }

    private func becameOnline() {
        releaseGate()
        refusedOnThisSlot = 0
        // A login of this tab's own (without connection sharing) worked: what was typed for it may
        // be remembered (see `SharedConnections.onSignInResult`).
        if let token = askPassEnv["TETHER_ASKPASS_TOKEN"] { SharedConnections.onSignInResult?(token, true, false) }
        waitsForUser = false
        retryPausedReason = nil
        if !descriptor.target.isLocal { HostRetryClock.shared.reached(descriptor.target.key) }
        // Its shared connection can serve the host panel and background work now (without sharing,
        // background work would only fail to sign in again).
        if sshOptions(configurationProvider()).useControlMaster { BackgroundSignIn.shared.clear(descriptor.target.key) }
        if !wasOnline { onPersistenceKnown?(self) }
        progress = nil
        if wasOnline { recorder?.mark("Reconnected \(Date().formatted(date: .omitted, time: .standard))") }
        if let drop = lastDrop {
            lastDrop = nil
            recentRecovery = drop
            ConnectionLog.shared.notice("Tab reconnected after losing its connection", .tab, host: descriptor.target.key, tab: logTab, detail: drop.reason)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if self?.recentRecovery == drop { self?.recentRecovery = nil }
            }
        }
        if !descriptor.target.isLocal {
            let mode = switch persistence {
            case .tmux: pendingAttachOnly ? "tmux, re-attached" : "tmux"
            case .screen: "GNU screen"
            case .plain, .unknown: PlatformCache.shared.isDevice(descriptor.target.key) ? "plain login (device or limited shell)"
                : platform.isWindows ? "PowerShell" : "plain shell"
            }
            ConnectionLog.shared.info("Tab connected in " + SharedConnections.seconds(Date().timeIntervalSince(attemptBegan)) + " (\(mode))",
                                      .tab, host: descriptor.target.key, tab: logTab)
        }
        wasOnline = true
        attempt = 0
        lastError = nil
        phase = .online
        if let size = realSize { terminalDidResize(cols: size.cols, rows: size.rows) }
        deliverHeldInput()
        startActivityPolling()
        onOnline?(self)
    }

    /// SwiftTerm reports `waitpid`'s raw status on macOS: ssh's 255 (connection lost) arrives as
    /// 65280, and was taken for a shell that exited by itself — the tab ended instead of reconnecting.
    /// A process ended by a signal counts as lost too (255).
    nonisolated static func exitStatus(fromWaitStatus raw: Int32?) -> Int32? {
        guard let raw else { return nil }
        return raw & 0x7f == 0 ? (raw >> 8) & 0xff : 255
    }

    fileprivate func processTerminated(exitCode: Int32?) {
        process = nil
        releaseGate()
        // A login of this tab's own (no connection sharing) that never got online: told so, and
        // whether the server refused the password (then a remembered one is not sent again).
        if !phase.isOnline, let token = askPassEnv["TETHER_ASKPASS_TOKEN"] {
            SharedConnections.onSignInResult?(token, false, Self.isRefusedSignIn(stderrTail))
        }
        AskPassBridge.shared.revoke(environment: askPassEnv)
        askPassEnv = [:]
        if intentionalStop || phase.isDead { return }

        // tmux told us why it exited.
        if let reason = tmuxExitReason {
            let text = reason ?? ""
            if text.contains("detached") {
                finish(reason: "Detached from tmux", archive: true)
            } else if descriptor.target.isLocal {
                finish(reason: "Session ended", archive: true)
            } else {
                confirmTmuxEnded(reason: text)
            }
            return
        }

        // The session could not be asked about (`RemoteBootstrap.Marker.unreachable`): waiting for
        // the user, not retried on a timer (it would only fail the same way) and not ended.
        if let why = unreachableReason {
            unreachableReason = nil
            let where_ = descriptor.target.isLocal ? "this Mac" : "the server"
            let message = "Could not reach the session on \(where_) (\(why)). It may still be running: check tmux there, then press Reconnect."
            progress?.failure = "Could not reach the session"
            progress?.hint = message
            scheduleReconnect()
            pauseRetries(message)
            return
        }

        // A restricted shell (rbash and the like) answered the platform question like any shell, then
        // refused Tether's start-up script: the host is remembered as a limited shell and gets a
        // plain login, now (Host ▸ Edit ▸ Shell can change that).
        if !markerResolved, !descriptor.target.isLocal, Self.isRestrictedShell(stderrTail) {
            PlatformCache.shared.markDevice(descriptor.target.key)
            ConnectionLog.shared.notice("The account's shell is restricted; opening a plain login", .tab, host: descriptor.target.key, tab: logTab)
            display(Array("\r\n\u{1b}[2m[Tether] This account's shell is restricted: Tether runs nothing on this host and opens a plain login.\u{1b}[0m\r\n".utf8))
            startTerminal(attachOnly: false, options: sshOptions(configurationProvider()))
            return
        }

        // The shared connection was gone when this ssh started (it ended a moment before): the next
        // attempt checks it afresh and signs in once for the host if needed.
        // Only ssh's own exit (255) on a socket that really does not answer: the text alone could
        // come from the server, which must not be able to end the connection's silent channel.
        if exitCode == 255, sshOptions(configurationProvider()).useControlMaster, SharedConnections.isLostConnectionMessage(stderrTail) {
            let options = sshOptions(configurationProvider()), target = descriptor.target
            Task {
                guard let socket = await SharedConnections.shared.socket(for: target, options: options) else { return }
                if SharedConnections.isSocket(socket), case .alive = await SharedConnections.check(socket, ssh: options.sshBinary) { return }
                await SharedConnections.shared.forget(socket: socket)
            }
        }
        // The server limits sessions per shared connection (sshd MaxSessions): use another one.
        // A refusal right after many tabs reconnected at once is often brief (their old sessions are
        // still closing on the server): the same connection is tried once more before another one —
        // another sign-in — is opened.
        // A server that allows a single session per connection: the silent channel holding it gives
        // way first. Never more than a few further connections (each one a sign-in).
        if !phase.isOnline, Self.isSessionRefused(stderrTail), controlSlot < 8, sshOptions(configurationProvider()).useControlMaster {
            ConnectionLog.shared.notice(refusedOnThisSlot == 0 ? "The server refused another session; trying the same connection again"
                                        : "The server refused another session; opening another connection", .tab, host: descriptor.target.key, tab: logTab)
            if refusedOnThisSlot == 0 {
                refusedOnThisSlot += 1
                progress?.detail = "The server is busy closing earlier sessions — trying again"
                retryTask?.cancel()
                let target = descriptor.target, options = sshOptions(configurationProvider())
                retryTask = Task { [weak self] in
                    let yielded = await SharedConnections.shared.yieldSentinel(for: target, options: options)
                    try? await Task.sleep(for: .seconds(yielded ? 0.5 : 2))
                    guard let self, !Task.isCancelled, !self.intentionalStop, !self.phase.isDead else { return }
                    self.retryTask = nil
                    self.launch(attachOnly: self.pendingAttachOnly)
                }
                return
            }
            refusedOnThisSlot = 0
            controlSlot += 1
            progress?.detail = "The server limits sessions per connection — opening another shared connection"
            launch(attachOnly: pendingAttachOnly)
            return
        }
        let code = exitCode ?? 255
        // In a plain shell a non-255 code means the shell exited normally.
        if persistence == .plain && code != 255 && markerResolved {
            finishEnded("Shell exited (code \(code))", code: code)
            return
        }
        // Never got online and ssh failed: show why; retry only if it looks transient.
        for line in stderrTail.split(separator: "\n") {
            if let (problem, hint) = ConnectionProgress.diagnose(String(line)) { progress?.failure = problem; progress?.hint = hint }
        }
        // A changed host key never fixes itself: stop and let the user decide, even for a session
        // that was online before (the server may have been reinstalled — or the connection intercepted).
        if !wasOnline && !pendingAttachOnly || progress?.hostKeyChange != nil {
            let message = stderrTail.isEmpty ? "ssh exited with code \(code)" : stderrTail
            if Self.isPermanentFailure(message) || (attempt >= 2 && !ConnectionProgress.isUnreachable(message))
                || progress?.hostKeyChange != nil {
                endedByConnectionFailure = true
                noteIfUnreachable(message, why: message)
                finish(reason: message, archive: false)
                return
            }
        }
        lastError = stderrTail.isEmpty ? nil : stderrTail
        ConnectionLog.shared.info("Tab's ssh ended (code \(code)); reconnecting", .tab, host: descriptor.target.key, tab: logTab, detail: stderrTail)
        noteDrop(stderrTail.isEmpty ? (code == 255 ? "the connection to the server ended" : "ssh ended (code \(code))") : stderrTail)
        if Self.isRefusedSignIn(stderrTail) {
            retryPausedReason = "The server did not accept the sign-in. Check the password or key, then press Reconnect."
        }
        scheduleReconnect(unreachable: ConnectionProgress.isUnreachable(stderrTail))
    }

    /// tmux ended this client without saying "detached". It also does so while the session keeps
    /// running — a client too far behind on a slow link — so the server is asked before the tab is
    /// called ended: still there → reconnect and re-attach; no answer → reconnect too (the bootstrap
    /// then says whether the session is gone).
    private func confirmTmuxEnded(reason: String) {
        activityTask?.cancel()
        tmux = nil
        tmuxExitReason = nil
        let executor = RemoteExecutor(target: descriptor.target, options: sshOptions(configurationProvider()))
        let name = descriptor.remoteSessionName
        Task { [weak self] in
            let r = await executor.run(RemoteScript(#"tmux has-session -t "=$1" 2>/dev/null"#), arguments: [name],
                                       timeout: 10, purpose: "monitor")
            guard let self, !self.intentionalStop, !self.phase.isDead, self.process == nil, self.retryTask == nil else { return }
            if r.status == 1 && !r.timedOut {
                self.finishEnded("The tmux session ended on the server", code: nil)
            } else {
                self.connectionLost(reason.isEmpty ? "tmux closed the connection" : "tmux closed the connection (\(reason))")
            }
        }
    }

    /// A tab that gives up still tells the server's other tabs that it could not reach it: those
    /// queued behind its attempt then do not try again one after another.
    private func noteIfUnreachable(_ text: String, why: String) {
        guard !descriptor.target.isLocal, ConnectionProgress.isUnreachable(text) else { return }
        let config = configurationProvider()
        _ = HostRetryClock.shared.next(for: descriptor.target.key, base: config.reconnectBaseDelay,
                                       longest: config.reconnectMaxDelay, why: why)
    }

    /// Another tab's attempt to this server failed while this one waited for its turn (see
    /// `HostRetryClock.failedSince`): treated as this tab's own failed attempt, without trying.
    private func sharedServerFailure(_ why: String?) {
        let message = why ?? "\(descriptor.target.displayName) did not answer"
        lastError = message
        ConnectionLog.shared.info("Tab did not try: the server just failed another tab's attempt", .tab,
                                  host: descriptor.target.key, tab: logTab, detail: message)
        scheduleReconnect(unreachable: true)
    }

    /// `unreachable`: the attempt failed because the server could not be reached
    /// (`ConnectionProgress.isUnreachable`). Only such failures plan the server's shared rounds
    /// (`HostRetryClock`): a refused password or a cancelled question is this tab's own matter, and
    /// the server's other tabs go on with their own sign-ins.
    private func scheduleReconnect(unreachable: Bool = false) {
        let config = configurationProvider()
        attempt += 1
        if attempt == 1 { showLostNotice() }
        let host = descriptor.target.key
        let clock = descriptor.target.isLocal ? nil : HostRetryClock.shared
        let pending = clock?.failedSince(.distantPast, host: host)
        // Noted first, whatever this tab does next (also with reconnecting off): tabs queued behind
        // this attempt learn that the server did not answer.
        let round = unreachable ? clock?.next(for: host, base: config.reconnectBaseDelay, longest: config.reconnectMaxDelay, why: lastError) : nil
        guard config.autoReconnect, config.maxReconnectAttempts == 0 || attempt <= config.maxReconnectAttempts else {
            ConnectionLog.shared.notice(config.autoReconnect ? "Tab stopped trying after \(attempt - 1) tries; Reconnect starts again"
                                        : "Tab waits for Reconnect (reconnecting on its own is off)", .tab, host: descriptor.target.key, tab: logTab)
            phase = .waiting(attempt: attempt, nextRetry: nil)
            return
        }
        if waitsForUser {
            ConnectionLog.shared.notice("Tab waits for you to sign in", .tab, host: descriptor.target.key, tab: logTab)
            phase = .waiting(attempt: attempt, nextRetry: nil)
            progress = nil
            lastError = "Needs your password — click the tab to sign in"
            return
        }
        if let reason = retryPausedReason {
            ConnectionLog.shared.notice("Tab stopped trying", .tab, host: descriptor.target.key, tab: logTab, detail: reason)
            phase = .waiting(attempt: attempt, nextRetry: nil)
            progress = nil
            lastError = reason
            return
        }
        // A tab that was working and just lost its connection tries again at once (through the shared
        // connection, if that survived) — unless the server already failed another tab just now.
        // Later attempts back off, together with the server's other tabs (`HostRetryClock`).
        let at: Date, planned: Bool
        if attempt == 1, wasOnline, pending == nil {
            (at, planned) = (Date().addingTimeInterval(0.3), true)
        } else if let round {
            (at, planned) = round
        } else if let pending {
            (at, planned) = (pending.at, false)
        } else {
            let delay = min(config.reconnectBaseDelay * pow(2, Double(min(attempt - 1, 8))), config.reconnectMaxDelay)
            (at, planned) = (Date().addingTimeInterval(delay), true)
        }
        let delay = max(at.timeIntervalSinceNow, 0)
        phase = .waiting(attempt: attempt, nextRetry: at)
        if delay >= 1 {
            ConnectionLog.shared.info((planned ? "Tab tries again in " : "Tab tries again with the server's other tabs in ")
                                      + SharedConnections.seconds(delay) + " (try \(attempt + 1))", .tab, host: host, tab: logTab)
        }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard let self, !self.waitsForUser else { return }
            self.retryTask = nil
            self.launch(attachOnly: self.wasOnline || self.restoredFromDisk)
        }
    }

    private func finish(reason: String, archive: Bool) {
        releaseGate()
        discardHeldInput()
        guard !phase.isDead else { return }
        retryTask?.cancel()
        ConnectionLog.shared.info("Tab ended", .tab, host: descriptor.target.key, tab: logTab, detail: reason)
        phase = .dead(reason: reason)
        endedAt = Date()
        let sentence = reason.hasSuffix(".") ? reason : reason + "."
        let notice = "\r\n\u{1b}[2m[Tether] \(sentence) This session is now read-only.\u{1b}[0m\r\n"
        display(Array(notice.utf8))
        recorder?.close()
        // A recording continued from an earlier run holds that run's output: it is kept in the
        // archive even when this run never got online.
        if archive || continuedRecording { onDeath?(self) }
        onEnded?(self)
    }

    /// Every 2 s while online: asks tmux what is running (tab titles) and measures latency.
    /// If the server stops answering for `stallTimeout` seconds of awake time, the tab re-attaches
    /// (through the shared connection, so nobody signs in) and the connection itself is checked
    /// (`onStall`). Not while the network is away or the Mac sleeps (`connectivityHeld`): plain ssh
    /// waits too, and the connection often survives.
    private func startActivityPolling() {
        activityTask?.cancel()
        let timeout = configurationProvider().stallTimeout
        activityTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase.isOnline else { return }
                if let tmux = self.tmux {
                    // Lost only when the question went unanswered *and* nothing at all arrived:
                    // a connection busy with other tabs' output is slow, not dead.
                    let now = ProcessInfo.processInfo.systemUptime
                    if self.connectivityHeld {
                        // Nothing is judged meanwhile: the clock starts again when it is back.
                        self.lastReceivedUptime = max(self.lastReceivedUptime, now - 1)
                    } else if let sent = tmux.activitySentAt, now - sent > timeout, now - self.lastReceivedUptime > timeout,
                              now - self.heldUntil > timeout {
                        ConnectionLog.shared.notice("The server stopped answering a tab", .tab, host: self.descriptor.target.key, tab: self.logTab)
                        self.onStall?(self)
                        self.connectionLost("The server stopped responding")
                        return
                    }
                    tmux.requestActivity()
                } else {
                    await self.measureLatencyOutOfBand()
                }
                // A tab not on screen asks half as often (its marks may lag a little); still well
                // within the stall timeout, so a dead connection is noticed as before.
                let interval: Double = self.tmux == nil ? 10 : (self.isOnScreen ? 2 : min(4, max(2, timeout * 0.66)))
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// Without tmux there is no side channel in the session; time a no-op over the shared connection.
    private func measureLatencyOutOfBand() async {
        // An extra ssh command per session adds up with many tabs; only the one on screen measures.
        guard !descriptor.target.isLocal, isOnScreen else { return }
        let config = configurationProvider()
        guard sshOptions(config).useControlMaster else { return }
        let executor = RemoteExecutor(target: descriptor.target, options: sshOptions(config))
        let start = Date()
        let r = await executor.run(RemoteScript(":", windows: "exit 0"), timeout: 10, purpose: "latency")
        if r.succeeded { recordLatency(Date().timeIntervalSince(start)) }
    }

    /// The network went away (Wi-Fi off, sleep). Persistent sessions are dropped immediately and
    /// re-attached when the network returns; plain shells are left alone because they cannot be
    /// re-attached and a short outage may not kill their TCP connection.
    public func networkBecameUnavailable() {
        guard phase.isOnline, !descriptor.target.isLocal, persistence == .tmux || persistence == .screen else { return }
        connectionLost("Network unavailable", waitForNetwork: true)
    }

    /// The Mac is about to sleep: a tmux/screen tab lets go of its server session (which keeps
    /// running), so nothing is sent to a Mac that cannot answer — a server whose data goes
    /// unacknowledged gives up on the whole connection after some minutes. The tab re-attaches
    /// after waking, through the shared connection, which stays signed in.
    public func prepareForSleep() {
        recorder?.flush()       // the Mac may not wake
        guard phase.isOnline, !descriptor.target.isLocal, persistence == .tmux || persistence == .screen else { return }
        connectionLost("Paused while the Mac sleeps", waitForNetwork: true)
    }

    /// Drops the current connection and enters the waiting state.
    private func connectionLost(_ reason: String, waitForNetwork: Bool = false) {
        ConnectionLog.shared.info("Tab let go of its connection: " + reason, .tab, host: descriptor.target.key, tab: logTab)
        if reason != "Paused while the Mac sleeps" { noteDrop(reason) }
        activityTask?.cancel()
        intentionalStop = true
        process?.terminate()
        process = nil
        tmux = nil
        AskPassBridge.shared.revoke(environment: askPassEnv)
        intentionalStop = false
        lastError = reason
        latencyStore.markLost()
        latency = latencyStore
        if waitForNetwork {
            attempt += 1
            if attempt == 1 { showLostNotice() }
            phase = .waiting(attempt: attempt, nextRetry: nil)
        } else {
            scheduleReconnect()
        }
    }

    private func recordLatency(_ rtt: TimeInterval) {
        latencyStore.record(rtt)
        func bucket(_ s: LatencyStats) -> Int { Int(((s.median ?? 0) * 100).rounded()) }
        let changed = bucket(latencyStore) != bucket(latency) || latencyStore.quality != latency.quality
        if changed || Date().timeIntervalSince(latencyPublishedAt) > 30 {
            latency = latencyStore
            latencyPublishedAt = Date()
        }
    }

    private func showLostNotice() {
        guard wasOnline else { return }
        recorder?.mark("Connection lost \(Date().formatted(date: .omitted, time: .standard))")
        recorder?.flush()       // what is only in memory goes to disk now (Tether may not last)
        // tmux: the banner above the terminal says it; the screen stays exactly as tmux left it, so
        // what the server prints meanwhile can be added seamlessly on reconnect (HistoryCatchUp).
        guard persistence != .tmux else { return }
        // A plain shell cannot be reattached: say so, so nobody waits for a command that has ended.
        let notice = persistence == .plain
            ? "\r\n\u{1b}[2m[Tether] Connection lost. This server keeps no shell running for Tether (no tmux or screen), so the shell and what ran in it have ended; reconnecting starts a new one. The output above is kept.\u{1b}[0m\r\n"
            : "\r\n\u{1b}[2m[Tether] Connection lost. History is kept; input is paused until the session is back.\u{1b}[0m\r\n"
        display(Array(notice.utf8))
    }

    private func display(_ raw: [UInt8]) {
        let (bytes, title) = titleFilter.filter(passthrough.filter(raw))
        if let title, title != remoteTitle { remoteTitle = title }
        guard !bytes.isEmpty else { return }
        fedAnything = true
        sink?.feed(bytes[...])
        noteOutput()
        if let recorder {
            // The recording notes the terminal's size before output laid out for it, so replays
            // and the recording's text lay it out the same way (`SizeMarker`, invisible).
            // It is noted again every megabyte, so any piece of the recording says it.
            // Only between escape sequences: a marker inside one would split it (and hide a clear).
            if let size = realSize, !recordedEscapes.isInside, recordedSize?.recording != recorder.url || recordedSize?.cols != size.cols
                || recordedSize?.rows != size.rows || bytesSinceSizeMarker >= 1 << 20 {
                recorder.append(SizeMarker.bytes(cols: size.cols, rows: size.rows))
                recordedSize = (recorder.url, size.cols, size.rows)
                bytesSinceSizeMarker = 0
            }
            recorder.append(bytes)
            recordedEscapes.feed(bytes)
            bytesSinceSizeMarker += bytes.count
        }
        if detectPrompts {
            let prompt = promptDetector.feed(bytes)
            if prompt != passwordPrompt {
                passwordPrompt = prompt
                if let prompt { onPasswordPrompt?(self, prompt) }
            }
        }
    }

    private func rememberStderr(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let text = String(decoding: bytes, as: UTF8.self)
        let lines = (stderrTail + text).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        stderrTail = lines.suffix(2).joined(separator: "\n")
        // Before the session is up, ssh's messages (e.g. a host key warning) go to the details log too.
        if !phase.isOnline {
            for line in text.split(whereSeparator: \.isNewline) { progress?.append(String(line)) }
        }
    }

    public nonisolated static func isSessionRefused(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("session open refused") || m.contains("administratively prohibited")
            || m.contains("session request failed")
    }

    static func isPermanentFailure(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("permission denied") || m.contains("could not resolve hostname")
            || m.contains("host key verification failed") || m.contains("no such file")
            || m.contains("bad configuration") || m.contains("too many authentication failures")
    }

    /// The terminal's size once its view has really been laid out (nil before).
    private var realSize: (cols: Int, rows: Int)? {
        guard let sink, sink.hasRealSize else { return nil }
        return sink.cellSize
    }

    fileprivate var windowSize: winsize {
        let s: (cols: Int, rows: Int) = sink?.cellSize ?? (80, 24)
        return winsize(ws_row: UInt16(max(s.rows, 1)), ws_col: UInt16(max(s.cols, 1)), ws_xpixel: 0, ws_ypixel: 0)
    }
}

/// Non-isolated adapter between SwiftTerm's `LocalProcessDelegate` and the main-actor session.
/// The process is created with `dispatchQueue: .main`, so callbacks already run on the main thread.
final class ProcessBridge: LocalProcessDelegate {
    weak var owner: TerminalSession?
    /// The process this bridge belongs to: what a process the tab already let go of still sends
    /// (tmux's `%exit` as it detaches, ssh's last words) is not shown in the terminal.
    weak var process: LocalProcess?
    init(owner: TerminalSession) { self.owner = owner }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        let code = TerminalSession.exitStatus(fromWaitStatus: exitCode)
        MainActor.assumeIsolated {
            // A process the tab already let go of (and replaced) ending later changes nothing.
            guard let owner, owner.isCurrent(source) else { return }
            owner.processTerminated(exitCode: code)
        }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        MainActor.assumeIsolated {
            guard let owner, owner.isCurrent(process) else { return }
            owner.processOutput(slice)
        }
    }

    func getWindowSize() -> winsize {
        MainActor.assumeIsolated { owner?.windowSize ?? winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0) }
    }
}

/// A process in a terminal's foreground (see `TerminalSession.foregroundProcess`).
public struct ForegroundProcess: Equatable, Sendable {
    /// Program name, e.g. "sudo".
    public var command: String
    /// The real user who started it (for sudo and su: the one who typed the command).
    public var user: String
    /// Its arguments, without the program itself.
    public var arguments: [String]

    /// For `su`: the account whose password it asks for (`su - bob` → bob, plain `su` → root).
    public var suTarget: String {
        var skipNext = false
        for a in arguments {
            if skipNext { skipNext = false; continue }
            if ["-c", "--command", "-s", "--shell", "-g", "--group", "-G", "--supp-group", "-w", "--whitelist-environment"].contains(a) { skipNext = true; continue }
            if a.hasPrefix("-") { continue }
            return a
        }
        return "root"
    }

    /// Picks the foreground process (`+` in its state) running `command` from `ps -o stat=,ruser=,args=`.
    public static func parse(ps output: String, command: String) -> ForegroundProcess? {
        var fallback: ForegroundProcess?
        for line in output.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
            guard f.count == 3, f[0].contains("+") else { continue }
            let words = f[2].split(separator: " ").map(String.init)
            guard let first = words.first else { continue }
            let name = (first as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let p = ForegroundProcess(command: name, user: f[1], arguments: Array(words.dropFirst()))
            if name == command { return p }
            fallback = p
        }
        return fallback.map { ForegroundProcess(command: command, user: $0.user, arguments: []) }
    }
}

