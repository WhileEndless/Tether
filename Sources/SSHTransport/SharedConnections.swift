import Foundation
import TetherCore

/// The signed-in shared connections (ControlMaster), one per machine and slot, and the only place
/// that signs in for them.
///
/// Every ssh Tether runs to a host — terminals, file listings, transfers, monitoring, port forwards —
/// first asks `prepare` for the connection and then runs as a client of it that cannot sign in by
/// itself (`SSHOptions.controlPath`). So a machine is signed in to once, however many tabs, windows
/// and transfers want it at the same moment: they all wait for the one sign-in in progress.
///
/// The connection is kept like plain `ssh` keeps it: no forced keep-alives, and a silent channel
/// (`exec cat >/dev/null`) holds it open while Tether runs, so it never ends merely because no tab
/// used it for a while — also across sleep, when ssh's own clock keeps running. When Tether quits
/// (or crashes: the channel's input closes), the connection ends after `ControlPersist`.
public actor SharedConnections {
    public static let shared = SharedConnections()

    /// Who answers a sign-in, when one is needed. nil for background work: it never asks.
    public struct SignIn: Sendable {
        public var purpose: String
        /// The tab whose sign-in this is (its question is shown while it, or its host, is in front).
        public var sessionID: UUID?
        /// ssh's `-v` lines of the sign-in, for a progress display.
        public var onLine: (@Sendable (String) -> Void)?

        public init(purpose: String, sessionID: UUID? = nil, onLine: (@Sendable (String) -> Void)? = nil) {
            self.purpose = purpose
            self.sessionID = sessionID
            self.onLine = onLine
        }
    }

    public enum Outcome: Sendable {
        /// Ready: run ssh with these options (a client of the shared connection when it is shared).
        /// `reused`: the connection was already there — nobody signed in.
        case ready(SSHOptions, reused: Bool)
        /// Background work: signing in needs the user (a password, a host key).
        case needsUser(String)
        /// Signing in failed or was stopped; `log` holds ssh's last lines.
        case failed(String, log: [String])
    }

    /// Where a target's shared connection lives, as ssh itself works it out.
    struct Resolution: Sendable {
        var socket: String
        /// One jump host (ProxyJump) with no ProxyCommand of its own; nil otherwise.
        var jump: String?
        /// The jump host(s) as ssh reported them (also a chain), for `identity`.
        var route: String?
        var expires: TimeInterval

        /// What a remembered password belongs to: the socket name (host name, port, user and, in
        /// recent OpenSSH, the jump host) plus the jump route itself, for older ssh versions.
        var identity: String { socket + "\u{0}" + (route ?? "") }

        func socket(slot: Int) -> String { slot == 0 ? socket : socket + "-\(slot)" }
    }

    private final class Login {
        var waiters: [UUID: CheckedContinuation<Outcome, Never>] = [:]
        /// The tab each waiter stands for (nil: a file window, a transfer — shown wherever it is).
        var interest: [UUID: UUID?] = [:]
        /// The askpass token of its ssh, once started.
        var token: String?
        var environment: [String: String] = [:]
        /// When its ssh started (system uptime).
        var startedAt: TimeInterval = .infinity
        var launcher: MasterLauncher?
        /// The work signing in (cancelled when nobody waits any more, also during the jump host's turn).
        var task: Task<Void, Never>?
        let quiet: Bool
        var finished = false
        /// The jump host's connection this sign-in is waiting for, if any.
        var waitingOn: String?
        init(quiet: Bool) { self.quiet = quiet }
    }

    private final class Sentinel {
        let process: Process
        let input: Pipe
        let id = UUID()
        init(process: Process, input: Pipe) { self.process = process; self.input = input }
    }

    private var resolutions: [String: Resolution] = [:]
    private var resolving: [String: Task<Resolution?, Never>] = [:]
    private var logins: [String: Login] = [:]
    private var sentinels: [String: Sentinel] = [:]
    private var startingSentinel: Set<String> = []
    private var sentinelRestarts: [String: [TimeInterval]] = [:]
    /// When each socket last answered `-O check` (system uptime: sleep does not count).
    private var confirmed: [String: TimeInterval] = [:]
    private var closing = false
    /// How many times each connection was signed in (a forward made on an earlier one is gone).
    private var generations: [String: Int] = [:]
    /// What each connection is for (devices are only checked locally).
    private var targets: [String: ConnectionTarget] = [:]
    /// Connections whose silent channel gave way to a tab (the server allows one session only).
    private var withoutSentinel: Set<String> = []
    /// Where Tether's sockets live (tests use a folder of their own, so Tether's own is never touched).
    private var customSocketDirectory: URL?
    private var socketDirectory: URL { customSocketDirectory ?? AppPaths.controlSocketDirectory }

    /// Tests: sockets are worked out in, and stale ones removed only from, this folder.
    public func useSocketDirectory(_ url: URL) { customSocketDirectory = url }
    /// The `-v` logs of the connections this run signed in (see `MasterLauncher.Result.success`).
    private var logs: [String: FileHandle] = [:]
    private var trimming = false
    /// When each connection this run signed in was opened (wall clock: sleep included), for the log.
    private var openedAt: [String: Date] = [:]

    public static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A duration for the Connection Log: "0.8 s", "12 s", "3 min 5 s".
    public static func seconds(_ t: TimeInterval) -> String {
        let t = max(t, 0)
        if t < 10 { return String(format: "%.1f s", t) }
        if t < 120 { return "\(Int(t.rounded())) s" }
        if t < 3_600 { return "\(Int(t) / 60) min \(Int(t) % 60) s" }
        return "\(Int(t) / 3_600) h \(Int(t) % 3_600 / 60) min"
    }

    /// Told the askpass token of a sign-in that succeeded / did not (the app keeps a password typed
    /// for it only after it worked, see `SealedPasswordCache`).
    /// `refused`: it failed because the server turned the password down.
    nonisolated(unsafe) public static var onSignInResult: (@Sendable (_ token: String, _ succeeded: Bool, _ refused: Bool) -> Void)?
    /// Told which connection a sign-in's askpass token is for (its socket for slot 0, which ssh
    /// derives from the local host, host name, port, user and jump host): a password typed for it
    /// is remembered for exactly that connection.
    nonisolated(unsafe) public static var onSignInStarted: (@Sendable (_ token: String, _ connection: String) -> Void)?

    // MARK: Preparing

    /// The connection for `target` (signing in once if it is not there), or why there is none.
    /// Without connection sharing, or for this Mac, the options come back unchanged.
    public func prepare(_ target: ConnectionTarget, options: SSHOptions, signIn: SignIn?) async -> Outcome {
        await prepare(target, options: options, signIn: signIn, chain: [])
    }

    /// `chain`: the connections a jump host is being prepared for (a jump host that leads back to
    /// one of them uses ssh's own hop instead of waiting for itself).
    private func prepare(_ target: ConnectionTarget, options: SSHOptions, signIn: SignIn?, chain: Set<String>) async -> Outcome {
        guard options.useControlMaster, !target.isLocal else { return .ready(options, reused: false) }
        guard let resolution = await resolve(target, options: options) else {
            // ssh could not work the socket out (a broken config): the old shared connection
            // (ControlMaster=auto), which ssh then reports the problem with.
            var legacy = options
            legacy.controlPath = nil
            return .ready(legacy, reused: false)
        }
        var o = options
        o.controlPath = resolution.socket(slot: options.controlSlot)
        let socket = o.controlPath!
        if isReady(socket) { return .ready(o, reused: true) }
        // A further connection to a server whose first one is signing in right now waits for it:
        // the password typed there is then remembered (Signing In Again) and answers this one too,
        // instead of a second question while the first is still being answered.
        if options.controlSlot > 0, let first = logins[resolution.socket], !first.finished {
            _ = await wait(on: first, socket: resolution.socket, for: signIn)
            if isReady(socket) { return .ready(o, reused: true) }
        }
        // Whoever asked is gone (a tab closed while this was being worked out): no sign-in for it.
        if Task.isCancelled { return .failed("The sign-in was stopped", log: []) }
        let quiet = signIn == nil
        // A background attempt (no questions) in progress: wait for it; if it found that the user
        // is needed, a sign-in that may ask follows.
        if let login = logins[socket], !login.quiet || quiet {
            return await wait(on: login, socket: socket, for: signIn)
        }
        if let login = logins[socket], login.quiet {
            let first = await wait(on: login, socket: socket, for: signIn)
            guard case .needsUser = first else { return first }
            if let again = logins[socket] { return await wait(on: again, socket: socket, for: signIn) }
        }
        // One sign-in at a time per server: while another connection of it signs in (the first or
        // a further one), this one waits. A remembered password is then sent once, not by several
        // connections at the same moment, and one the server refused is forgotten before anything
        // sends it again; a password typed there is remembered and answers this one too.
        if !quiet {
            while let other = signingIn(besides: socket, of: resolution) {
                _ = await wait(on: other.login, socket: other.socket, for: signIn)
                if Task.isCancelled { return .failed("The sign-in was stopped", log: []) }
                if isReady(socket) { return .ready(o, reused: true) }
            }
            if let login = logins[socket], !login.quiet { return await wait(on: login, socket: socket, for: signIn) }
        }
        let login = Login(quiet: quiet)
        logins[socket] = login
        login.task = Task { await self.establish(login, socket: socket, target: target, options: o, resolution: resolution,
                                                 signIn: signIn, chain: chain.union([resolution.socket])) }
        return await wait(on: login, socket: socket, for: signIn)
    }

    /// A sign-in that may ask (not a background one) in progress for another connection of the
    /// same server (`resolution.socket(slot:)` of another slot).
    private func signingIn(besides socket: String, of resolution: Resolution) -> (socket: String, login: Login)? {
        let base = resolution.socket
        return logins.first { key, login in
            guard key != socket, !login.finished, !login.quiet else { return false }
            if key == base { return true }
            guard key.hasPrefix(base + "-") else { return false }
            let slot = key.dropFirst(base.count + 1)
            return !slot.isEmpty && slot.allSatisfy(\.isNumber)
        }.map { ($0.key, $0.value) }
    }

    /// Waits for a sign-in in progress. A waiter that is cancelled (its tab closed) stops waiting;
    /// the sign-in goes on for the others and ends only when nobody waits for it any more.
    private func wait(on login: Login, socket: String, for signIn: SignIn?) async -> Outcome {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
                if login.finished || Task.isCancelled {
                    cont.resume(returning: .failed("The sign-in was stopped", log: []))
                } else {
                    login.waiters[id] = cont
                    login.interest[id] = signIn?.sessionID
                    publishInterest()
                }
            }
        } onCancel: {
            Task { await self.leave(login, id: id, socket: socket) }
        }
    }

    private func leave(_ login: Login, id: UUID, socket: String) {
        guard let cont = login.waiters.removeValue(forKey: id) else { return }
        login.interest[id] = nil
        cont.resume(returning: .failed("The sign-in was stopped", log: []))
        if login.waiters.isEmpty, !login.finished {
            login.launcher?.cancel()
            login.task?.cancel()      // a jump host's sign-in waited for by this one stops too
            // A new request for this connection starts afresh instead of joining one being stopped.
            if logins[socket] === login { logins[socket] = nil }
        }
        publishInterest()
    }

    /// Who a sign-in question stands for, by askpass token: the tabs waiting for it — also those
    /// waiting for a host behind it, when it is a jump host's — and whether anything without a tab
    /// (a file window, a transfer) waits. The app shows the question when one of them is in front.
    private func publishInterest() {
        var byToken: [String: SignInInterest.Waiting] = [:]
        for (socket, login) in logins {
            guard let token = login.token else { continue }
            var waiting = SignInInterest.Waiting()
            var queue = [socket], seen: Set<String> = []
            while let s = queue.popLast(), seen.insert(s).inserted {
                guard let l = logins[s] else { continue }
                for value in l.interest.values {
                    if let id = value { waiting.sessions.insert(id) } else { waiting.unowned = true }
                }
                queue += logins.filter { $0.value.waitingOn == s }.map(\.key)
            }
            byToken[token] = waiting
        }
        SignInInterest.replace(byToken)
    }

    private func finish(_ login: Login, socket: String, _ outcome: Outcome) {
        login.finished = true
        if logins[socket] === login { logins[socket] = nil }
        let waiters = login.waiters
        login.waiters = [:]
        login.interest = [:]
        publishInterest()
        for cont in waiters.values { cont.resume(returning: outcome) }
    }

    private func establish(_ login: Login, socket: String, target: ConnectionTarget, options: SSHOptions,
                           resolution: Resolution, signIn: SignIn?, chain: Set<String>) async {
        // Already there (made before this run of the app, or a moment ago): use it. A second
        // master would sign in once more and then hang ("ControlSocket … already exists").
        if Self.isSocket(socket) {
            switch await Self.check(socket, ssh: options.sshBinary) {
            case .alive:
                ConnectionLog.shared.info("Using the connection already open", host: target.key)
                confirmed[socket] = Self.uptime
                targets[socket] = target
                if generations[socket] == nil { generations[socket] = 1 }
                finish(login, socket: socket, .ready(options, reused: true))
                startSentinel(target: target, options: options)
                return
            case .noAnswer:
                // Busy or stuck, but there: never a second one next to it.
                ConnectionLog.shared.notice("The open connection did not answer a local check; used as it is", host: target.key)
                finish(login, socket: socket, .ready(options, reused: true))
                return
            case .gone:
                ConnectionLog.shared.info("Removed the socket of a connection that had ended", host: target.key)
                Self.removeStaleSocket(socket, directory: socketDirectory)
            }
        }
        if signIn == nil, let reason = BackgroundSignIn.shared.reason(target.key) {
            ConnectionLog.shared.info("Background work waits: signing in needs the user", .signIn, host: target.key)
            finish(login, socket: socket, .needsUser(BackgroundSignIn.message(reason, sharing: true)))
            return
        }
        // Behind one jump host: through the jump host's own shared connection, so every host behind
        // it shares one sign-in there. If that cannot be had, ssh's own hop (it signs in itself).
        var proxyCommand: String?
        if login.waiters.isEmpty || Task.isCancelled {
            finish(login, socket: socket, .failed("The sign-in was stopped", log: []))
            return
        }
        var jumpOptions = options
        jumpOptions.controlPath = nil
        jumpOptions.controlSlot = 0
        let jumpTarget = resolution.jump.map(Self.target(forJump:))
        let jumpSocket: String? = if let jumpTarget { await resolve(jumpTarget, options: jumpOptions)?.socket } else { nil }
        // A jump host that leads back here — on this path, or through sign-ins already waiting for
        // each other (two tabs opened at once to hosts that jump through one another) — uses ssh's
        // own hop instead of waiting for itself.
        let loopsBack = jumpSocket.map { chain.contains($0) || waits($0, on: socket) } ?? true
        if jumpTarget != nil, jumpSocket != nil, loopsBack {
            ConnectionLog.shared.notice("Jump hosts lead back to each other; using ssh's own hop", host: target.key)
        }
        if let jumpTarget, !loopsBack, chain.count < 4 {
            login.waitingOn = jumpSocket
            defer { login.waitingOn = nil }
            switch await prepare(jumpTarget, options: jumpOptions, signIn: signIn, chain: chain) {
            case .ready(let ready, _) where ready.usesSharedConnection:
                ConnectionLog.shared.info("Going through the jump host's own connection", host: target.key, detail: jumpTarget.key)
                proxyCommand = Self.proxyCommand(through: ready, jump: jumpTarget)
            case .needsUser(let message):
                finish(login, socket: socket, .needsUser(message))
                return
            case .failed(let message, let log):
                // The jump host's sign-in failed or was cancelled: ssh's own hop would only ask again.
                ConnectionLog.shared.problem("The jump host's sign-in did not succeed", .signIn, host: target.key, detail: message)
                finish(login, socket: socket, .failed(message, log: log))
                return
            case .ready:
                break
            }
        }
        // Everyone who wanted it stopped waiting (tabs closed, the jump host took a while): no
        // sign-in — and no question — for nobody.
        guard !login.waiters.isEmpty else {
            ConnectionLog.shared.info("Sign-in not started: nobody waits for it any more", .signIn, host: target.key)
            finish(login, socket: socket, .failed("The sign-in was stopped", log: []))
            return
        }
        let quiet = signIn == nil
        let env = quiet ? AskPassBridge.shared.refusingEnvironment(targetKey: target.key, purpose: "connect")
                        : AskPassBridge.shared.environment(targetKey: target.key, purpose: signIn?.purpose ?? "connect",
                                                           mode: "force", sessionID: signIn?.sessionID)
        // Its log sits next to its socket (Tether's private socket folder).
        let launcher = MasterLauncher(directory: URL(fileURLWithPath: socket).deletingLastPathComponent())
        login.launcher = launcher
        if !quiet, let token = env["TETHER_ASKPASS_TOKEN"] { Self.onSignInStarted?(token, resolution.identity) }
        login.token = env["TETHER_ASKPASS_TOKEN"]
        login.environment = env
        login.startedAt = Self.uptime
        publishInterest()
        var args = options.masterArguments(target: target, controlPath: socket, logFile: launcher.logPath, proxyCommand: proxyCommand)
        if quiet { args.insert(contentsOf: ["-o", "BatchMode=yes"], at: 0) }
        ConnectionLog.shared.info((quiet ? "Signing in without asking (background work)" : "Signing in")
                                  + (options.controlSlot > 0 ? " (connection \(options.controlSlot + 1))" : "")
                                  + (proxyCommand != nil ? " through the jump host's connection" : resolution.jump.map { _ in " through a jump host" } ?? ""),
                                  .signIn, host: target.key, detail: signIn.map { "Asked for by: " + $0.purpose })
        let result = await launcher.run(ssh: options.sshBinary, arguments: args, environment: env, onLine: signIn?.onLine)
        AskPassBridge.shared.revoke(environment: env)
        if let token = env["TETHER_ASKPASS_TOKEN"] {
            switch result {
            case .success: Self.onSignInResult?(token, true, false)
            case .failure(_, let log):
                Self.onSignInResult?(token, false, BackgroundSignIn.reasonFor(stderr: log.joined(separator: "\n")) == .password)
            }
        }
        login.launcher = nil
        switch result {
        case .success(let log):
            generations[socket, default: 0] += 1
            targets[socket] = target
            openedAt[socket] = Date()
            let steps = launcher.milestones
            ConnectionLog.shared.notice("Signed in" + (options.controlSlot > 0 ? " (connection \(options.controlSlot + 1))" : "")
                                        + (DiagnosticText.signInMethod(steps).map { " with \($0)" } ?? "")
                                        + " in " + Self.seconds(Self.uptime - login.startedAt),
                                        .signIn, host: target.key, detail: steps.joined(separator: "\n"))
            if let log { logs[socket] = log }
            trimLogsSoon()
            BackgroundSignIn.shared.clear(target.key)
            confirmed[socket] = Self.uptime
            finish(login, socket: socket, .ready(options, reused: false))
            startSentinel(target: target, options: options)
        case .failure(let message, let log):
            let steps = launcher.milestones
            let last = log.suffix(3).filter { !steps.contains($0) }
            // ssh's words (host names, addresses) go in the detail: private in macOS's log.
            ConnectionLog.shared.problem("Sign-in failed after " + Self.seconds(Self.uptime - login.startedAt),
                                         .signIn, host: target.key, detail: ([message] + steps + last).joined(separator: "\n"))
            if quiet {
                BackgroundSignIn.shared.noteQuietResult(target.key, status: 255, stderr: log.joined(separator: "\n"))
                if let reason = BackgroundSignIn.shared.reason(target.key) {
                    finish(login, socket: socket, .needsUser(BackgroundSignIn.message(reason, sharing: true)))
                    return
                }
            }
            finish(login, socket: socket, .failed(message, log: log))
        }
    }

    /// How many times `target`'s connection has been signed in during this run (0: never). A port
    /// forward made on an earlier one is gone and must be made again.
    public func generation(of target: ConnectionTarget, options: SSHOptions) async -> Int {
        guard let socket = await socket(for: target, options: options) else { return 0 }
        return generations[socket] ?? 0
    }

    /// The host a connection goes to (as the tabs name it), for the log; nil when not known.
    public func hostKey(of socket: String) -> String? { targets[socket]?.key }

    /// Whether this connection is to a network device (checked locally only, nothing run on it).
    public func isDeviceConnection(_ socket: String) -> Bool {
        targets[socket].map { PlatformCache.shared.isDevice($0.key) } ?? false
    }

    /// The server refused a tab a session while the silent channel held one (a server that allows
    /// a single session per connection): the channel gives way, for good, on this connection.
    /// Whether there was one to give way.
    public func yieldSentinel(for target: ConnectionTarget, options: SSHOptions) async -> Bool {
        guard let socket = await socket(for: target, options: options) else { return false }
        withoutSentinel.insert(socket)
        guard let s = sentinels.removeValue(forKey: socket) else { return false }
        if s.process.isRunning { s.process.terminate() }
        ConnectionLog.shared.notice("The server allows few sessions; the silent channel gave way to a tab", host: target.key)
        return true
    }

    /// The network changed or the Mac woke while sign-ins were under way: those not waiting for the
    /// user are started again (one begun on the old network would hang until TCP gives up).
    public func restartStalledSignIns(startedBefore moment: TimeInterval) {
        for (socket, login) in logins where !login.finished && login.startedAt < moment {
            guard let launcher = login.launcher, !AskPassBridge.shared.isAsking(environment: login.environment) else { continue }
            ConnectionLog.shared.info("Restarted a sign-in begun before the network changed", .signIn, host: targets[socket]?.key)
            launcher.cancel()
        }
    }

    /// Whether the sign-in for `socket` is (indirectly) waiting for the one for `target`.
    private func waits(_ socket: String, on target: String) -> Bool {
        var current: String? = socket
        for _ in 0..<8 {
            guard let c = current else { return false }
            if c == target { return true }
            current = logins[c]?.waitingOn
        }
        return true
    }

    /// Ready without asking anyone: the socket is there and either its silent channel still runs
    /// (it ends the moment the connection does) or it answered a moment ago.
    private func isReady(_ socket: String) -> Bool {
        guard logins[socket] == nil, Self.isSocket(socket) else { return false }
        if let s = sentinels[socket], s.process.isRunning { return true }
        if let at = confirmed[socket], Self.uptime - at < 20 { return true }
        return false
    }

    /// Whether `target`'s shared connection is up (checking it if needed), without signing in.
    public func isUp(_ target: ConnectionTarget, options: SSHOptions) async -> Bool {
        guard options.useControlMaster, !target.isLocal, let r = await resolve(target, options: options) else { return false }
        let socket = r.socket(slot: options.controlSlot)
        if isReady(socket) { return true }
        guard Self.isSocket(socket), case .alive = await Self.check(socket, ssh: options.sshBinary) else { return false }
        confirmed[socket] = Self.uptime
        return true
    }

    /// The name ssh gives `target`'s connection (host name, port, user, jump host), also when
    /// connections are not shared: a sign-in for it takes part in Signing In Again.
    public func identity(of target: ConnectionTarget, options: SSHOptions) async -> String? {
        guard !target.isLocal else { return nil }
        return await resolve(target, options: options)?.identity
    }

    /// The socket of `target`'s shared connection (for its slot), whether or not it is up.
    public func socket(for target: ConnectionTarget, options: SSHOptions) async -> String? {
        guard options.useControlMaster, !target.isLocal else { return nil }
        return await resolve(target, options: options)?.socket(slot: options.controlSlot)
    }

    /// The prepared client options for `target` if its connection is up; nil otherwise.
    public func readyOptions(_ target: ConnectionTarget, options: SSHOptions) async -> SSHOptions? {
        guard await isUp(target, options: options), let r = await resolve(target, options: options) else { return nil }
        var o = options
        o.controlPath = r.socket(slot: options.controlSlot)
        return o
    }

    /// A client found its connection gone (it ended between `prepare` and the client's start):
    /// the next `prepare` checks again instead of trusting what it saw.
    public func forget(socket: String) {
        confirmed[socket] = nil
        if let s = sentinels.removeValue(forKey: socket), s.process.isRunning { s.process.terminate() }
    }

    /// Host settings changed (ssh_config, a host edited): sockets are worked out again.
    public func forgetResolutions() { resolutions = [:] }

    // MARK: Resolving

    func resolve(_ target: ConnectionTarget, options: SSHOptions) async -> Resolution? {
        // The whole destination (jump host, identity, port, user), not just the target's name: two
        // direct connections to one address through different jump hosts are different machines.
        let key = ([options.configFile?.path ?? "", options.sshBinary] + SSHOptions.destinationArguments(for: target))
            .joined(separator: "\u{0}")
        if let r = resolutions[key], r.expires > Self.uptime { return r }
        // Many tabs opening at once ask together: one `ssh -G` answers them all.
        if let running = resolving[key] { return await running.value }
        let args = options.resolveArguments(target: target, directory: socketDirectory), ssh = options.sshBinary
        let task = Task<Resolution?, Never> {
            let r = await ProcessRunner.run(ssh, arguments: args, timeout: 10)
            guard r.status == 0, !r.timedOut, let parsed = Self.parseResolution(r.output) else {
                ConnectionLog.shared.problem("ssh could not work out where this host's connection lives", host: target.key, detail: r.errorOutput)
                return nil
            }
            return Resolution(socket: parsed.socket, jump: parsed.jump, route: parsed.route, expires: Self.uptime + 300)
        }
        resolving[key] = task
        let resolution = await task.value
        resolving[key] = nil
        if let resolution { resolutions[key] = resolution }
        return resolution
    }

    /// The socket and the single jump host from `ssh -G` output.
    nonisolated static func parseResolution(_ output: String) -> (socket: String, jump: String?, route: String?)? {
        var socket: String?, jump: String?, proxyCommand = false
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "controlpath": socket = parts[1]
            case "proxyjump": jump = parts[1]
            case "proxycommand": proxyCommand = parts[1].lowercased() != "none"
            default: break
            }
        }
        guard let socket, socket.hasPrefix("/"), socket.lowercased() != "none" else { return nil }
        let route = jump?.lowercased() == "none" ? nil : jump
        // A chain of jump hosts, or the user's own ProxyCommand: ssh's own hop is kept.
        if proxyCommand || jump?.contains(",") == true || jump?.lowercased() == "none" { jump = nil }
        return (socket, jump, route)
    }

    /// The jump host as a destination: `user@host:port` or a host / ssh_config name.
    nonisolated static func target(forJump spec: String) -> ConnectionTarget {
        var rest = spec.trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("ssh://") { rest.removeFirst(6) }
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        var port: Int?
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let tail = rest[rest.index(after: close)...]
            if tail.hasPrefix(":") { port = Int(tail.dropFirst()) }
            rest = String(rest[rest.index(after: rest.startIndex)..<close])
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":") {
            port = Int(rest[rest.index(after: colon)...])
            rest = String(rest[..<colon])
        }
        if user == nil, port == nil { return .alias(rest) }
        return .adhoc(user: user, host: rest, port: port, jump: nil)
    }

    /// A ProxyCommand that reaches the target through the jump host's shared connection (`-W`).
    /// It cannot sign in to the jump host itself; `%` is doubled (ssh expands it in ProxyCommand).
    nonisolated static func proxyCommand(through jump: SSHOptions, jump target: ConnectionTarget) -> String {
        var parts = [jump.sshBinary]
        if let config = jump.configFile { parts += ["-F", config.path] }
        parts += ["-o", "ControlMaster=no", "-o", "ControlPath=\(jump.controlPath ?? "none")",
                  "-o", "ProxyCommand=/usr/bin/false", "-o", "BatchMode=yes"]
        parts += SSHOptions.destinationArguments(for: target, jump: false)
        let quoted = parts.map { $0.replacingOccurrences(of: "%", with: "%%").shellQuoted }
        // -W goes before the destination's "--".
        let dash = quoted.firstIndex(of: "--") ?? quoted.endIndex
        var line = quoted
        line.insert(contentsOf: ["-W", "'[%h]:%p'"], at: dash)
        return line.joined(separator: " ")
    }

    // MARK: The silent channel

    /// Holds the connection open while Tether runs: `exec cat >/dev/null` (PowerShell on Windows)
    /// prints nothing — a server sending data to a sleeping Mac gives up on the connection after
    /// some minutes — and ends when its input closes (Tether quit or crashed). Not for devices,
    /// which run nothing Tether sends.
    private func startSentinel(target: ConnectionTarget, options: SSHOptions) {
        guard let socket = options.controlPath, !closing, sentinels[socket] == nil, !startingSentinel.contains(socket),
              !withoutSentinel.contains(socket) else { return }
        // Not in a loop: a server that ends the channel at once (a restricted account) gets a few
        // tries in ten minutes, then the connection lives without it.
        let now = Self.uptime
        let recent = (sentinelRestarts[socket] ?? []).filter { now - $0 < 600 }
        guard recent.count < 4 else {
            ConnectionLog.shared.notice("The silent channel keeps ending; the connection goes on without it", host: target.key)
            return
        }
        sentinelRestarts[socket] = recent + [now]
        startingSentinel.insert(socket)
        Task {
            let platform = await RemoteExecutor(target: target, options: options).resolvedPlatform(quiet: true)
            self.launchSentinel(target: target, options: options, socket: socket, platform: platform)
        }
    }

    private func launchSentinel(target: ConnectionTarget, options: SSHOptions, socket: String, platform: RemotePlatform) {
        startingSentinel.remove(socket)
        guard !closing, sentinels[socket] == nil, Self.isSocket(socket), !PlatformCache.shared.isDevice(target.key) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: options.sshBinary)
        let command = platform.isWindows ? PowerShell.launcher : "exec cat >/dev/null"
        p.arguments = options.commonOptions() + ["-T", "-o", "BatchMode=yes"] + options.destination(target) + [command]
        p.environment = ChildEnvironment.base.merging(AskPassBridge.shared.refusingEnvironment(targetKey: target.key, purpose: "sentinel")) { $1 }
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let sentinel = Sentinel(process: p, input: input)
        p.terminationHandler = { _ in Task { await self.sentinelEnded(socket, id: sentinel.id, target: target, options: options) } }
        do { try p.run() } catch { return }
        if platform.isWindows {
            // The launcher reads its script from the first line; ReadToEnd then waits for the end
            // of input, which never comes while Tether runs.
            try? input.fileHandleForWriting.write(contentsOf: PowerShell.input("$null=[Console]::In.ReadToEnd()", arguments: []))
        }
        sentinels[socket] = sentinel
    }

    private func sentinelEnded(_ socket: String, id: UUID, target: ConnectionTarget, options: SSHOptions) async {
        // An older channel ending after a new one took its place changes nothing.
        guard sentinels[socket]?.id == id else { return }
        sentinels[socket] = nil
        guard !closing else { return }
        if Self.isSocket(socket), case .alive = await Self.check(socket, ssh: options.sshBinary) {
            // The connection is fine; only the channel ended (the server limits sessions, someone
            // ended `cat`): open it again (`startSentinel` keeps this from looping).
            ConnectionLog.shared.info("The silent channel ended; opening it again", host: target.key)
            startSentinel(target: target, options: options)
            return
        }
        confirmed[socket] = nil
        let lived = openedAt.removeValue(forKey: socket).map { " after " + Self.seconds(Date().timeIntervalSince($0)) } ?? ""
        ConnectionLog.shared.notice("The connection ended" + lived, host: target.key)
    }

    /// Empties the connections' logs every few minutes and lets go of those whose connection ended.
    private func trimLogsSoon() {
        guard !trimming else { return }
        trimming = true
        Task {
            while true {
                try? await Task.sleep(for: .seconds(300))
                guard self.trimLogs() else { break }
            }
        }
    }

    private func trimLogs() -> Bool {
        for (socket, handle) in logs {
            if Self.isSocket(socket) { try? handle.truncate(atOffset: 0) } else { try? handle.close(); logs[socket] = nil }
        }
        if logs.isEmpty { trimming = false }
        return !logs.isEmpty
    }

    // MARK: Ending

    /// Tether quits: every shared connection ends now (sessions on the servers keep running). Does
    /// not wait — `ssh -O exit` finishes on its own after the app is gone.
    public nonisolated static func closeAllNow(ssh: String) {
        let dir = AppPaths.controlSocketDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name != AppPaths.askPassSocket.lastPathComponent {
            let path = dir.appendingPathComponent(name).path
            guard isSocket(path) else { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ssh)
            p.arguments = ["-F", "/dev/null", "-o", "ControlPath=\(path)", "-O", "exit", "tether-master"]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
    }

    /// Ends the silent channels and forgets what is known (tests, which use their own sockets).
    public func reset() {
        stopSentinels()
        resolutions = [:]
        confirmed = [:]
        sentinelRestarts = [:]
        closing = false
    }

    private func stopSentinels() {
        for s in sentinels.values where s.process.isRunning { s.process.terminate() }
        sentinels = [:]
    }

    // MARK: Sockets

    public enum Check: Sendable { case alive, gone, noAnswer }

    /// `ssh -O check` on the socket itself: the master process answers (says nothing about its link).
    public nonisolated static func check(_ socket: String, ssh: String) async -> Check {
        let r = await ProcessRunner.run(ssh, arguments: ["-F", "/dev/null", "-o", "ControlPath=\(socket)", "-O", "check", "tether-master"],
                                        timeout: 5)
        if r.timedOut { return .noAnswer }
        return r.status == 0 ? .alive : .gone
    }

    /// What a client of a shared connection says when the connection is not there: its ProxyCommand
    /// (`/usr/bin/false`) ended at once, or the socket refused it.
    public nonisolated static func isLostConnectionMessage(_ stderr: String) -> Bool {
        stderr.contains("UNKNOWN port 65535") || stderr.contains("Control socket connect")
    }

    public nonisolated static func isSocket(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK
    }

    /// A socket left by a connection that ended without removing it: only a socket, only inside
    /// Tether's own socket folder.
    nonisolated static func removeStaleSocket(_ path: String, directory: URL) {
        let dir = directory.standardizedFileURL.path + "/"
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path.hasPrefix(dir), url.deletingLastPathComponent().standardizedFileURL.path + "/" == dir,
              isSocket(url.path), url.lastPathComponent != AppPaths.askPassSocket.lastPathComponent else { return }
        unlink(url.path)
    }
}

