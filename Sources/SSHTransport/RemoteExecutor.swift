import Foundation
import TetherCore

public struct RemoteError: Error, LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Runs non-interactive commands on a remote host, sharing the ControlMaster connection
/// with the terminal sessions so authentication happens only once.
public struct RemoteExecutor: Sendable {
    public var target: ConnectionTarget
    public var options: SSHOptions

    public init(target: ConnectionTarget, options: SSHOptions) {
        self.target = target
        self.options = options
    }

    /// Runs a POSIX shell script on the remote host. The script is sent on stdin so it never
    /// has to survive quoting by the user's login shell (bash, zsh, fish, ...). On Windows hosts
    /// this fails with a clear message; use the `RemoteScript` variant to provide PowerShell.
    public func run(script: String, arguments: [String] = [], stdin extra: Data? = nil,
                    timeout: TimeInterval = 30, purpose: String = "command") async -> ProcessResult {
        await run(RemoteScript(script), arguments: arguments, stdin: extra, timeout: timeout, purpose: purpose)
    }

    /// Runs the variant of `script` for the host's platform (detected once, then cached).
    /// - Parameter stopOnCancel: cancelling the calling task ends the command (see `ProcessRunner`).
    public func run(_ script: RemoteScript, arguments: [String] = [], stdin extra: Data? = nil,
                    timeout: TimeInterval = 30, purpose: String = "command", stopOnCancel: Bool = false) async -> ProcessResult {
        if target.isLocal {
            // Many arguments (thousands of file names): macOS starts no program with more than
            // 4,096. They are set at the top of the script instead, which comes on stdin.
            let many = arguments.count > 512
            var input = Data(((many ? "set -- " + arguments.map(\.shellQuoted).joined(separator: " ") + "\n" : "") + script.posix).utf8)
            if !script.posix.hasSuffix("\n") { input.append(0x0a) }
            if let extra { input.append(extra) }
            return await ProcessRunner.run("/bin/sh", arguments: ["-s", "--"] + (many ? [] : arguments), environment: ChildEnvironment.local,
                                           input: input, timeout: timeout, stopOnCancel: stopOnCancel)
        }
        let quiet = SSHOptions.isQuietPurpose(purpose)
        var attempt = 0
        var result: ProcessResult
        var platform: RemotePlatform
        repeat {
            attempt += 1
            let me: RemoteExecutor
            switch await prepared(purpose: purpose) {
            case .ready(let ready): me = ready
            case .refused(let refusal): return refusal
            }
            platform = await me.resolvedPlatform(quiet: quiet)
            let call: (command: String, input: Data)
            do {
                call = try me.invocation(script, arguments: arguments, platform: platform, extra: extra)
            } catch {
                return ProcessResult(status: 127, stdout: Data(), stderr: Data(error.localizedDescription.utf8), timedOut: false)
            }
            let args = me.options.batchArguments(target: target, remoteCommand: call.command, quiet: quiet)
            let env = AskPassBridge.shared.environment(for: target.key, purpose: purpose)
            // Without sharing, this ssh signs in by itself: as its connection (Signing In Again).
            let ownSignIn = !quiet && !me.options.useControlMaster ? env["TETHER_ASKPASS_TOKEN"] : nil
            if let token = ownSignIn, let identity = await SharedConnections.shared.identity(of: target, options: me.options) {
                SharedConnections.onSignInStarted?(token, identity)
            }
            result = await ProcessRunner.run(options.sshBinary, arguments: args, environment: env, input: call.input, timeout: timeout,
                                             stopOnCancel: stopOnCancel)
            AskPassBridge.shared.revoke(environment: env)
            if let token = ownSignIn {
                SharedConnections.onSignInResult?(token, result.status != 255 && !result.timedOut,
                                                  BackgroundSignIn.reasonFor(stderr: result.errorOutput) == .password)
            }
            if quiet, !me.options.usesSharedConnection { BackgroundSignIn.shared.noteQuietResult(target.key, status: result.status, stderr: result.errorOutput) }
            // The shared connection ended between preparing and running: once more, which signs
            // in again (once for the host) or finds it back.
            guard !(stopOnCancel && Task.isCancelled), await me.lostSharedConnection(result) else { break }
        } while attempt < 2
        if platform.isWindows {
            // PowerShell writes CRLF; the parsers expect LF.
            result.stdout = PowerShell.normalize(result.stdout)
            result.stderr = PowerShell.normalize(result.stderr)
        }
        return result
    }

