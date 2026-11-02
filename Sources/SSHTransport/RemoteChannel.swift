import Foundation
import TetherCore

/// One ssh (or scp) a feature runs on a server, set up the same way everywhere: the connection
/// prepared first (a client of the host's shared connection, or — with sharing off — an ssh that
/// signs in by itself), its own askpass token, and its sign-in told about as one (`SignInEvents`),
/// so a password typed for it is remembered and handed on like any other, and one the server
/// refused is never sent again.
public struct RemoteChannel: Sendable {
    public let target: ConnectionTarget
    /// Prepared: a client of the shared connection, or signing in by itself.
    public let options: SSHOptions
    public let purpose: String
    /// This ssh's askpass environment (its token; quiet work refuses every question).
    public let askPass: [String: String]

    public var quiet: Bool { SSHOptions.isQuietPurpose(purpose) }
    /// No shared connection to ride: this ssh signs in by itself, and its sign-in is reported.
    public var signsInItself: Bool { !quiet && !options.usesSharedConnection }
    public var token: String? { askPass["TETHER_ASKPASS_TOKEN"] }

    /// `options` as they are (already prepared, or for this Mac); a new askpass token.
    public init(target: ConnectionTarget, options: SSHOptions, purpose: String) {
        self.target = target
        self.options = options
        self.purpose = purpose
        askPass = AskPassBridge.shared.environment(for: target.key, purpose: purpose)
    }

    public enum Opening: Sendable {
        case ready(RemoteChannel)
        /// What to report instead of running (no connection, or it needs the user).
        case refused(ProcessResult)
    }

    /// Prepares the connection (signing in once for the host when it may ask) and returns the
    /// channel to run on it.
    public static func open(_ target: ConnectionTarget, options: SSHOptions, purpose: String) async -> Opening {
        switch await RemoteExecutor(target: target, options: options).prepared(purpose: purpose) {
        case .ready(let ready): return .ready(RemoteChannel(target: target, options: ready.options, purpose: purpose))
        case .refused(let result): return .refused(result)
        }
    }

    // MARK: Arguments

    /// ssh running `remoteCommand` without a terminal.
    public func command(_ remoteCommand: String, connectTimeout: Int = 15) -> [String] {
        options.batchArguments(target: target, remoteCommand: remoteCommand, connectTimeout: connectTimeout, quiet: quiet)
    }

    /// ssh running a POSIX script (`sh -c`) with these arguments, each quoted for the remote shell.
    public func script(_ script: String, arguments: [String] = [], connectTimeout: Int = 15) -> [String] {
        command(Self.shCommand(script, arguments: arguments), connectTimeout: connectTimeout)
    }

    public static func shCommand(_ script: String, arguments: [String]) -> String {
        (["sh", "-c", script.shellQuoted, "sh"] + arguments.map(\.shellQuoted)).joined(separator: " ")
    }

    /// scp's options and the host to put before a remote path (`host:path`). Devices often speak
    /// only the classic scp protocol, not SFTP (scp's default now).
    public func scp(device: Bool) -> (options: [String], host: String) {
        let (destination, host) = SSHOptions.scpArguments(for: target, jump: !options.usesSharedConnection)
        var args = options.commonOptions() + destination + (device ? ["-O"] : [])
        // Its own sign-in: an unreachable server fails after the same time as anywhere else.
        if !options.usesSharedConnection { args += ["-o", "ConnectTimeout=\(options.connectTimeout)"] }
        return (args, host)
    }

    /// The environment to start it with: Tether's own, plus its askpass token.
    public var processEnvironment: [String: String] {
        ChildEnvironment.base.merging(askPass) { $1 }
    }

    /// Runs a POSIX script on the server without waiting for it (it may outlive Tether: cleanups
    /// at quit). Never asks anything. Through the shared connection when `options` were prepared
    /// for one; otherwise a sign-in of its own that only a key can pass — never `ControlMaster=auto`,
    /// which would leave a connection of its own behind for minutes.
    public static func detached(_ script: String, arguments: [String], target: ConnectionTarget, options: SSHOptions) {
        let p = Process()
        var environment: [String: String] = [:]
        if target.isLocal {
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script, "sh"] + arguments
            p.environment = ChildEnvironment.local
        } else {
            var o = options
            if !o.usesSharedConnection { o.useControlMaster = false }
            environment = AskPassBridge.shared.refusingEnvironment(targetKey: target.key, purpose: "cleanup")
            p.executableURL = URL(fileURLWithPath: o.sshBinary)
            p.arguments = o.commonOptions() + ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
                + o.destination(target) + [shCommand(script, arguments: arguments)]
            p.environment = ChildEnvironment.base.merging(environment) { $1 }
        }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { _ in AskPassBridge.shared.revoke(environment: environment) }
        do { try p.run() } catch { AskPassBridge.shared.revoke(environment: environment) }
    }

    // MARK: Its sign-in

    /// Whether a question of this ssh waits for the user right now (a deadline then waits too).
    public var isAsking: Bool { AskPassBridge.shared.isAsking(environment: askPass) }

    /// For a deadline (`ProcessRunner.run(waitWhile:)`): while this ssh signs in by itself and its
    /// question is in front of the user, its time does not run out (see `waitsOnUser`). nil when it
    /// rides a shared connection.
    public var questionWait: (@Sendable () -> Bool)? {
        guard signsInItself else { return nil }
        let environment = askPass
        return { AskPassBridge.shared.waitsOnUser(environment: environment) }
    }

    /// Before it starts: with no shared connection, its sign-in is told about as one for this
    /// connection (so what it is answered with is remembered, or handed on, for that connection).
    public func began() async {
        guard signsInItself, let token,
              let identity = await SharedConnections.shared.identity(of: target, options: options) else { return }
        SignInEvents.shared.post(.started(token: token, connection: identity))
    }

    /// It ended: its token is let go, and its own sign-in reported (see `SSHFailure.signInEnd`).
    public func ended(status: Int32, stderr: String, stopped: Bool) {
        AskPassBridge.shared.revoke(environment: askPass)
        if signsInItself, let token {
            SignInEvents.shared.post(.ended(token: token, end: SSHFailure.signInEnd(status: status, stderr: stderr, stopped: stopped)))
        }
        if quiet, !options.usesSharedConnection, !target.isLocal {
            BackgroundSignIn.shared.noteQuietResult(target.key, status: status, stderr: stderr)
        }
    }

    /// It ended without an exit status to go by (a transfer: completed, cancelled, or failed with
    /// these words). Only a refusal the server said counts against what it was answered with.
    public func ended(succeeded: Bool, stopped: Bool, words: String) {
        let status: Int32 = succeeded ? 0 : SSHFailure.isRefusedSignIn(words) ? 255 : -1
        ended(status: status, stderr: words, stopped: stopped)
    }
}
