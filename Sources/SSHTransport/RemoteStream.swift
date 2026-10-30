import Foundation
import TetherCore

/// A long-running remote script whose output is delivered in chunks, e.g. a monitoring loop.
/// It rides on the shared ControlMaster connection, so it costs one channel instead of a new
/// ssh process for every refresh.
public final class RemoteStream: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var buffer = Data()
    /// Something arrived from the remote side (so the login itself worked).
    private(set) var receivedAny = false
    private var stopped = false
    private var env: [String: String] = [:]

    /// Called on the main queue for every complete record (text up to and including `separator`).
    public var onRecord: ((String) -> Void)?
    /// Called on the main queue when the stream ends, with stderr text.
    public var onEnd: ((Int32, String) -> Void)?

    private let separator: Data
    /// Windows hosts write CRLF; records are normalized to LF.
    private var normalizeLineEndings = false

    public init(separator: String) {
        self.separator = Data(separator.utf8)
    }

    public func start(executor: RemoteExecutor, script: String, arguments: [String], purpose: String) {
        start(executor: executor, script: RemoteScript(script), platform: .posix, arguments: arguments, purpose: purpose)
    }

    /// Starts the variant of `script` for `platform` (resolve it first with `resolvedPlatform()`).
    /// A remote stream first gets its host's shared connection (it never signs in for quiet work).
    public func start(executor: RemoteExecutor, script remoteScript: RemoteScript, platform: RemotePlatform,
                      arguments: [String], purpose: String) {
        guard !executor.target.isLocal, executor.options.useControlMaster else {
            launch(executor: executor, script: remoteScript, platform: platform, arguments: arguments, purpose: purpose)
            return
        }
        Task {
            switch await executor.prepared(purpose: purpose) {
            case .ready(let ready):
                self.launch(executor: ready, script: remoteScript, platform: platform, arguments: arguments, purpose: purpose)
            case .refused(let result):
                DispatchQueue.main.async { self.onEnd?(result.status, result.errorOutput) }
            }
        }
    }

    private func launch(executor: RemoteExecutor, script remoteScript: RemoteScript, platform: RemotePlatform,
                        arguments: [String], purpose: String) {
        guard !lock.withLock({ stopped }) else { return }
        var stdinData: Data
        if executor.target.isLocal {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-s", "--"] + arguments
            stdinData = Data(remoteScript.posix.utf8)
            stdinData.append(0x0a)
        } else {
            let call: (command: String, input: Data)
            do {
                call = try executor.invocation(remoteScript, arguments: arguments, platform: platform, extra: nil)
            } catch {
                DispatchQueue.main.async { self.onEnd?(127, error.localizedDescription) }
                return
            }
            stdinData = call.input
            normalizeLineEndings = platform.isWindows
            process.executableURL = URL(fileURLWithPath: executor.options.sshBinary)
            process.arguments = executor.options.batchArguments(target: executor.target, remoteCommand: call.command,
                                                                quiet: SSHOptions.isQuietPurpose(purpose))
        }
        env = AskPassBridge.shared.environment(for: executor.target.key, purpose: purpose)
        let quiet = SSHOptions.isQuietPurpose(purpose), local = executor.target.isLocal, key = executor.target.key
        let shared = executor.options.usesSharedConnection
        process.environment = ChildEnvironment.base.merging(env) { $1 }
        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        let errData = ErrorBuffer()
        err.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            // At end of file the handler would otherwise fire continuously.
            if chunk.isEmpty { h.readabilityHandler = nil } else { errData.append(chunk) }
        }
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            self?.consume(chunk)
        }
        process.terminationHandler = { [weak self] p in
            err.fileHandleForReading.readabilityHandler = nil
            let status = p.terminationStatus
            let text = errData.text
            // Only a stream that never delivered anything can have failed to sign in (one that ran
            // for hours and then lost its network did not). Through a shared connection it cannot
            // have tried to sign in at all.
            if quiet, !local, !shared, self?.receivedAny != true { BackgroundSignIn.shared.noteQuietResult(key, status: status, stderr: text) }
            DispatchQueue.main.async {
                guard let self else { return }
                AskPassBridge.shared.revoke(environment: self.env)
                self.onEnd?(status, text)
            }
        }
        do {
            try process.run()
            AskPassBridge.shared.bindToken(env, pid: process.processIdentifier)
            // Stopped while the connection was being prepared: nothing more to do.
            if lock.withLock({ stopped }) { process.terminate(); return }
            let data = stdinData
            // Off the caller's thread (often the main one): a script larger than the pipe's buffer
            // would wait there until the far end reads it, however slow its host is.
            DispatchQueue.global().async {
                try? input.fileHandleForWriting.write(contentsOf: data)
                try? input.fileHandleForWriting.close()
            }
        } catch {
            DispatchQueue.main.async { self.onEnd?(-1, error.localizedDescription) }
        }
    }

    private func consume(_ chunk: Data) {
        lock.lock()
        receivedAny = true
        buffer.append(chunk)
        // Normalized as a whole, so a CR at the end of one chunk still pairs with the LF of the next.
        if normalizeLineEndings { buffer = PowerShell.normalize(buffer) }
        var records: [String] = []
        while let r = buffer.range(of: separator) {
            records.append(String(decoding: buffer[..<r.upperBound], as: UTF8.self))
            buffer.removeSubrange(..<r.upperBound)
        }
        if buffer.count > 4_000_000 { buffer.removeAll() } // never grow without bound
        lock.unlock()
        guard !records.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in records.forEach { self?.onRecord?($0) } }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        if process.isRunning { process.terminate() }
    }

    deinit { stop() }

    private final class ErrorBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock(); if data.count < 65536 { data.append(d) }; lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
}
