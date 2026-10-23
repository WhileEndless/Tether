import Foundation
import TetherCore

/// A long-running remote script whose output is delivered in chunks, e.g. a monitoring loop.
/// It rides on the shared ControlMaster connection, so it costs one channel instead of a new
/// ssh process for every refresh.
public final class RemoteStream: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var buffer = Data()
    private var stopped = false
    private var env: [String: String] = [:]

    /// Called on the main queue for every complete record (text up to and including `separator`).
    public var onRecord: ((String) -> Void)?
    /// Called on the main queue when the stream ends, with stderr text.
    public var onEnd: ((Int32, String) -> Void)?

    private let separator: Data

    public init(separator: String) {
        self.separator = Data(separator.utf8)
    }

    public func start(executor: RemoteExecutor, script: String, arguments: [String], purpose: String) {
        if executor.target.isLocal {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-s", "--"] + arguments
        } else {
            let remote = (["sh", "-s", "--"] + arguments.map(\.shellQuoted)).joined(separator: " ")
            process.executableURL = URL(fileURLWithPath: executor.options.sshBinary)
            process.arguments = executor.options.batchArguments(target: executor.target, remoteCommand: remote)
        }
        env = AskPassBridge.shared.environment(targetKey: executor.target.key, purpose: purpose)
        process.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
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
            DispatchQueue.main.async {
                guard let self else { return }
                AskPassBridge.shared.revoke(environment: self.env)
                self.onEnd?(status, text)
            }
        }
        do {
            try process.run()
            var data = Data(script.utf8)
            data.append(0x0a)
            // Keep stdin open: closing it would end `sh -s` once the script has been read anyway,
            // but some shells read lazily, so the pipe stays open until stop().
            try input.fileHandleForWriting.write(contentsOf: data)
            try input.fileHandleForWriting.close()
        } catch {
            DispatchQueue.main.async { self.onEnd?(-1, error.localizedDescription) }
        }
    }

    private func consume(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
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
