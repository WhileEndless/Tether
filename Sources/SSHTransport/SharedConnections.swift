import CryptoKit
import Foundation
import os
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
        /// Where ssh goes, as `ssh -G` puts it (host name, port, user, ProxyCommand); nil when it
        /// did not say.
        var destination: String? = nil
        /// What the user's ssh_config sets that Tether's own options take into account.
        var config = UserConfig()

        /// What a remembered password belongs to: the server ssh goes to (host name, port, user,
        /// ProxyCommand) and the jump route. Not the socket name: ssh's `%C` also hashes this Mac's
        /// own host name, which can change with the network (a new address, waking from sleep), and
        /// the password typed for a server must still be found afterwards.
        var identity: String { (destination ?? socket) + "\u{0}" + (route ?? "") }

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
        /// The network changed or the Mac woke while it signed in: a failure is the network's.
        var networkChanged = false
        /// It failed in a way its waiters must not each try again (the user cancelled, the server
        /// refused): they get its result instead of starting sign-ins of their own, one after another.
        var stopsWaiters = false
        init(quiet: Bool) { self.quiet = quiet }
    }

    private final class Sentinel {
        let process: Process
        let input: ChildPipe
        let id = UUID()
        init(process: Process, input: ChildPipe) { self.process = process; self.input = input }

        /// Ends its channel: stopped, and its input closed (so it also ends if the signal is late).
        func end() {
            if process.isRunning { process.terminate() }
            try? input.write.close()
        }
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
    /// The last things each connection's ssh said (its errors, not its steps), kept when its log is
    /// emptied: when the connection ends, they say why.
    private var lastWords: [String: [String]] = [:]
    private var trimming = false

    /// A connection's own last words: what its log holds now after what was kept from before.
    private func lastWords(of socket: String) -> [String] {
        var words = lastWords[socket] ?? []
        if let handle = logs[socket] {
            try? handle.seek(toOffset: 0)
            if let data = try? handle.readToEnd() {
                words += String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
                    .filter { !$0.hasPrefix("debug") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            }
            _ = try? handle.seekToEnd()
        }
        return Array(words.suffix(8))
    }
    /// When each connection this run signed in was opened (wall clock: sleep included), for the log.
    private var openedAt: [String: Date] = [:]
    /// When each connection this run signed in was opened (system uptime, like `confirmed`).
    private var openedUptime: [String: TimeInterval] = [:]

    public static var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// A duration for the Connection Log: "0.8 s", "12 s", "3 min 5 s".
    public static func seconds(_ t: TimeInterval) -> String {
        let t = max(t, 0)
        if t < 10 { return String(format: "%.1f s", t) }
        if t < 120 { return "\(Int(t.rounded())) s" }
        if t < 3_600 { return "\(Int(t) / 60) min \(Int(t) % 60) s" }
        return "\(Int(t) / 3_600) h \(Int(t) % 3_600 / 60) min"
    }

    /// How a failed sign-in ended for what it was answered with (`SignInEnd`), from ssh's last
    /// lines: the network's doing or a stop by Tether is not judged by the server.
    /// `killed`: ssh was ended by a signal — by Tether (a late answer, a question left in the
    /// background) when `status` does not say otherwise.
    nonisolated static func end(status: MasterLauncher.Stop?, killed: Bool, networkChanged: Bool, cancelledByUser: Bool,
                                log: [String]) -> SignInEnd {
        let last = log.suffix(3).joined(separator: "\n")
        if networkChanged || cancelledByUser || SSHFailure.isNetwork(last) { return .notJudged }
        switch status {
        case .unanswered: return .unanswered
        case .stopped: return .notJudged
        case nil: if killed { return .notJudged }
        }
        // The jump host's connection (a ProxyCommand through it) ended under it: the target never
        // got as far as judging anything.
        if SSHFailure.isLostSharedConnection(last) { return .notJudged }
        return .failed
    }

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
            let r = await wait(on: first, socket: resolution.socket, for: signIn)
            if isReady(socket) { return .ready(o, reused: true) }
            if first.stopsWaiters { return r }
        }
        // Whoever asked is gone (a tab closed while this was being worked out): no sign-in for it.
        if Task.isCancelled { return .failed("The sign-in was stopped", log: []) }
        // You cancelled this server's sign-in a moment ago: what followed by itself (the next
        // queued transfer, a file window, a forward) does not ask again. A tab's Reconnect, a Retry
        // or a sign-in that worked starts over.
        if let signIn, signIn.sessionID == nil, await !HostLinks.shared.mayAskByItself(target.key) {
            return .failed(Self.cancelledMessage, log: [])
        }
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
                let r = await wait(on: other.login, socket: other.socket, for: signIn)
                if Task.isCancelled { return .failed("The sign-in was stopped", log: []) }
                if isReady(socket) { return .ready(o, reused: true) }
                // Refused or cancelled there: the same question here would only be refused or
                // cancelled again. A failure of the network, or a stop by Tether, lets this one try.
                if other.login.stopsWaiters { return r }
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

    public static let cancelledMessage = "Sign-in cancelled"

    private func establish(_ login: Login, socket: String, target: ConnectionTarget, options: SSHOptions,
                           resolution: Resolution, signIn: SignIn?, chain: Set<String>) async {
        // Already there (made before this run of the app, or a moment ago): use it. A second
        // master would sign in once more and then hang ("ControlSocket … already exists").
        if Self.isSocket(socket) {
            var state = await Self.check(socket, ssh: options.sshBinary)
            // One this run did not open (kept from the last run, the Mac slept since), or one whose
            // master does not answer: is its link still there? Asked once, quickly.
            // Opened by this run before the network changed (or suspected since), kept from the
            // last run (the Mac slept since), or a master that does not answer a local check: is
            // its link still there? The shared check decides (one for every tab waiting): a busy
            // connection is kept, a slow one too, and only one found dead is closed.
            let fromEarlierRun = openedUptime[socket] == nil
            if state == .noAnswer || (state == .alive && (fromEarlierRun || predatesNetworkChange(socket))) {
                let why = fromEarlierRun ? "it was kept from before" : "the network changed, or a tab stopped hearing from it, since it last answered"
                if await verifyLink(socket, ssh: options.sshBinary, deadAfter: staleLinkDeadAfter, why: why) == false {
                    ConnectionLog.shared.notice("The connection already open no longer reaches its server; signing in afresh", host: target.key)
                    state = .gone
                } else if state == .noAnswer {
                    state = .alive
                }
            }
            switch state {
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
        // Nothing is asked for while Tether is locked: the sign-in starts once it is unlocked.
        if !quiet {
            await SignInEvents.shared.mayStart()
            guard !login.waiters.isEmpty, !Task.isCancelled else {
                finish(login, socket: socket, .failed("The sign-in was stopped", log: []))
                return
            }
        }
        let env = quiet ? AskPassBridge.shared.refusingEnvironment(targetKey: target.key, purpose: "connect")
                        : AskPassBridge.shared.environment(targetKey: target.key, purpose: signIn?.purpose ?? "connect",
                                                           mode: "force", sessionID: signIn?.sessionID)
        // Its log sits next to its socket (Tether's private socket folder).
        let launcher = MasterLauncher(directory: URL(fileURLWithPath: socket).deletingLastPathComponent())
        login.launcher = launcher
        if !quiet, let token = env["TETHER_ASKPASS_TOKEN"] { SignInEvents.shared.post(.started(token: token, connection: resolution.identity)) }
        login.token = env["TETHER_ASKPASS_TOKEN"]
        login.environment = env
        login.startedAt = Self.uptime
        publishInterest()
        var args = options.masterArguments(target: target, controlPath: socket, logFile: launcher.logPath, proxyCommand: proxyCommand,
                                           config: resolution.config, device: PlatformCache.shared.isDevice(target.key))
        ConnectionLog.shared.info("Connection settings", .signIn, host: target.key,
                                  detail: Self.describe(arguments: args))
        if quiet { args.insert(contentsOf: ["-o", "BatchMode=yes"], at: 0) }
        ConnectionLog.shared.info((quiet ? "Signing in without asking (background work)" : "Signing in")
                                  + (options.controlSlot > 0 ? " (connection \(options.controlSlot + 1))" : "")
                                  + (proxyCommand != nil ? " through the jump host's connection" : resolution.jump.map { _ in " through a jump host" } ?? ""),
                                  .signIn, host: target.key, detail: signIn.map { "Asked for by: " + $0.purpose })
        let result = await launcher.run(ssh: options.sshBinary, arguments: args, environment: env, onLine: signIn?.onLine)
        AskPassBridge.shared.revoke(environment: env)
        if let token = env["TETHER_ASKPASS_TOKEN"] {
            switch result {
            case .success: SignInEvents.shared.post(.ended(token: token, end: .succeeded))
            case .failure(let message, let log):
                let cancelled = SignInEvents.shared.takeCancelled(token: token)
                let end = Self.end(status: launcher.stop, killed: message == MasterLauncher.stoppedMessage,
                                   networkChanged: login.networkChanged, cancelledByUser: cancelled, log: log)
                if cancelled || end == .failed { login.stopsWaiters = true }
                if cancelled { await HostLinks.shared.noteCancelled(target.key) }
                SignInEvents.shared.post(.ended(token: token, end: end))
            }
        }
        login.launcher = nil
        switch result {
        case .success(let log):
            generations[socket, default: 0] += 1
            targets[socket] = target
            openedAt[socket] = Date()
            openedUptime[socket] = Self.uptime
            jumpSockets[socket] = proxyCommand != nil ? jumpSocket : nil
            let steps = launcher.milestones
            ConnectionLog.shared.notice("Signed in" + (options.controlSlot > 0 ? " (connection \(options.controlSlot + 1))" : "")
                                        + (DiagnosticText.signInMethod(steps).map { " with \($0)" } ?? "")
                                        + " in " + Self.seconds(Self.uptime - login.startedAt),
                                        .signIn, host: target.key, detail: steps.joined(separator: "\n"))
            if let log { logs[socket] = log }
            trimLogsSoon()
            BackgroundSignIn.shared.clear(target.key)
            HostLinks.post(.signedIn(target.key))
            confirmed[socket] = Self.uptime
            // A new connection gets its silent channel again (an earlier one may have given way to
            // a tab when the server's session limit was reached for a moment).
            withoutSentinel.remove(socket)
            sentinelRestarts[socket] = nil
            finish(login, socket: socket, .ready(options, reused: false))
            startSentinel(target: target, options: options)
        case .failure(let launcherMessage, let log):
            // Stopped because the network changed under it: said so, so tabs wait for the next try
            // instead of counting it as a failed sign-in (a few of those end a new tab).
            let message = login.networkChanged && launcherMessage == MasterLauncher.stoppedMessage
                ? SSHFailure.networkChangedDuringSignIn : launcherMessage
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
    /// a single session per connection, or its limit reached for a moment): the channel gives way
    /// on this connection — until it is signed in again.
    /// Whether there was one to give way.
    public func yieldSentinel(for target: ConnectionTarget, options: SSHOptions) async -> Bool {
        guard let socket = await socket(for: target, options: options) else { return false }
        withoutSentinel.insert(socket)
        guard let s = sentinels.removeValue(forKey: socket) else { return false }
        s.end()
        ConnectionLog.shared.notice("The server allows few sessions; the silent channel gave way to a tab", host: target.key)
        return true
    }

    /// The network changed or the Mac woke while sign-ins were under way: those not waiting for the
    /// user are started again (one begun on the old network would hang until TCP gives up).
    public func restartStalledSignIns(startedBefore moment: TimeInterval) {
        for (socket, login) in logins where !login.finished && login.startedAt < moment {
            // One waiting for the user goes on (its question is answered on the new network); a
            // later refusal there is the server's, not the network's.
            guard let launcher = login.launcher, !AskPassBridge.shared.waitsOnUser(environment: login.environment) else { continue }
            login.networkChanged = true
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
    ///
    /// Not after the way out to the network changed: a connection made over the old one keeps its
    /// silent channel running while its link is gone (nothing is sent on it, so nothing notices) —
    /// trusted, every tab would wait on it for minutes while a fresh `ssh` works at once. Such a
    /// connection is checked first (`establish`).
    private func isReady(_ socket: String) -> Bool {
        guard logins[socket] == nil, Self.isSocket(socket), !predatesNetworkChange(socket) else { return false }
        if let s = sentinels[socket], s.process.isRunning { return true }
        if let at = confirmed[socket], Self.uptime - at < 20 { return true }
        return false
    }

    /// Whether `socket` must be checked before it is used again: last known to work before the way
    /// out to the network last changed, or something using it stopped hearing from the server.
    private func predatesNetworkChange(_ socket: String) -> Bool {
        // Only the server answering over the link counts here (`verifyLink`, a sign-in): a local
        // `-O check` (`confirmed`) asks the master process on this Mac, which a dead link keeps alive.
        let known = max(linkVerified[socket] ?? 0, openedUptime[socket] ?? 0)
        if let at = suspected[socket], known < at { return true }
        guard networkChangedAt > 0 else { return false }
        return known < networkChangedAt
    }

    /// When each connection's link last answered (`verifyLink`, or the probe of one kept from the
    /// last run), in system uptime.
    private var linkVerified: [String: TimeInterval] = [:]

    /// When something using each connection last stopped hearing from its server.
    private var suspected: [String: TimeInterval] = [:]

    /// Something using `socket` stopped hearing from its server (a tab's attempt that made no
    /// progress, a tab gone silent): it is not used again before it was checked (`verifyLink`).
    public func suspect(_ socket: String) { suspected[socket] = Self.uptime }

    /// Whether `target`'s shared connection is up (checking it if needed), without signing in.
    public func isUp(_ target: ConnectionTarget, options: SSHOptions) async -> Bool {
        guard options.useControlMaster, !target.isLocal, let r = await resolve(target, options: options) else { return false }
        let socket = r.socket(slot: options.controlSlot)
        if isReady(socket) { return true }
        guard Self.isSocket(socket), logins[socket] == nil else { return false }
        // Made before the network changed (or suspected): only the server answering says it is up.
        if predatesNetworkChange(socket) {
            return await verifyLink(socket, ssh: options.sshBinary, deadAfter: staleLinkDeadAfter, why: "it was asked for after the network changed") == true
        }
        guard case .alive = await Self.check(socket, ssh: options.sshBinary) else { return false }
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
        sentinels.removeValue(forKey: socket)?.end()
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
            ResolvedNames.note(target.key, Self.parseNames(r.output))
            if let destination = Self.parseDestination(r.output) { ResolvedNames.noteServer(target.key, destination) }
            let config = UserConfig.parse(r.output)
            if config.remoteCommand { ResolvedNames.noteRemoteCommand(target.key) }
            var resolution = Resolution(socket: parsed.socket, jump: parsed.jump, route: parsed.route, expires: Self.uptime + 300,
                                        destination: Self.parseDestination(r.output), config: config)
            // Tether names the socket itself, after the server (`identity`): ssh's `%C` also hashes
            // this Mac's own host name, which can change with the network — and then a second
            // connection would sign in next to the first.
            resolution.socket = Self.socketName(for: resolution.identity, in: URL(fileURLWithPath: parsed.socket).deletingLastPathComponent())
            return resolution
        }
        resolving[key] = task
        let resolution = await task.value
        resolving[key] = nil
        if let resolution { resolutions[key] = resolution }
        return resolution
    }

    /// The options of a sign-in worth knowing when a connection drops (keep-alives, timeouts), for
    /// the Connection Log: no host, path or command.
    nonisolated static func describe(arguments args: [String]) -> String {
        var interval: String?, count: String?, timeout: String?, persist: String?
        for (i, a) in args.enumerated() where a == "-o" && i + 1 < args.count {
            let o = args[i + 1]
            if o.hasPrefix("ServerAliveInterval=") { interval = String(o.dropFirst(20)) }
            if o.hasPrefix("ServerAliveCountMax=") { count = String(o.dropFirst(20)) }
            if o.hasPrefix("ConnectTimeout=") { timeout = String(o.dropFirst(15)) }
            if o.hasPrefix("ControlPersist=") { persist = String(o.dropFirst(15)) }
        }
        let keepAlive = interval.map { "keep-alive every \($0) s, given up after \(count ?? "3") unanswered" } ?? "keep-alive as in ssh_config (none by default)"
        return [keepAlive, "connect timeout " + (timeout.map { "\($0) s" } ?? "as in ssh_config"),
                persist.map { "kept \($0) s after its last user" } ?? ""].filter { !$0.isEmpty }.joined(separator: "; ")
    }

    /// The socket for a connection identity, inside `directory`: short (Unix socket paths are limited
    /// to 104 bytes, and ssh adds a temporary suffix while it creates one), the same in every run.
    nonisolated static func socketName(for identity: String, in directory: URL) -> String {
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("c-" + digest).path
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

    /// Where ssh goes, from `ssh -G` output: host name, port, user and ProxyCommand (nil without a
    /// host name). The same server however this Mac is named (see `Resolution.identity`).
    nonisolated static func parseDestination(_ output: String) -> String? {
        var fields: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let name = parts[0].lowercased()
            if ["hostname", "port", "user", "proxycommand"].contains(name), fields[name] == nil { fields[name] = parts[1] }
        }
        guard let host = fields["hostname"] else { return nil }
        return [host, fields["port"] ?? "", fields["user"] ?? "", fields["proxycommand"] ?? ""].joined(separator: "\u{0}")
    }

    /// The names ssh uses for the server and the jump hosts on the way, from `ssh -G` output: the
    /// host name (after `%h`, wildcard and Match blocks), a HostKeyAlias, and each jump host.
    nonisolated static func parseNames(_ output: String) -> (names: Set<String>, hasJumps: Bool) {
        var names: Set<String> = [], jumps = false
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "hostname", "hostkeyalias": names.insert(parts[1])
            case "proxyjump" where parts[1].lowercased() != "none":
                jumps = true
                for hop in parts[1].split(separator: ",") {
                    var name = String(hop).trimmingCharacters(in: .whitespaces)
                    if name.hasPrefix("ssh://") { name.removeFirst(6) }
                    if let at = name.lastIndex(of: "@") { name = String(name[name.index(after: at)...]) }
                    if name.hasPrefix("["), let close = name.firstIndex(of: "]") { name = String(name[name.index(after: name.startIndex)..<close]) }
                    else if name.filter({ $0 == ":" }).count == 1, let colon = name.firstIndex(of: ":") { name = String(name[..<colon]) }
                    if !name.isEmpty { names.insert(name) }
                }
            case "proxycommand" where parts[1].lowercased() != "none":
                jumps = true
            default: break
            }
        }
        return (names, jumps)
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
        let askPass = AskPassBridge.shared.refusingEnvironment(targetKey: target.key, purpose: "sentinel")
        p.environment = ChildEnvironment.base.merging(askPass) { $1 }
        // Checked: with no descriptor left, there is simply no sentinel (instead of a crash).
        guard let input = ChildPipe() else { AskPassBridge.shared.revoke(environment: askPass); return }
        p.standardInput = input.read
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let sentinel = Sentinel(process: p, input: input)
        // Its id only: the process keeps this handler, and the sentinel (which holds the process)
        // must not be kept by it.
        let id = sentinel.id
        p.terminationHandler = { _ in
            AskPassBridge.shared.revoke(environment: askPass)
            Task { await self.sentinelEnded(socket, id: id, target: target, options: options) }
        }
        do { try p.run() } catch {
            p.terminationHandler = nil
            input.closeBoth()
            AskPassBridge.shared.revoke(environment: askPass)
            return
        }
        input.closeChildEnd(output: false)
        if platform.isWindows {
            // The launcher reads its script from the first line; ReadToEnd then waits for the end
            // of input, which never comes while Tether runs.
            try? input.write.write(contentsOf: PowerShell.input("$null=[Console]::In.ReadToEnd()", arguments: []))
        }
        sentinels[socket] = sentinel
    }

    private func sentinelEnded(_ socket: String, id: UUID, target: ConnectionTarget, options: SSHOptions) async {
        // An older channel ending after a new one took its place changes nothing.
        guard sentinels[socket]?.id == id else { return }
        sentinels.removeValue(forKey: socket)?.end()
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
        // Why, in ssh's own words when it said any ("Timeout, server not responding", "Connection
        // reset", "Received disconnect …").
        let words = lastWords(of: socket)
        lastWords[socket] = nil
        ConnectionLog.shared.notice("The connection ended" + lived, host: target.key,
                                    detail: words.isEmpty ? "ssh said nothing about why" : words.joined(separator: "\n"))
        HostLinks.post(.connectionEnded(target.key))
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
            if Self.isSocket(socket) {
                lastWords[socket] = lastWords(of: socket)
                try? handle.truncate(atOffset: 0)
            } else { try? handle.close(); logs[socket] = nil }
        }
        if logs.isEmpty { trimming = false }
        return !logs.isEmpty
    }

    // MARK: Ending

    /// Tether quits: every shared connection ends now (sessions on the servers keep running). Does
    /// not wait — `ssh -O exit` finishes on its own after the app is gone.
    /// `gently`: no new users, but what runs on them goes on until it ends (`ssh -O stop`: plain
    /// shells, transfers and forwards are not cut off — connection sharing was turned off).
    /// Tether quits: sign-ins under way stop, and none starts any more.
    public nonisolated static func stopSigningIn() { MasterLauncher.stopAllForQuit() }

    public nonisolated static func closeAllNow(ssh: String, gently: Bool = false) {
        let dir = AppPaths.controlSocketDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where name != AppPaths.askPassSocket.lastPathComponent {
            let path = dir.appendingPathComponent(name).path
            guard isSocket(path) else { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ssh)
            p.arguments = controlArguments(gently ? .stop : .exit, socket: path)
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
        networkChangedAt = 0
        jumpSockets = [:]
        linkChecks = [:]
        openedUptime = [:]
        suspected = [:]
        linkVerified = [:]
        staleLinkDeadAfter = 10
        signsOfLife = { _, _ in false }
        canJudge = { true }
    }

    private func stopSentinels() {
        for s in sentinels.values { s.end() }
        sentinels = [:]
    }

    // MARK: Link health

    /// When the way out to the network last changed (system uptime; 0: not since launch).
    private var networkChangedAt: TimeInterval = 0
    /// The jump host's connection each connection goes through (its ProxyCommand rides on it).
    private var jumpSockets: [String: String] = [:]
    private struct LinkCheck {
        let startedAt: TimeInterval
        let task: Task<Bool?, Never>
    }
    /// Checks under way, one per connection: everyone asking about it waits for the same verdict.
    private var linkChecks: [String: LinkCheck] = [:]
    /// Signs of life on a connection since a moment (a tab or a transfer received something), and
    /// whether the Mac is online and awake: told by the app (see `configureLinkHealth`).
    private var signsOfLife: @Sendable (String, Date) async -> Bool = { _, _ in false }
    private var canJudge: @Sendable () async -> Bool = { true }

    public func configureLinkHealth(signsOfLife: @escaping @Sendable (String, Date) async -> Bool,
                                    canJudge: @escaping @Sendable () async -> Bool) {
        self.signsOfLife = signsOfLife
        self.canJudge = canJudge
    }

    /// The way out to the network changed (another network, a VPN, waking up): connections made
    /// before it are checked before they are used again (see `isReady`).
    public func noteNetworkChanged() { networkChangedAt = Self.uptime }

    /// How long a connection made before the network changed may stay silent before it counts as
    /// dead, when it is about to be used again (tests use less).
    private var staleLinkDeadAfter: TimeInterval = 10
    public func useStaleLinkDeadAfter(_ seconds: TimeInterval) { staleLinkDeadAfter = seconds }

    /// Whether the connection at `socket` still reaches its server — the one place that decides,
    /// and closes it when it does not. true: alive (or busy); false: it was dead and is closed now;
    /// nil: nothing could be decided (offline, asleep).
    ///
    /// One check per connection at a time; whoever asks meanwhile gets its verdict — unless it
    /// began before the network last changed, when one more check follows it. A check is not
    /// stopped when the one who asked stops waiting (the next network event would otherwise cancel
    /// every check before it decided anything). One that does not answer gets until `deadAfter`
    /// seconds — of the network being there — before it counts as dead; any sign of life on it
    /// meanwhile (a large transfer can hold the check up) keeps it.
    @discardableResult
    public func verifyLink(_ socket: String, ssh: String, deadAfter: TimeInterval, why: String? = nil) async -> Bool? {
        if let running = linkChecks[socket] {
            let verdict = await running.task.value
            if running.startedAt >= networkChangedAt || verdict == false { return verdict }
            if let next = linkChecks[socket], next.startedAt >= networkChangedAt { return await next.task.value }
        }
        let started = Self.uptime
        let deadAfter = max(deadAfter, 0.5)
        let signsOfLife = self.signsOfLife, canJudge = self.canJudge
        let task = Task<Bool?, Never> { [weak self] in
            let since = Date()
            var verdict = await Self.probe(socket, ssh: ssh, timeout: min(8, deadAfter))
            while verdict == nil {
                // Only time with the network counts; without it nothing is decided.
                guard await canJudge() else { break }
                if await signsOfLife(socket, since) { verdict = true; break }
                let left = deadAfter - (Self.uptime - started)
                if left <= 0 { verdict = false; break }
                try? await Task.sleep(for: .seconds(min(5, deadAfter / 3, left)))
                verdict = await Self.probe(socket, ssh: ssh, timeout: min(10, max(1, deadAfter - (Self.uptime - started))))
            }
            await self?.linkJudged(socket, verdict, ssh: ssh, deadAfter: deadAfter, took: Self.uptime - started, why: why)
            return verdict
        }
        linkChecks[socket] = LinkCheck(startedAt: started, task: task)
        let verdict = await task.value
        if linkChecks[socket]?.startedAt == started { linkChecks[socket] = nil }
        return verdict
    }

    private func linkJudged(_ socket: String, _ verdict: Bool?, ssh: String, deadAfter: TimeInterval, took: TimeInterval, why: String?) async {
        let host = targets[socket]?.key
        let asked = why.map { "; checked because " + $0 } ?? ""
        switch verdict {
        case true?:
            confirmed[socket] = Self.uptime
            linkVerified[socket] = Self.uptime
            ConnectionLog.shared.info("Checked a connection: it still reaches its server (\(Self.seconds(took))\(asked))", host: host)
            if let host { HostLinks.post(.linkAlive(host)) }
        case false?:
            ConnectionLog.shared.notice("Closed a connection that no longer reaches its server (no answer in \(Self.seconds(took))\(asked))", host: host)
            await Self.close(socket: socket, ssh: ssh, directory: socketDirectory)
            forget(socket: socket)
            // Through a jump host: the jump host's own connection may be what died (the target
            // behind it can be fine). Checked too, or the next sign-in would hang on it.
            if let jump = jumpSockets.removeValue(forKey: socket), Self.isSocket(jump) {
                Task { await self.verifyLink(jump, ssh: ssh, deadAfter: deadAfter, why: "a connection through it stopped answering") }
            }
            if let host { HostLinks.post(.connectionEnded(host)) }
        case nil:
            break
        }
    }

    // MARK: Sockets

    public enum Check: Sendable { case alive, gone, noAnswer }

    /// `ssh -O check` on the socket itself: the master process answers (says nothing about its link).
    public nonisolated static func check(_ socket: String, ssh: String) async -> Check {
        let r = await ProcessRunner.run(ssh, arguments: controlArguments(.check, socket: socket),
                                        timeout: 5)
        if r.timedOut { return .noAnswer }
        return r.status == 0 ? .alive : .gone
    }

    /// Whether a shared connection still reaches its server: true (alive), false (clearly dead),
    /// nil (no answer in time). It asks the server, over the connection's own link, to forward to a
    /// closed port on itself (`-W 127.0.0.1:9`): nothing runs on the server — no session, no shell,
    /// no login scripts, nothing counted against its session limit —, and the server's refusal,
    /// which comes at once, is the answer (also where forwarding is forbidden, and on network
    /// devices). Only silence means the link is gone. No new login can happen: no config file,
    /// BatchMode, and a ProxyCommand that fails at once if the socket does not answer.
    public nonisolated static func probe(_ socket: String, ssh: String, timeout: TimeInterval) async -> Bool? {
        let r = await ProcessRunner.run(ssh, arguments: [
            "-F", "/dev/null", "-o", "ControlPath=\(socket)", "-o", "ControlMaster=no", "-o", "BatchMode=yes",
            "-o", "ProxyCommand=/usr/bin/false", "-W", "127.0.0.1:9", "tether-master",
        ], input: Data(), timeout: timeout)
        return probeVerdict(status: r.status, stderr: r.errorOutput, timedOut: r.timedOut)
    }

    /// What `probe`'s ssh said, as a verdict (see `probe`).
    nonisolated static func probeVerdict(status: Int32, stderr: String, timedOut: Bool) -> Bool? {
        if timedOut { return nil }
        if isLostConnectionMessage(stderr) { return false }
        // The server answered: it refused the forward (the usual answer), or forwarded somewhere.
        let l = stderr.lowercased()
        if status != 255 || l.contains("forwarding request failed") || l.contains("open failed")
            || l.contains("administratively prohibited") || l.contains("refused by peer") { return true }
        return false
    }

    /// What a client of a shared connection says when the connection is not there: its ProxyCommand
    /// (`/usr/bin/false`) ended at once, or the socket refused it.
    public nonisolated static func isLostConnectionMessage(_ stderr: String) -> Bool { SSHFailure.isLostSharedConnection(stderr) }

    /// What `ssh -O` asks a shared connection's master (answered by the master itself, on this Mac).
    public enum ControlCommand: String, Sendable { case check, exit, stop }

    /// ssh's arguments for `command` on the master at `socket` (no ssh_config read: only the socket counts).
    public nonisolated static func controlArguments(_ command: ControlCommand, socket: String) -> [String] {
        ["-F", "/dev/null", "-o", "ControlPath=\(socket)", "-O", command.rawValue, "tether-master"]
    }

    /// Asks the master at `socket` (`ssh -O`), waiting at most `timeout`.
    @discardableResult
    public nonisolated static func control(_ command: ControlCommand, socket: String, ssh: String, timeout: TimeInterval = 5) async -> ProcessResult {
        await ProcessRunner.run(ssh, arguments: controlArguments(command, socket: socket), timeout: timeout)
    }

    /// Ends a shared connection: `ssh -O exit`; one whose master does not even answer that (stuck)
    /// is ended as a process — found by its own socket in its arguments, so only the master Tether
    /// started for it — and its socket removed (inside Tether's socket folder only).
    public nonisolated static func close(socket: String, ssh: String, directory: URL = AppPaths.controlSocketDirectory) async {
        let r = await ProcessRunner.run(ssh, arguments: controlArguments(.exit, socket: socket),
                                        timeout: 5)
        // It took the request (it is ending), or there was none to ask.
        guard r.timedOut || (r.status != 0 && isSocket(socket)) else { return }
        let stuck = masterProcesses(socket: socket)
        guard !stuck.isEmpty else { return }
        ConnectionLog.shared.notice("A connection did not answer when asked to close; its ssh was ended")
        for pid in stuck { kill(pid, SIGTERM) }
        try? await Task.sleep(for: .seconds(1))
        // Only those found stuck: a new connection started meanwhile on the same socket (a tab
        // reconnecting) is not touched, nor is its socket.
        let now = masterProcesses(socket: socket)
        for pid in now where stuck.contains(pid) { kill(pid, SIGKILL) }
        if now.allSatisfy(stuck.contains) { removeStaleSocket(socket, directory: directory) }
    }

    /// This user's ssh processes that are the master of `socket` (`ControlMaster=yes` and
    /// `ControlPath=<socket>` among their arguments).
    nonisolated static func masterProcesses(socket: String) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        let me = getuid()
        return pids.prefix(Int(n)).filter { pid in
            guard pid > 0 else { return false }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0, info.pbi_uid == me else { return false }
            let args = arguments(of: pid)
            return args.contains("ControlMaster=yes") && args.contains("ControlPath=\(socket)")
        }
    }

    /// A process's arguments (KERN_PROCARGS2); empty when they cannot be read.
    nonisolated static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        // The executable's path, then padding.
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var args: [String] = []
        while i < size, args.count < argc {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            args.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// The server refused one more session on a connection that is alive (sshd's MaxSessions, or a
    /// server that allows a single session): nothing ran.
    public nonisolated static func isSessionRefused(_ message: String) -> Bool { SSHFailure.isSessionRefused(message) }

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
    /// When ssh last wrote to its log or a question was open (system uptime): a sign-in stuck
    /// without a word is ended.
    private var lastProgress = ProcessInfo.processInfo.systemUptime
    private var environment: [String: String] = [:]
    /// A question was answered: the server is checking it now (PAM, LDAP, a push approval).
    private var answered = false
    private var wasAsking = false
    private var answersSeen = 0
    /// Why Tether ended it, if it did.
    private var _stop: Stop?
    /// Silence allowed before any question: a server stuck in the key exchange.
    static let silentLimit: TimeInterval = 45
    /// Silence allowed after an answer: checking it may take a while (and sshd's own login time is
    /// two minutes).
    static let answeredLimit: TimeInterval = 120
    static let stoppedMessage = "The sign-in was stopped"

    enum Stop: Sendable {
        /// Stopped by Tether (a tab closed, Retry, stuck before any question): nothing was judged.
        case stopped
        /// An answer was sent and the server said nothing for `answeredLimit`.
        case unanswered
    }

    var stop: Stop? { lock.withLock { _stop } }

    /// Sign-ins under way now (their ssh not yet backgrounded as the connection's master).
    private static let signingIn = OSAllocatedUnfairLock<[ObjectIdentifier: MasterLauncher]>(initialState: [:])
    nonisolated(unsafe) private static var quitting = false

    /// Tether quits: sign-ins under way stop (a server that never answers would keep their ssh
    /// waiting after Tether is gone), and none starts any more.
    static func stopAllForQuit() {
        quitting = true
        for launcher in signingIn.withLock({ Array($0.values) }) { launcher.cancel() }
    }

    init(directory: URL) {
        logPath = directory.appendingPathComponent("connect-\(UUID().uuidString.prefix(8)).log").path
    }

    /// ssh's steps so far (where it connected, how it signed in, its errors).
    var milestones: [String] { lock.withLock { steps } }

    func cancel() {
        lock.lock(); cancelled = true; if _stop == nil { _stop = .stopped }; let p = process; lock.unlock()
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
        // What the jump host's ssh (its ProxyCommand) says goes to stderr, not to `-E`'s log: kept
        // apart, since a server's banner arrives there too and must not pass for ssh's own words.
        let errorPath = logPath + ".err"
        FileManager.default.createFile(atPath: errorPath, contents: nil, attributes: [.posixPermissions: 0o600])
        let errors = FileHandle(forWritingAtPath: errorPath)
        p.standardError = errors ?? FileHandle.nullDevice
        defer { try? errors?.close(); unlink(errorPath) }
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
            let stop = cancelled || Self.quitting
            if !stop { process = p }
            lock.unlock()
            if stop { p.terminationHandler = nil; cont.resume(returning: -2); return }
            Self.signingIn.withLock { $0[ObjectIdentifier(self)] = self }
            do {
                try p.run()
                AskPassBridge.shared.bindToken(environment, pid: p.processIdentifier)
            } catch { p.terminationHandler = nil; cont.resume(returning: -1) }
        }
        Self.signingIn.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(self)) }
        timer.cancel()
        readLog(onLine)
        lock.withLock { process = nil }
        // The connection keeps writing to this file for as long as it lives: the name goes, and a
        // handle stays so it can be emptied now and then (ssh appends, so it writes on at the start).
        let handle = status == 0 ? FileHandle(forUpdatingAtPath: logPath) : nil
        unlink(logPath)
        if status == 0 { try? handle?.truncate(atOffset: 0); return .success(log: handle) }
        var log = lock.withLock { tail }
        if status == -2 { return .failure(Self.stoppedMessage, log: log) }
        // Only the jump host's words about the server behind it are taken from there.
        let jump = Self.jumpWords(in: (try? String(contentsOfFile: errorPath, encoding: .utf8)) ?? "")
        log += jump
        return .failure(jump.first ?? "ssh exited with code \(status)", log: log)
    }

    /// The jump host's lines saying it could not reach the server, from what ssh printed.
    static func jumpWords(in text: String) -> [String] {
        Array(text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter(SSHFailure.isJumpCannotReachTarget).prefix(4))
    }

    /// A server that answered and then went silent in the middle of signing in (a key exchange or
    /// an authentication step that never finishes): stopped after a while, unless a question waits
    /// for the user — so every tab, file window and transfer waiting for this server is not stuck.
    ///
    /// The time a question is in front of the user does not count: they may take minutes. A
    /// question nobody can see (held back for a tab in the background, waiting for Tether to be
    /// unlocked) counts like silence: the sign-in ends, and is asked again when the user is back.
    /// After an answer the server gets `answeredLimit` to check it.
    private func stopIfStuck() {
        let now = ProcessInfo.processInfo.systemUptime
        let asking = AskPassBridge.shared.isAsking(environment: environment)
        let waitsOnUser = AskPassBridge.shared.waitsOnUser(environment: environment)
        // Answers given at once (remembered, from the keychain) are never seen as a question open.
        let answers = AskPassBridge.shared.answerCount(environment: environment)
        let (idle, limit, afterAnswer): (TimeInterval, TimeInterval, Bool) = lock.withLock {
            if waitsOnUser { lastProgress = now }
            if asking { wasAsking = true }
            else if wasAsking { wasAsking = false; answered = true; lastProgress = now }
            if answers > answersSeen { answersSeen = answers; answered = true; lastProgress = now }
            return (now - lastProgress, answered ? Self.answeredLimit : Self.silentLimit, answered)
        }
        guard !waitsOnUser, idle > limit else { return }
        lock.withLock { if _stop == nil { _stop = afterAnswer ? .unanswered : .stopped } }
        ConnectionLog.shared.problem(afterAnswer ? "The server did not answer the sign-in for \(Int(limit)) s after it was answered; stopped"
                                                 : "A sign-in made no progress for \(Int(limit)) s; stopped",
                                     .signIn, detail: milestones.suffix(6).joined(separator: "\n"))
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

/// What the user's ssh_config sets (from `ssh -G`) that Tether's own options have to respect.
public struct UserConfig: Sendable, Equatable {
    /// ServerAliveInterval / ServerAliveCountMax (0 interval: none set).
    public var serverAliveInterval = 0
    public var serverAliveCountMax = 3
    /// The user set a ConnectTimeout of their own.
    public var setsConnectTimeout = false
    /// A RemoteCommand is set: Tether's own commands replace it (`RemoteCommand=none`).
    public var remoteCommand = false

    public init(serverAliveInterval: Int = 0, serverAliveCountMax: Int = 3, setsConnectTimeout: Bool = false, remoteCommand: Bool = false) {
        self.serverAliveInterval = serverAliveInterval
        self.serverAliveCountMax = serverAliveCountMax
        self.setsConnectTimeout = setsConnectTimeout
        self.remoteCommand = remoteCommand
    }

    static func parse(_ output: String) -> UserConfig {
        var c = UserConfig()
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0].lowercased() {
            case "serveraliveinterval": c.serverAliveInterval = Int(value) ?? 0
            case "serveralivecountmax": c.serverAliveCountMax = Int(value) ?? 3
            case "connecttimeout": c.setsConnectTimeout = value.lowercased() != "none" && Int(value) != nil
            case "remotecommand": c.remoteCommand = value.lowercased() != "none" && !value.isEmpty
            default: break
            }
        }
        return c
    }
}

