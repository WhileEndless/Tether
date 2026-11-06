import Foundation

/// A pipe between Tether and a process it starts, made with `pipe(2)` directly.
///
/// Foundation's `Pipe()` cannot fail: when the system has no descriptor left it hands out nil
/// handles, and the first use crashes. Here the failure is an answer (`nil`), and the command that
/// wanted the pipe fails with `unavailableMessage` instead.
///
/// Both ends are close-on-exec: a process started with this pipe gets its own end through
/// `Process` (which sets it up for the child), and no other child inherits a copy — a copy would keep
/// the pipe from ever reaching its end.
public final class ChildPipe: @unchecked Sendable {
    /// The end Tether reads from (for the child's output) or the child reads from (its input).
    public let read: FileHandle
    /// The end the child writes to (its output) or Tether writes to (its input).
    public let write: FileHandle

    public static let unavailableMessage = "Tether has too many files open to start another command. Close some tabs or restart Tether.\n"

    /// - Parameter make: creates the two descriptors like `pipe(2)` (replaced in tests).
    public init?(make: (UnsafeMutablePointer<Int32>) -> Int32 = { Darwin.pipe($0) }) {
        var fds: [Int32] = [-1, -1]
        let made = fds.withUnsafeMutableBufferPointer { make($0.baseAddress!) }
        guard made == 0, fds[0] >= 0, fds[1] >= 0 else { return nil }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // Writing to a reader that went away gives an error, not SIGPIPE.
        _ = fcntl(fds[1], F_SETNOSIGPIPE, 1)
        read = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        write = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
    }

    /// After the child started: Tether's copy of the child's end is closed, so the pipe reaches its
    /// end when the child (and whatever it left behind) closes its own.
    public func closeChildEnd(output: Bool) {
        try? (output ? write : read).close()
    }

    /// Nothing will use this pipe (the child did not start).
    public func closeBoth() {
        read.readabilityHandler = nil
        try? read.close()
        try? write.close()
    }
}

/// Waits until a finished process's output pipes reach their end — but not longer than a limit: a
/// process it left behind (ssh's shared connection, a background job) may hold them for hours.
/// Unlike a `DispatchGroup`, giving up early leaves nothing unbalanced.
final class OutputDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var open: Int
    private var completion: (@Sendable () -> Void)?

    init(ends: Int) { open = ends }

    /// One pipe reached its end.
    func reachedEnd() {
        lock.lock()
        open -= 1
        let run = open <= 0 ? completion : nil
        if run != nil { completion = nil }
        lock.unlock()
        run?()
    }

    /// Calls `completion` once: when every pipe reached its end, or after `limit`, whichever is first.
    func whenDrained(limit: TimeInterval, _ completion: @escaping @Sendable () -> Void) {
        lock.lock()
        if open <= 0 { lock.unlock(); completion(); return }
        self.completion = completion
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + limit) { [weak self] in self?.giveUp() }
    }

    private func giveUp() {
        lock.lock()
        let run = completion
        completion = nil
        lock.unlock()
        run?()
    }
}

/// Descriptors Tether has open are not handed to the programs it starts in terminals.
public enum ChildDescriptors {
    /// Marks every descriptor above stderr close-on-exec. A terminal's program is started with
    /// fork and exec (SwiftTerm), which pass on every open descriptor: a copy of a pipe's write end
    /// kept by a long-lived shell or tmux would keep that pipe from ever ending. Foundation's
    /// `Process` already passes on only what it is given, so nothing Tether starts relies on
    /// inheriting a descriptor.
    public static func closeOnExecAboveStdio() {
        let fds = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []).compactMap { Int32($0) }
        for fd in fds where fd > 2 {
            let flags = fcntl(fd, F_GETFD)
            if flags >= 0, flags & FD_CLOEXEC == 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
        }
    }
}
