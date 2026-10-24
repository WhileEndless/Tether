import Foundation

/// Runs helper programs for tests without ever waiting forever: output is drained while the
/// program runs (a full pipe cannot block it), and after `timeout` the program and the processes it
/// started are stopped. A stopped tmux server or a hanging tool then fails one test instead of
/// freezing the whole run.
public enum BoundedProcess {
    public struct Result: Sendable {
        public var output: String
        public var errorOutput: String
        public var status: Int32
        public var timedOut: Bool
    }

    @discardableResult
    public static func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil,
                           input: String? = nil, timeout: Double) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment { p.environment = environment }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = Pipe()
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        let collected = Collected()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { collected.append(d, error: false) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { collected.append(d, error: true) }
        }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        guard (try? p.run()) != nil else {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            return Result(output: "", errorOutput: "could not start \(executable)", status: -1, timedOut: false)
        }
        if let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            stopTree(p.processIdentifier)
            _ = done.wait(timeout: .now() + 2)
        }
        // Children that outlived the program would keep the pipes open: stop them too.
        stopChildren(of: p.processIdentifier)
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        collected.append(out.fileHandleForReading.readDataToEndOfFileIfClosed(), error: false)
        collected.append(err.fileHandleForReading.readDataToEndOfFileIfClosed(), error: true)
        return Result(output: collected.text(error: false), errorOutput: collected.text(error: true),
                      status: p.isRunning ? -1 : p.terminationStatus, timedOut: timedOut)
    }

    /// Ends a process and everything it started (children first), with SIGKILL as the last resort.
    public static func stopTree(_ pid: pid_t) {
        guard pid > 1 else { return }
        stopChildren(of: pid)
        kill(pid, SIGTERM)
        usleep(200_000)
        kill(pid, SIGKILL)
    }

    static func stopChildren(of pid: pid_t) {
        guard pid > 1 else { return }
        for child in children(of: pid) {
            stopChildren(of: child)
            kill(child, SIGKILL)
        }
    }

    /// Direct children, from `pgrep -P` (bounded: pgrep itself cannot hang on anything).
    static func children(of pid: pid_t) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }.filter { $0 > 1 }
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func append(_ data: Data, error: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        if error { err.append(data) } else { out.append(data) }
        lock.unlock()
    }

    func text(error: Bool) -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: error ? err : out, as: UTF8.self)
    }
}

private extension FileHandle {
    /// What is left in the pipe once the writers are gone; never blocks on a pipe still open.
    func readDataToEndOfFileIfClosed() -> Data {
        var result = Data()
        let fd = fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            result.append(contentsOf: buffer[0..<n])
        }
        return result
    }
}