    /// Like `run` but throws with a readable message on failure.
    public func output(script: String, arguments: [String] = [], timeout: TimeInterval = 30,
                       purpose: String = "command") async throws -> String {
        try await output(RemoteScript(script), arguments: arguments, timeout: timeout, purpose: purpose)
    }

    public func output(_ script: RemoteScript, arguments: [String] = [], timeout: TimeInterval = 30,
                       purpose: String = "command", stopOnCancel: Bool = false) async throws -> String {
        let r = await run(script, arguments: arguments, timeout: timeout, purpose: purpose, stopOnCancel: stopOnCancel)
        if stopOnCancel { try Task.checkCancellation() }
        if r.timedOut { throw RemoteError("The command timed out.") }
        if r.status == 255 {
            throw RemoteError(Self.cleanError(r.errorOutput, fallback: "Could not connect to \(target.displayName)."))
        }
        if r.status != 0 {
            throw RemoteError(Self.cleanError(r.errorOutput, fallback: "Command failed with exit code \(r.status)."))
        }
        return r.output
    }

    public static func cleanError(_ text: String, fallback: String) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        return lines.isEmpty ? fallback : lines.suffix(3).joined(separator: "\n")
    }

    /// Whether this target's shared connection is up (never signs in).
    public func isMasterAlive() async -> Bool {
        await SharedConnections.shared.isUp(target, options: options)
    }

    /// Asks the shared connection to exit, dropping every channel that shares it.
    public func closeMaster() async {
        guard let ready = await SharedConnections.shared.readyOptions(target, options: options), let socket = ready.controlPath else { return }
        _ = await ProcessRunner.run(options.sshBinary, arguments: ["-F", "/dev/null", "-o", "ControlPath=\(socket)", "-O", "exit", "tether-master"], timeout: 5)
        await SharedConnections.shared.forget(socket: socket)
    }

    public enum Prepared: Sendable {
        case ready(RemoteExecutor)
        /// What to report instead of running (no connection, or it needs the user).
        case refused(ProcessResult)
    }

    /// This executor with the shared connection prepared (signing in once for the host when the
    /// purpose may ask), or the result to report instead.
    public func prepared(purpose: String) async -> Prepared {
        let quiet = SSHOptions.isQuietPurpose(purpose)
        guard options.useControlMaster, !target.isLocal else {
            // Without sharing: a login in progress first (its host-key question is answered once).
            await ConnectionGate.shared.waitForTurn(target.key)
            if quiet, !(await backgroundWorkAllowed()) {
                return .refused(ProcessResult(status: 255, stdout: Data(), stderr: Data(backgroundWaitingMessage.utf8), timedOut: false))
            }
            return .ready(self)
        }
        let signIn = quiet ? nil : SharedConnections.SignIn(purpose: purpose)
        switch await SharedConnections.shared.prepare(target, options: options, signIn: signIn) {
        case .ready(let ready, _):
            return .ready(RemoteExecutor(target: target, options: ready))
        case .needsUser(let message):
            return .refused(ProcessResult(status: 255, stdout: Data(), stderr: Data(message.utf8), timedOut: false))
        case .failed(let message, let log):
            let text = ([message] + log.suffix(3)).joined(separator: "\n")
            return .refused(ProcessResult(status: 255, stdout: Data(), stderr: Data(text.utf8), timedOut: false))
        }
    }

    /// ssh failed because the shared connection it was given is gone: its socket was removed, or
    /// nothing answers on it (the client's ProxyCommand then fails at once, so it never signs in).
    func lostSharedConnection(_ result: ProcessResult) async -> Bool {
        guard result.status == 255, !result.timedOut, options.usesSharedConnection, let socket = options.controlPath else { return false }
        if SharedConnections.isSocket(socket) {
            guard SharedConnections.isLostConnectionMessage(result.errorOutput),
                  case .gone = await SharedConnections.check(socket, ssh: options.sshBinary) else { return false }
        }
        await SharedConnections.shared.forget(socket: socket)
        return true
    }
}