/// The names ssh itself uses on the way to each target (`SharedConnections.parseNames`), readable
/// from the app at once: a password question naming one of them belongs to that connection.
public enum ResolvedNames {
    nonisolated(unsafe) private static var table: [String: (names: Set<String>, hasJumps: Bool)] = [:]
    nonisolated(unsafe) private static var remoteCommands: Set<String> = []
    private static let lock = NSLock()

    nonisolated(unsafe) private static var servers: [String: String] = [:]

    static func noteServer(_ targetKey: String, _ destination: String) { lock.withLock { servers[targetKey] = destination } }

    /// A short, stable name for the server a target reaches (host name, port, user as ssh works them
    /// out — the same for every alias of it), or nil before it was worked out this run.
    public static func serverID(for targetKey: String) -> String? {
        guard let destination = lock.withLock({ servers[targetKey] }) else { return nil }
        return shortHash(destination)
    }

    /// A short hash naming a server or host without its name (settings keep this, not the name).
    public static func shortHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The target's ssh_config sets a RemoteCommand, which Tether's tabs do not run (told once).
    static func noteRemoteCommand(_ targetKey: String) {
        let new = lock.withLock { remoteCommands.insert(targetKey).inserted }
        if new {
            ConnectionLog.shared.notice("ssh_config sets a RemoteCommand for this host; Tether's tabs run their own instead", host: targetKey)
        }
    }

