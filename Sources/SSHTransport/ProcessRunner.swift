import Foundation

public struct ProcessResult: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public var output: String { String(decoding: stdout, as: UTF8.self) }
    public var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { status == 0 && !timedOut }
}

/// Runs a process without a TTY, collecting output asynchronously.
public enum ProcessRunner {
    /// Thread-safe accumulator for one process run.
    private final class Collector: @unchecked Sendable {
        let lock = NSLock()
        var out = Data()
        var err = Data()
        var finished = false
        var timedOut = false
        let group = DispatchGroup()

        func append(_ data: Data, isError: Bool) {
            lock.lock(); defer { lock.unlock() }
            if isError { err.append(data) } else { out.append(data) }
        }

        /// Returns true only for the first caller.
        func markFinished() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if finished { return false }
            finished = true
            return true
        }

        func result(status: Int32) -> ProcessResult {
            lock.lock(); defer { lock.unlock() }
            return ProcessResult(status: status, stdout: out, stderr: err, timedOut: timedOut)
        }
    }

    public static func run(_ executable: String, arguments: [String], environment: [String: String]? = nil,
                           input: Data? = nil, timeout: TimeInterval = 30) async -> ProcessResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ProcessResult, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let environment {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            }
            let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = input == nil ? FileHandle.nullDevice : inPipe

            let c = Collector()
            for (pipe, isErr) in [(outPipe, false), (errPipe, true)] {
                c.group.enter()
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let chunk = h.availableData
                    if chunk.isEmpty {
                        h.readabilityHandler = nil
                        c.group.leave()
                    } else {
                        c.append(chunk, isError: isErr)
                    }
                }
            }

            process.terminationHandler = { p in
                guard c.markFinished() else { return }
                let status = p.terminationStatus
                // Wait briefly for pipes to drain; a backgrounded ControlMaster may hold them open.
                DispatchQueue.global().async {
                    _ = c.group.wait(timeout: .now() + 1.5)
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(returning: c.result(status: status))
                }
            }
            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: ProcessResult(status: -1, stdout: Data(),
                                                     stderr: Data(error.localizedDescription.utf8), timedOut: false))
                return
            }
            if let input {
                DispatchQueue.global().async {
                    try? inPipe.fileHandleForWriting.write(contentsOf: input)
                    try? inPipe.fileHandleForWriting.close()
                }
            }
            if timeout > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        c.lock.lock(); c.timedOut = true; c.lock.unlock()
                        process.terminate()
                    }
                }
            }
        }
    }
}
