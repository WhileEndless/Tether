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
        /// More output came than the caller allows: the rest is not kept, and the process is stopped.
        var overflowed = false
        let maxOutput: Int

        init(maxOutput: Int) { self.maxOutput = maxOutput }

        /// Keeps a chunk of output; false once the output went over the limit (the process should
        /// stop: whatever it sends, a server cannot fill Tether's memory). Messages on stderr are
        /// kept up to a limit of their own and never stop it.
        func append(_ data: Data, isError: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if isError {
                if err.count < ProcessRunner.maxErrorOutput { err.append(data.prefix(ProcessRunner.maxErrorOutput - err.count)) }
                return true
            }
            guard !overflowed else { return false }
            guard out.count + data.count <= maxOutput else { overflowed = true; return false }
            out.append(data)
            return true
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
            guard overflowed else { return ProcessResult(status: status, stdout: out, stderr: err, timedOut: timedOut) }
            // Cut short: never taken for a complete answer.
            return ProcessResult(status: -1, stdout: out, stderr: Data("The command printed more than Tether reads (\(maxOutput / 1024) KB); it was stopped.\n".utf8) + err,
                                 timedOut: false)
        }
    }

    /// - Parameter stopOnCancel: cancelling the calling task ends the process (a search the user
    ///   stopped); otherwise it runs to its end or its timeout.
    /// - Parameter waitWhile: the timeout does not end it while this holds (a password question of
    ///   its own is open: the user may take minutes); checked again every second.
    /// - Parameter maxOutput: bytes of output kept at most; a process that prints more is stopped
    ///   and fails (status -1).
    public static func run(_ executable: String, arguments: [String], environment: [String: String]? = nil,
                           input: Data? = nil, timeout: TimeInterval = 30, stopOnCancel: Bool = false,
                           waitWhile: (@Sendable () -> Bool)? = nil, maxOutput: Int = defaultMaxOutput) async -> ProcessResult {
        let process = Process()
        let box = ProcessBox(process)
        return await withTaskCancellationHandler {
            await run(process, executable, arguments: arguments, environment: environment, input: input, timeout: timeout,
                      stopOnCancel: stopOnCancel, waitWhile: waitWhile, maxOutput: maxOutput)
        } onCancel: {
            if stopOnCancel { box.stop() }
        }
    }

    /// Output kept from one command unless its caller says otherwise: far more than any listing or
    /// probe prints, and a bound on what a server (or a broken script) can make Tether hold.
    public static let defaultMaxOutput = 128 << 20
    static let maxErrorOutput = 1 << 20

    // MARK: Running now

    private static let runningLock = NSLock()
    nonisolated(unsafe) private static var running: [ObjectIdentifier: Process] = [:]

    /// Ends every command started here that still runs (a listing, a check, a transfer's helper):
    /// when Tether quits they have nobody to answer, and a hanging one would stay behind. What is
    /// meant to outlive Tether (ending a private session on the server, closing shared connections)
    /// is started elsewhere and not touched.
    public static func terminateAll() {
        let now = runningLock.withLock { quitting = true; return Array(running.values) }
        for p in now where p.isRunning { p.terminate() }
    }
    /// Set by `terminateAll`: what is asked for after that is not started.
    nonisolated(unsafe) private static var quitting = false

    /// A run's output pipes, until it ends.
    private final class PipeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var pipes: [ChildPipe]
        init(_ pipes: [ChildPipe]) { self.pipes = pipes }
        func take() -> [ChildPipe] { lock.withLock { defer { pipes = [] }; return pipes } }
    }

    private final class ProcessBox: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
        func stop() { if process.isRunning { process.terminate() } }
    }

    private static func run(_ process: Process, _ executable: String, arguments: [String], environment: [String: String]?,
                            input: Data?, timeout: TimeInterval, stopOnCancel: Bool,
                            waitWhile: (@Sendable () -> Bool)?, maxOutput: Int) async -> ProcessResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ProcessResult, Never>) in
            func refuse(_ message: String) {
                cont.resume(returning: ProcessResult(status: -1, stdout: Data(), stderr: Data(message.utf8), timedOut: false))
            }
            // Checked pipes: with no descriptor left, the command fails instead of crashing the app.
            guard let outPipe = ChildPipe(), let errPipe = ChildPipe() else { return refuse(ChildPipe.unavailableMessage) }
            var inPipe: ChildPipe?
            if input != nil {
                guard let p = ChildPipe() else { return refuse(ChildPipe.unavailableMessage) }
                inPipe = p
            }
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ChildEnvironment.base.merging(environment ?? [:]) { $1 }
            process.standardOutput = outPipe.write
            process.standardError = errPipe.write
            process.standardInput = inPipe?.read ?? FileHandle.nullDevice

            let c = Collector(maxOutput: max(maxOutput, 0))
            let drain = OutputDrain(ends: 2)
            // Let go of when the run ends: closures that outlive it (its timeout) keep only this box.
            let ends = PipeBox([outPipe, errPipe])
            /// The one way out, whichever path ends the run first: the handlers go (nothing keeps the
            /// pipes alive after that, so they close), the process lets go of this run, and the caller
            /// is answered.
            @Sendable func finish(status: Int32) {
                for p in ends.take() { p.read.readabilityHandler = nil }
                process.terminationHandler = nil
                runningLock.withLock { _ = running.removeValue(forKey: ObjectIdentifier(process)) }
                cont.resume(returning: c.result(status: status))
            }

            process.terminationHandler = { p in
                runningLock.withLock { _ = running.removeValue(forKey: ObjectIdentifier(p)) }
                guard c.markFinished() else { return }
                let status = p.terminationStatus
                // What is still in the pipes is read first; a backgrounded ControlMaster may hold them
                // open, so not for long.
                drain.whenDrained(limit: 1.5) { finish(status: status) }
            }
            let refused = runningLock.withLock { () -> Bool in
                if quitting { return true }
                running[ObjectIdentifier(process)] = process
                return false
            }
            if refused {
                process.terminationHandler = nil
                ends.take().forEach { $0.closeBoth() }
                inPipe?.closeBoth()
                return refuse("Tether is quitting")
            }
            do {
                try process.run()
            } catch {
                runningLock.withLock { _ = running.removeValue(forKey: ObjectIdentifier(process)) }
                process.terminationHandler = nil
                ends.take().forEach { $0.closeBoth() }
                inPipe?.closeBoth()
                return refuse(error.localizedDescription)
            }
            // The child has its ends now; Tether's copies would keep the pipes from ending.
            outPipe.closeChildEnd(output: true)
            errPipe.closeChildEnd(output: true)
            inPipe?.closeChildEnd(output: false)
            for (pipe, isErr) in [(outPipe, false), (errPipe, true)] {
                pipe.read.readabilityHandler = { [weak process] h in
                    let chunk = h.availableData
                    if chunk.isEmpty {
                        h.readabilityHandler = nil
                        drain.reachedEnd()
                    } else if !c.append(chunk, isError: isErr), let process, process.isRunning {
                        // Read on (and dropped) until it ends, so it is never stuck writing to a full pipe.
                        process.terminate()
                    }
                }
            }
            if let environment { AskPassBridge.shared.bindToken(environment, pid: process.processIdentifier) }
            // Cancelled before it started: the handler found nothing running to stop.
            if stopOnCancel, Task.isCancelled { process.terminate() }
            if let input, let inPipe {
                DispatchQueue.global().async {
                    // A child that ended without reading it: an error (EPIPE), not a signal.
                    try? inPipe.write.write(contentsOf: input)
                    try? inPipe.write.close()
                }
            }
            if timeout > 0 {
                // Weakly: a command that ended long before its timeout must not be kept (with its
                // pipes) until then.
                @Sendable func expire(_ process: Process?) {
                    guard let process, process.isRunning else { return }
                    if let waitWhile, waitWhile() {
                        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak process] in expire(process) }
                        return
                    }
                    c.lock.lock(); c.timedOut = true; c.lock.unlock()
                    process.terminate()
                    // A process that ignores SIGTERM (stopped, or trapping it) must not keep its caller
                    // waiting: killed, and the caller answered, whatever happens to it.
                    let pid = process.processIdentifier
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak process] in
                        guard let process, process.isRunning else { return }
                        if pid > 1 { kill(pid, SIGKILL) }
                        guard c.markFinished() else { return }
                        finish(status: -9)
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in expire(process) }
            }
        }
    }
}

/// The environment for programs Tether starts: the app's own, without what would tie them to a
/// terminal multiplexer the app happens to run inside. With `$TMUX` set, tmux talks to that outer
/// server — local sessions and scripts would list, create or end sessions there.
public enum ChildEnvironment {
    public static let removed = ["TMUX", "TMUX_PANE"]

    public static var base: [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in removed { env[key] = nil }
        return env
    }

    /// Folders where package managers put tools such as tmux. An app started from the Dock or
    /// Finder gets launchd's minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) without them.
    public static let toolFolders = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    /// For programs run on this Mac (local terminals, local probes): `base` with the tool folders
    /// in PATH, so this Mac's tmux is found like on a server.
    public static var local: [String: String] {
        var env = base
        env["PATH"] = withToolFolders(env["PATH"])
        return env
    }

    static func withToolFolders(_ path: String?) -> String {
        let current = (path ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        return (toolFolders.filter { !current.contains($0) } + current).joined(separator: ":")
    }
}