    /// Whether the target's ssh_config sets a RemoteCommand (that Tether's tabs do not run).
    public static func setsRemoteCommand(_ targetKey: String) -> Bool { lock.withLock { remoteCommands.contains(targetKey) } }

    static func note(_ targetKey: String, _ value: (names: Set<String>, hasJumps: Bool)) {
        lock.withLock { table[targetKey] = value }
    }

    /// What ssh last worked out for the target with this key (nil: not resolved yet this run).
    public static func names(for targetKey: String) -> (names: Set<String>, hasJumps: Bool)? {
        lock.withLock { table[targetKey] }
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

    /// Posted (on the main thread) when who waits for a sign-in changed: a question held back may be
    /// shown now (a file window started waiting for it).
    public static let changed = Notification.Name("TetherSignInInterestChanged")

    static func replace(_ new: [String: Waiting]) {
        let differs = lock.withLock { () -> Bool in
            let differs = table.mapValues(\.sessions) != new.mapValues(\.sessions) || table.mapValues(\.unowned) != new.mapValues(\.unowned)
            table = new
            return differs
        }
        if differs { DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) } }
    }

    /// Who waits for the sign-in that asks with this askpass token (nil: not a shared sign-in).
    public static func waiting(for token: String) -> Waiting? { lock.withLock { table[token] } }
}
