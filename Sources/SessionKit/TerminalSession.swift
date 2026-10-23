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
    /// Whether to look for password prompts (from the settings; updated on connect and by the app).
    @ObservationIgnored public var detectPrompts = true
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

    private static let shells: Set<String> = ["bash", "zsh", "sh", "fish", "dash", "ksh", "tcsh", "csh", "-bash", "-zsh", "-sh"]

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
    public func send(_ bytes: ArraySlice<UInt8>) {
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
        display(Array("\r\n\u{1b}[2m[Tether] Disconnected. The session keeps running on the server.\u{1b}[0m\r\n".utf8))
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
            let executor = RemoteExecutor(target: descriptor.target, options: configurationProvider().ssh)
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
            let options = configurationProvider().ssh
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
        guard !target.isLocal, config.ssh.useControlMaster else {
            platform = target.isLocal ? .posix : (PlatformCache.shared.cached(target.key) ?? .posix)
            startTerminal(attachOnly: attachOnly)
            return
        }
        connectTask = Task { [weak self] in
            guard let self else { return }
            let executor = RemoteExecutor(target: target, options: config.ssh)
            if await executor.isMasterAlive() {
                self.progress?.detail = "Using the existing connection"
            } else {
                let env = AskPassBridge.shared.environment(targetKey: target.key, purpose: "connect", mode: "force")
                let connector = MasterConnector()
                self.connector = connector
                let error = await connector.connect(target: target, options: config.ssh, environment: env) { [weak self] line in
                    self?.progress?.ingest(line)
                }
                AskPassBridge.shared.revoke(environment: env)
                self.connector = nil
                guard !Task.isCancelled, !self.intentionalStop else { return }
                if let error {
                    self.connectionFailed(error)
                    return
                }
            }
            guard !Task.isCancelled, !self.intentionalStop else { return }
            self.progress?.detail = "Checking the server's shell"
            self.platform = await executor.resolvedPlatform()
            guard !Task.isCancelled, !self.intentionalStop else { return }
            self.startTerminal(attachOnly: attachOnly)
        }
    }

    /// Opening the shared connection failed: show why, then retry or give up.
    private func connectionFailed(_ fallback: String) {
        if progress?.failure == nil { progress?.failure = "Could not connect (\(fallback))." }
        let message = progress?.failure ?? fallback
        lastError = message
        let permanent = progress.map { p in p.log.contains { Self.isPermanentFailure($0) } } ?? false
        if !wasOnline && !pendingAttachOnly && (permanent || attempt >= 2) {
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
                                             directory: attachOnly ? nil : descriptor.initialDirectory)
        let local = descriptor.target.isLocal
        let executable = local ? "/bin/sh" : config.ssh.sshBinary
        let args = local ? ["-c", remote] : config.ssh.interactiveArguments(target: descriptor.target, remoteCommand: remote)

        AskPassBridge.shared.revoke(environment: askPassEnv)
        // "prefer" makes password prompts appear as a native sheet (with keychain support),
        // which also works while input is blocked during a reconnect.
        askPassEnv = AskPassBridge.shared.environment(targetKey: descriptor.target.key, purpose: "terminal", mode: "prefer")

        var env = ProcessInfo.processInfo.environment
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
        process.startProcess(executable: executable, args: args,
                             environment: env.map { "\($0.key)=\($0.value)" }, execName: local ? "sh" : "ssh")
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
        let args = config.ssh.interactiveArguments(target: descriptor.target, remoteCommand: command)
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
        process.startProcess(executable: config.ssh.sshBinary, args: args,
                             environment: env.map { "\($0.key)=\($0.value)" }, execName: "ssh")
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

    fileprivate func processOutput(_ slice: ArraySlice<UInt8>) {
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
            driver.size = { [weak self] in self?.sink?.cellSize ?? (80, 24) }
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
        if !wasOnline && !pendingAttachOnly {
            let message = stderrTail.isEmpty ? "ssh exited with code \(code)" : stderrTail
            if Self.isPermanentFailure(message) || attempt >= 2 {
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
        guard !phase.isDead else { return }
        retryTask?.cancel()
        phase = .dead(reason: reason)
        endedAt = Date()
        let notice = "\r\n\u{1b}[2m[Tether] \(reason). This session is now read-only.\u{1b}[0m\r\n"
        display(Array(notice.utf8))
        recorder?.close()
        if archive { onDeath?(self) }
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
                    if let sent = tmux.activitySentAt, Date().timeIntervalSince(sent) > timeout {
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
        guard !descriptor.target.isLocal else { return }
        let config = configurationProvider()
        guard config.ssh.useControlMaster else { return }
        let executor = RemoteExecutor(target: descriptor.target, options: config.ssh)
        let start = Date()
        let r = await executor.run(script: ":", timeout: 10, purpose: "latency")
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
        let notice = "\r\n\u{1b}[2m[Tether] Connection lost. History is kept; input is paused until the session is back.\u{1b}[0m\r\n"
        display(Array(notice.utf8))
        recorder?.mark("Connection lost \(Date().formatted(date: .omitted, time: .standard))")
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
            if prompt != passwordPrompt { passwordPrompt = prompt }
        }
    }

    private func rememberStderr(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let text = String(decoding: bytes, as: UTF8.self)
        let lines = (stderrTail + text).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        stderrTail = lines.suffix(2).joined(separator: "\n")
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
