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
    public func run(_ script: RemoteScript, arguments: [String] = [], stdin extra: Data? = nil,
                    timeout: TimeInterval = 30, purpose: String = "command") async -> ProcessResult {
        if target.isLocal {
            var input = Data(script.posix.utf8)
            if !script.posix.hasSuffix("\n") { input.append(0x0a) }
            if let extra { input.append(extra) }
            return await ProcessRunner.run("/bin/sh", arguments: ["-s", "--"] + arguments, input: input, timeout: timeout)
        }
        if options.useControlMaster { await ConnectionGate.shared.waitForTurn(target.key) }
        let platform = await resolvedPlatform()
        let call: (command: String, input: Data)
        do {
            call = try invocation(script, arguments: arguments, platform: platform, extra: extra)
        } catch {
            return ProcessResult(status: 127, stdout: Data(), stderr: Data(error.localizedDescription.utf8), timedOut: false)
        }
        let args = options.batchArguments(target: target, remoteCommand: call.command)
        let env = AskPassBridge.shared.environment(targetKey: target.key, purpose: purpose)
        defer { AskPassBridge.shared.revoke(environment: env) }
        var result = await ProcessRunner.run(options.sshBinary, arguments: args, environment: env, input: call.input, timeout: timeout)
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
                       purpose: String = "command") async throws -> String {
        let r = await run(script, arguments: arguments, timeout: timeout, purpose: purpose)
        if r.timedOut { throw RemoteError("The command timed out.") }
        if r.status == 255 {
            throw RemoteError(Self.cleanError(r.errorOutput, fallback: "Could not connect to \(target.displayName)."))
        }
        if r.status != 0 {
            throw RemoteError(Self.cleanError(r.errorOutput, fallback: "Command failed with exit code \(r.status)."))
        }
        return r.output
    }

    static func cleanError(_ text: String, fallback: String) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        return lines.isEmpty ? fallback : lines.suffix(3).joined(separator: "\n")
    }

    /// Whether a multiplex master is alive for this target.
    public func isMasterAlive() async -> Bool {
        guard options.useControlMaster, !target.isLocal else { return false }
        let r = await ProcessRunner.run(options.sshBinary, arguments: options.controlArguments(target: target, command: "check"), timeout: 5)
        return r.status == 0
    }

    /// Asks the multiplex master to exit, dropping every channel that shares it.
    public func closeMaster() async {
        guard options.useControlMaster, !target.isLocal else { return }
        _ = await ProcessRunner.run(options.sshBinary, arguments: options.controlArguments(target: target, command: "exit"), timeout: 5)
    }
}
