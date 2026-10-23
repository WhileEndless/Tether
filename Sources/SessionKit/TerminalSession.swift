import AppKit
import Observation
import SwiftTerm
import TetherCore
import SSHTransport
import RecordingKit

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
    public private(set) var phase: SessionPhase = .connecting
    public private(set) var persistence: ActivePersistence = .unknown
    /// Title reported by the remote program (OSC 0/2 or a screen/tmux name sequence).
    public var remoteTitle: String = ""
    /// What is running in the session (tmux only): foreground command and working directory.
    public private(set) var activity: (command: String, path: String)?
    /// Step-by-step progress while connecting or re-attaching (nil once online).
    public private(set) var progress: ConnectionProgress?
    /// A password prompt currently waiting in the terminal (sudo, su, ssh, …), if any.
    public private(set) var passwordPrompt: PasswordPrompt?
    @ObservationIgnored private var promptDetector = PasswordPromptDetector()
    /// Set by the app while this session's terminal is the visible tab of a window.
    @ObservationIgnored public var isOnScreen = false
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
        await ConnectionGate.shared.acquire(key)
        holdingGate = key
        if Task.isCancelled || intentionalStop { releaseGate(); return false }
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

    /// Called whenever the session ends, archived or not.
    @ObservationIgnored public var onEnded: ((TerminalSession) -> Void)?
    /// Called when the session becomes dead (to archive it).
    @ObservationIgnored public var onDeath: ((TerminalSession) -> Void)?
    /// Called when the negotiated persistence backend becomes known, so the session can be
    /// saved immediately and re-attached even if the app is killed.
    @ObservationIgnored public var onPersistenceKnown: ((TerminalSession) -> Void)?
    /// Called every time the session comes online (first connect and every reconnect).
    @ObservationIgnored public var onOnline: ((TerminalSession) -> Void)?
    /// Called when ssh needs a configuration refresh before reconnecting.
    @ObservationIgnored public var configurationProvider: () -> SessionConfiguration

    @ObservationIgnored public private(set) var sink: TerminalSink?
    @ObservationIgnored private var process: LocalProcess?
    @ObservationIgnored private var bridge: ProcessBridge?
    @ObservationIgnored private var tmux: TmuxDriver?
    @ObservationIgnored private var markerBuffer: [UInt8] = []
    @ObservationIgnored private var markerResolved = false
    @ObservationIgnored private var recorder: SessionRecorder?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
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

    public static let shells: Set<String> = ["bash", "zsh", "sh", "fish", "dash", "ksh", "tcsh", "csh", "-bash", "-zsh", "-sh"]

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

    private func tmuxQuery(_ format: String) async -> String? {
        guard let tmux else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { @MainActor in await tmux.query(format) }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            if first == nil { tmux.answerForegroundQueries(nil) }
            return first
        }
    }

    /// Tab title: a custom name if the user set one, otherwise derived from what is running.
    public var displayTitle: String {
        if descriptor.customTitle { return descriptor.title }
        let host = descriptor.target.displayName
        if let activity, !activity.command.isEmpty {
            if Self.shells.contains(activity.command) {
                let dir = (activity.path as NSString).lastPathComponent
                return dir.isEmpty ? host : "\(host): \(Self.abbreviate(activity.path, dir))"
            }
            return "\(activity.command) — \(host)"
        }
        let t = remoteTitle.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? host : t
    }

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

    /// Nothing worth keeping: no command was run here, nothing is running in it, and it was not
    /// re-attached to an existing session (which may hold earlier work). Closing it needs no question.
    public var isUnused: Bool {
        if hasRunCommands || restoredFromDisk || openedForAttach { return false }
        if let command = activity?.command, !command.isEmpty, !Self.shells.contains(command) { return false }
        return true
    }

    public func send(_ bytes: ArraySlice<UInt8>) {
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
        case .waiting, .suspended, .dead:
            NSSound.beep()
        }
    }

    public func terminalDidResize(cols: Int, rows: Int) {
        guard let process, process.running else { return }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
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
    public func reconnectNow() {
        guard case .waiting = phase else { return }
        retryTask?.cancel()
        retryTask = nil
        Task {
            // A half-dead multiplex master would make the new connection hang; drop it first.
            let executor = RemoteExecutor(target: descriptor.target, options: sshOptions(configurationProvider()))
            if !(await executor.isMasterAlive()) { await executor.closeMaster() }
            launch(attachOnly: wasOnline || restoredFromDisk)
        }
    }

    /// Ends the session. For tmux/screen, `killRemote` decides whether the remote session
    /// keeps running (detach) or is terminated.
    public func close(killRemote: Bool) {
        intentionalStop = true
        connectTask?.cancel()
        connector?.cancel()
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
        connector?.cancel()
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
        detectPrompts = config.detectPasswordPrompts
        intentionalStop = false
        markerBuffer = []
        markerResolved = false
        tmux = nil
        tmuxExitReason = nil
        stderrTail = ""
        if !wasOnline && !attachOnly { phase = .connecting }
        pendingAttachOnly = attachOnly

        if recorder == nil, config.recordingEnabled {
            recorder = SessionRecorder(targetKey: descriptor.target.key, sessionID: id)
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
            if target.isLocal { startTerminal(attachOnly: attachOnly); return }
            // Without a shared connection every tab is its own login: start them one at a time
            // (the gate is released once this one is online or has failed).
            connectTask = Task { [weak self] in
                guard let self, await self.waitForGate(target.key) else { return }
                self.startTerminal(attachOnly: attachOnly)
            }
            return
        }
        connectTask = Task { [weak self] in
            guard let self else { return }
            // One login at a time per host; the others reuse the shared connection right after.
            guard await self.waitForGate(target.key) else { return }
            let executor = RemoteExecutor(target: target, options: self.sshOptions(config))
            if await executor.isMasterAlive() {
                self.progress?.detail = "Using the existing connection"
            } else {
                let env = AskPassBridge.shared.environment(targetKey: target.key, purpose: "connect", mode: "force")
                let connector = MasterConnector()
                self.connector = connector
                let error = await connector.connect(target: target, options: sshOptions(config), environment: env) { [weak self] line in
                    self?.progress?.ingest(line)
                }
                AskPassBridge.shared.revoke(environment: env)
                self.connector = nil
                guard !Task.isCancelled, !self.intentionalStop else { self.releaseGate(); return }
                if let error {
                    self.releaseGate()
                    self.connectionFailed(error)
                    return
                }
            }
            self.releaseGate()
            guard !Task.isCancelled, !self.intentionalStop else { return }
            self.progress?.detail = "Checking the server's shell"
            self.platform = await executor.resolvedPlatform()
            guard !Task.isCancelled, !self.intentionalStop else { return }
            self.startTerminal(attachOnly: attachOnly)
        }
    }

    /// True when the session ended because it could not connect (not because the remote shell ended).
    public private(set) var endedByConnectionFailure = false

    /// Tries the same session again after it gave up connecting. Re-attaches to its tmux/screen
    /// session if it had one, instead of starting a new session.
    public func retryAfterFailure() {
        guard phase.isDead, endedByConnectionFailure else { return }
        endedByConnectionFailure = false
        endedAt = nil
        recorder = nil      // the old one was closed; a new recording starts
        attempt = 0
        lastError = nil
        phase = wasOnline || restoredFromDisk ? .waiting(attempt: 0, nextRetry: nil) : .connecting
        launch(attachOnly: wasOnline || restoredFromDisk)
    }

    /// Opening the shared connection failed: show why, then retry or give up.
    private func connectionFailed(_ fallback: String) {
        if progress?.failure == nil { progress?.failure = "Could not connect (\(fallback))." }
        let message = progress?.failure ?? fallback
        lastError = message
        let permanent = progress.map { p in p.log.contains { Self.isPermanentFailure($0) } } ?? false
        if (!wasOnline && !pendingAttachOnly && (permanent || attempt >= 2)) || progress?.hostKeyChange != nil {
            endedByConnectionFailure = true
            finish(reason: message, archive: false)
            return
        }
        scheduleReconnect()
    }

    /// Runs the terminal process: ssh (attaching to the shared connection) with the bootstrap command.
    private func startTerminal(attachOnly: Bool) {
        let config = configurationProvider()
        progress?.step = .startSession
        progress?.detail = descriptor.target.isLocal ? "Starting a local shell" : "Starting the session on the server"

        if platform.isWindows {
            startWindowsTerminal(attachOnly: attachOnly, config: config)
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
        let executable = local ? "/bin/sh" : sshOptions(config).sshBinary
        let args = local ? ["-c", remote] : sshOptions(config).interactiveArguments(target: descriptor.target, remoteCommand: remote)

        AskPassBridge.shared.revoke(environment: askPassEnv)
        // "prefer" makes password prompts appear as a native sheet (with keychain support),
        // which also works while input is blocked during a reconnect. Never for local shells: every
        // program started there could use the token to ask Tether for saved secrets.
        askPassEnv = local ? [:] : AskPassBridge.shared.environment(targetKey: descriptor.target.key, purpose: "terminal", mode: "prefer")

        var env = ProcessInfo.processInfo.environment
        for key in ["SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "TETHER_ASKPASS_SOCKET", "TETHER_ASKPASS_TOKEN"] { env[key] = nil }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Tether"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        for (k, v) in askPassEnv { env[k] = v }

        let bridge = ProcessBridge(owner: self)
        self.bridge = bridge
        let process = LocalProcess(delegate: bridge, dispatchQueue: .main)
        self.process = process
        if local { env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin") }
        // A Finder-launched app runs in "/": local shells start in the home folder like Terminal.app.
        process.startProcess(executable: executable, args: args,
                             environment: env.map { "\($0.key)=\($0.value)" }, execName: local ? "sh" : "ssh",
                             currentDirectory: local ? (descriptor.initialDirectory ?? NSHomeDirectory()) : nil)
        AskPassBridge.shared.bindToken(askPassEnv, pid: process.shellPid)
    }

    /// Windows hosts: an interactive PowerShell over ssh. There is no tmux or screen on Windows,
    /// so the shell ends with the connection (like a plain shell on other systems).
    private func startWindowsTerminal(attachOnly: Bool, config: SessionConfiguration) {
        if attachOnly {
            progress?.failure = "Windows sessions end when the connection drops."
            progress?.hint = "Windows has no tmux or screen to keep the shell running. Open a new session to continue."
            intentionalStop = true
            finish(reason: "The Windows shell ended with the connection", archive: wasOnline)
            return
        }
        var command: String?
        if let dir = descriptor.initialDirectory, !dir.isEmpty {
            let quoted = "'" + dir.replacingOccurrences(of: "'", with: "''") + "'"
            command = "powershell -NoLogo -NoExit -Command \"Set-Location -LiteralPath \(quoted)\""
        } else if platform == .windowsCmd {
            command = "powershell -NoLogo"
        }
        let args = sshOptions(config).interactiveArguments(target: descriptor.target, remoteCommand: command)
        AskPassBridge.shared.revoke(environment: askPassEnv)
        askPassEnv = AskPassBridge.shared.environment(targetKey: descriptor.target.key, purpose: "terminal", mode: "prefer")
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        for (k, v) in askPassEnv { env[k] = v }
        let bridge = ProcessBridge(owner: self)
        self.bridge = bridge
        let process = LocalProcess(delegate: bridge, dispatchQueue: .main)
        self.process = process
        process.startProcess(executable: sshOptions(config).sshBinary, args: args,
                             environment: env.map { "\($0.key)=\($0.value)" }, execName: "ssh")
        AskPassBridge.shared.bindToken(askPassEnv, pid: process.shellPid)
        markerResolved = true
        progress?.detail = "Starting PowerShell"
        handleMarker(.plain)
    }

    /// Cancels a connection attempt in progress.
    public func cancelConnecting() {
        connector?.cancel()
        connectTask?.cancel()
        close(killRemote: false)
    }

    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var connector: MasterConnector?

    @ObservationIgnored private var pendingAttachOnly = false
    @ObservationIgnored private var restoredFromDisk = false

    // MARK: Process callbacks

    @ObservationIgnored private var lastReceivedAt = Date()

    fileprivate func processOutput(_ slice: ArraySlice<UInt8>) {
        lastReceivedAt = Date()
        if !markerResolved {
            markerBuffer.append(contentsOf: slice)
            if let found = RemoteBootstrap.extractMarker(from: markerBuffer) {
                markerResolved = true
                markerBuffer = []
                display(found.before)
                handleMarker(found.marker)
                if !found.after.isEmpty { routeOutput(found.after[...]) }
            } else {
                let hold = RemoteBootstrap.pendingPrefixLength(markerBuffer)
                let emit = Array(markerBuffer.dropLast(hold))
                markerBuffer = Array(markerBuffer.suffix(hold))
                rememberStderr(emit)
                display(emit)
            }
            return
        }
        routeOutput(slice)
    }

    private func routeOutput(_ slice: ArraySlice<UInt8>) {
        if let tmux { tmux.receive(slice) } else { display(Array(slice)) }
    }

    private func handleMarker(_ marker: RemoteBootstrap.Marker) {
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
            driver.size = { [weak self] in self?.sink?.cellSize ?? (80, 24) }
            driver.screenTail = { [weak self] in
                self?.sink?.screenTail(maxRows: 12).map { HistoryCatchUp.Anchor(lines: $0.lines, lastRow: $0.lastRow) }
            }
            driver.catchUpLimit = max(configurationProvider().serverHistoryLines, TmuxDriver.catchUpProbe)
            driver.onReady = { [weak self] in self?.becameOnline() }
            driver.onExit = { [weak self] reason in self?.tmuxExitReason = .some(reason) }
            driver.onActivity = { [weak self] command, path, rtt in
                guard let self else { return }
                if self.activity?.command != command || self.activity?.path != path {
                    self.activity = (command, path)
                }
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
        if !wasOnline { onPersistenceKnown?(self) }
        progress = nil
        if wasOnline { recorder?.mark("Reconnected \(Date().formatted(date: .omitted, time: .standard))") }
        wasOnline = true
        attempt = 0
        lastError = nil
        phase = .online
        if let size = sink?.cellSize { terminalDidResize(cols: size.cols, rows: size.rows) }
        startActivityPolling()
        onOnline?(self)
    }

    fileprivate func processTerminated(exitCode: Int32?) {
        process = nil
        releaseGate()
        AskPassBridge.shared.revoke(environment: askPassEnv)
        askPassEnv = [:]
        if intentionalStop || phase.isDead { return }

        // tmux told us why it exited.
        if let reason = tmuxExitReason {
            let text = reason ?? ""
            if text.contains("detached") {
                finish(reason: "Detached from tmux", archive: true)
            } else {
                finish(reason: "Session ended", archive: true)
            }
            return
        }

        // The server limits sessions per shared connection (sshd MaxSessions): use another one.
        if !phase.isOnline, Self.isSessionRefused(stderrTail), controlSlot < 32, sshOptions(configurationProvider()).useControlMaster {
            controlSlot += 1
            progress?.detail = "The server limits sessions per connection — opening another shared connection"
            launch(attachOnly: pendingAttachOnly)
            return
        }
        let code = exitCode ?? 255
        // In a plain shell a non-255 code means the shell exited normally.
        if persistence == .plain && code != 255 && markerResolved {
            finish(reason: "Shell exited (code \(code))", archive: true)
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
            if Self.isPermanentFailure(message) || attempt >= 2 || progress?.hostKeyChange != nil {
                endedByConnectionFailure = true
                finish(reason: message, archive: false)
                return
            }
        }
        lastError = stderrTail.isEmpty ? nil : stderrTail
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        let config = configurationProvider()
        attempt += 1
        if attempt == 1 { showLostNotice() }
        guard config.autoReconnect, config.maxReconnectAttempts == 0 || attempt <= config.maxReconnectAttempts else {
            phase = .waiting(attempt: attempt, nextRetry: nil)
            return
        }
        let delay = min(config.reconnectBaseDelay * pow(2, Double(min(attempt - 1, 8))), config.reconnectMaxDelay)
        phase = .waiting(attempt: attempt, nextRetry: Date().addingTimeInterval(delay))
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.retryTask = nil
            self.launch(attachOnly: self.wasOnline || self.restoredFromDisk)
        }
    }

    private func finish(reason: String, archive: Bool) {
        releaseGate()
        guard !phase.isDead else { return }
        retryTask?.cancel()
        phase = .dead(reason: reason)
        endedAt = Date()
        let sentence = reason.hasSuffix(".") ? reason : reason + "."
        let notice = "\r\n\u{1b}[2m[Tether] \(sentence) This session is now read-only.\u{1b}[0m\r\n"
        display(Array(notice.utf8))
        recorder?.close()
        if archive { onDeath?(self) }
        onEnded?(self)
    }

    /// Every 2 s while online: asks tmux what is running (tab titles) and measures latency.
    /// If the server stops answering for `stallTimeout` seconds the connection is treated as lost
    /// right away, instead of waiting for ssh's keep-alive to give up.
    private func startActivityPolling() {
        activityTask?.cancel()
        let timeout = configurationProvider().stallTimeout
        activityTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase.isOnline else { return }
                if let tmux = self.tmux {
                    // Lost only when the question went unanswered *and* nothing at all arrived:
                    // a connection busy with other tabs' output is slow, not dead.
                    if let sent = tmux.activitySentAt, Date().timeIntervalSince(sent) > timeout,
                       Date().timeIntervalSince(self.lastReceivedAt) > timeout {
                        self.connectionLost("The server stopped responding")
                        return
                    }
                    tmux.requestActivity()
                } else {
                    await self.measureLatencyOutOfBand()
                }
                try? await Task.sleep(for: .seconds(self.tmux == nil ? 10 : 2))
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

    /// Drops the current connection and enters the waiting state.
    private func connectionLost(_ reason: String, waitForNetwork: Bool = false) {
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
        // tmux: the banner above the terminal says it; the screen stays exactly as tmux left it, so
        // what the server prints meanwhile can be added seamlessly on reconnect (HistoryCatchUp).
        guard persistence != .tmux else { return }
        let notice = "\r\n\u{1b}[2m[Tether] Connection lost. History is kept; input is paused until the session is back.\u{1b}[0m\r\n"
        display(Array(notice.utf8))
    }

    private func display(_ raw: [UInt8]) {
        let (bytes, title) = titleFilter.filter(raw)
        if let title, title != remoteTitle { remoteTitle = title }
        guard !bytes.isEmpty else { return }
        fedAnything = true
        sink?.feed(bytes[...])
        recorder?.append(bytes)
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

    static func isSessionRefused(_ message: String) -> Bool {
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

    fileprivate var windowSize: winsize {
        let s: (cols: Int, rows: Int) = sink?.cellSize ?? (80, 24)
        return winsize(ws_row: UInt16(max(s.rows, 1)), ws_col: UInt16(max(s.cols, 1)), ws_xpixel: 0, ws_ypixel: 0)
    }
}

/// Non-isolated adapter between SwiftTerm's `LocalProcessDelegate` and the main-actor session.
/// The process is created with `dispatchQueue: .main`, so callbacks already run on the main thread.
final class ProcessBridge: LocalProcessDelegate {
    weak var owner: TerminalSession?
    init(owner: TerminalSession) { self.owner = owner }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        MainActor.assumeIsolated { owner?.processTerminated(exitCode: exitCode) }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { owner?.processOutput(slice) }
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