/// Runs the ssh that signs in and becomes a shared connection, reading its `-v` log so progress can
/// be shown without anything appearing in a terminal.
final class MasterLauncher: @unchecked Sendable {
    enum Result: @unchecked Sendable {
        /// Signed in; `log` stays open on the connection's `-v` log (see `SharedConnections.trimLogs`).
        case success(log: FileHandle?)
        case failure(String, log: [String])
    }

    let logPath: String
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var offset: UInt64 = 0
    private var partial = ""
    private var tail: [String] = []
    /// ssh's steps worth reporting (`DiagnosticText.isMilestone`), for the Connection Log.
    private var steps: [String] = []
    /// When ssh last wrote to its log (system uptime): a sign-in stuck without a word is ended.
    private var lastProgress = ProcessInfo.processInfo.systemUptime
    private var environment: [String: String] = [:]
    static let silentLimit: TimeInterval = 45

    init(directory: URL) {
        logPath = directory.appendingPathComponent("connect-\(UUID().uuidString.prefix(8)).log").path
    }

    /// ssh's steps so far (where it connected, how it signed in, its errors).
    var milestones: [String] { lock.withLock { steps } }

    func cancel() {
        lock.lock(); cancelled = true; let p = process; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    func run(ssh: String, arguments: [String], environment: [String: String],
             onLine: (@Sendable (String) -> Void)?) async -> Result {
        FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ssh)
        p.arguments = arguments
        p.environment = ChildEnvironment.base.merging(environment) { $1 }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 0.15, repeating: 0.15)
        self.environment = environment
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.readLog(onLine)
            self.stopIfStuck()
        }
        // Started at once: a dispatch source cancelled or released before it ever ran ends the app.
        timer.resume()
        let status: Int32 = await withCheckedContinuation { cont in
            p.terminationHandler = { cont.resume(returning: $0.terminationReason == .uncaughtSignal ? -2 : $0.terminationStatus) }
            lock.lock()
            let stop = cancelled
            if !stop { process = p }
            lock.unlock()
            if stop { p.terminationHandler = nil; cont.resume(returning: -2); return }
            do {
                try p.run()
                AskPassBridge.shared.bindToken(environment, pid: p.processIdentifier)
            } catch { p.terminationHandler = nil; cont.resume(returning: -1) }
        }
        timer.cancel()
        readLog(onLine)
        lock.withLock { process = nil }
        // The connection keeps writing to this file for as long as it lives: the name goes, and a
        // handle stays so it can be emptied now and then (ssh appends, so it writes on at the start).
        let handle = status == 0 ? FileHandle(forUpdatingAtPath: logPath) : nil
        unlink(logPath)
        if status == 0 { try? handle?.truncate(atOffset: 0); return .success(log: handle) }
        let log = lock.withLock { tail }
        if status == -2 { return .failure("The sign-in was stopped", log: log) }
        return .failure("ssh exited with code \(status)", log: log)
    }

    /// A server that answered and then went silent in the middle of signing in (a key exchange or
    /// an authentication step that never finishes): stopped after a while, unless a question waits
    /// for the user — so every tab, file window and transfer waiting for this server is not stuck.
    private func stopIfStuck() {
        let idle = lock.withLock { ProcessInfo.processInfo.systemUptime - lastProgress }
        guard idle > Self.silentLimit, !AskPassBridge.shared.isAsking(environment: environment) else { return }
        ConnectionLog.shared.problem("A sign-in made no progress for \(Int(Self.silentLimit)) s; stopped", .signIn, detail: milestones.suffix(6).joined(separator: "\n"))
        cancel()
    }

    private func readLog(_ onLine: (@Sendable (String) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        guard let h = FileHandle(forReadingAtPath: logPath) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        guard let data = try? h.readToEnd(), !data.isEmpty else { return }
        offset += UInt64(data.count)
        lastProgress = ProcessInfo.processInfo.systemUptime
        let text = partial + String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        partial = lines.removeLast()
        for l in lines {
            let t = l.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            tail.append(t)
            if tail.count > 40 { tail.removeFirst(tail.count - 40) }
            if DiagnosticText.isMilestone(t) {
                steps.append(t)
                if steps.count > 60 { steps.removeFirst(steps.count - 60) }
            }
            onLine?(t)
        }
    }
}

/// Which tabs wait for each sign-in question (see `SharedConnections.publishInterest`), readable
/// from the app at once.
public enum SignInInterest {
    public struct Waiting: Sendable {
        public var sessions: Set<UUID> = []
        /// Something without a tab waits (a file window, a transfer): the question is always shown.
        public var unowned = false
    }

    nonisolated(unsafe) private static var table: [String: Waiting] = [:]
    private static let lock = NSLock()

    static func replace(_ new: [String: Waiting]) { lock.withLock { table = new } }

    /// Who waits for the sign-in that asks with this askpass token (nil: not a shared sign-in).
    public static func waiting(for token: String) -> Waiting? { lock.withLock { table[token] } }
}
