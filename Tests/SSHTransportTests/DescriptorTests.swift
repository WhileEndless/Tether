import Foundation
import Testing
import TetherCore
@testable import SSHTransport

/// Commands and streams give back every descriptor they used, whichever way they end; running out
/// of descriptors makes a command fail instead of crashing the app.
@Suite(.serialized) struct DescriptorTests {
    private static func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
    }

    /// Other suites run at the same time and open files of their own: a leak shows as dozens of
    /// descriptors left over, far more than what they hold for a moment.
    private static let slack = 24

    @Test func commandsGiveBackTheirPipesHoweverTheyEnd() async throws {
        let before = Self.openDescriptors()
        for _ in 0..<30 {
            let r = await ProcessRunner.run("/bin/sh", arguments: ["-c", "echo out; echo err >&2"], timeout: 10)
            #expect(r.output == "out\n" && r.errorOutput == "err\n")
        }
        for _ in 0..<30 {
            let r = await ProcessRunner.run("/bin/sh", arguments: ["-c", "cat"], input: Data("in".utf8), timeout: 10)
            #expect(r.output == "in")
        }
        for _ in 0..<5 {
            // More than a pipe's buffer, in both directions.
            let big = Data(repeating: 0x61, count: 300_000)
            let r = await ProcessRunner.run("/bin/sh", arguments: ["-c", "cat"], input: big, timeout: 20)
            #expect(r.stdout.count == big.count)
        }
        for _ in 0..<5 {
            let r = await ProcessRunner.run("/bin/sh", arguments: ["-c", "yes"], timeout: 10, maxOutput: 10_000)
            #expect(!r.succeeded)
        }
        // A child that ended, leaving one behind that holds its output: answered after a short wait.
        for _ in 0..<2 {
            let start = Date()
            let r = await ProcessRunner.run("/bin/sh", arguments: ["-c", "sleep 2 & echo started"], timeout: 10)
            #expect(r.output == "started\n")
            #expect(Date().timeIntervalSince(start) < 2)
        }
        // Over its time: stopped.
        let slow = await ProcessRunner.run("/bin/sh", arguments: ["-c", "exec sleep 5"], timeout: 0.3)
        #expect(slow.timedOut)
        // Ignoring SIGTERM: killed, and the caller answered all the same.
        let stubborn = await ProcessRunner.run("/bin/sh", arguments: ["-c", "trap '' TERM; exec sleep 5"], timeout: 0.3)
        #expect(stubborn.status == -9)
        // Cancelled.
        let task = Task { await ProcessRunner.run("/bin/sh", arguments: ["-c", "exec sleep 5"], timeout: 10, stopOnCancel: true) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        _ = await task.value

        try await Task.sleep(for: .seconds(2.5))     // the one left behind ends; its pipe with it
        let after = Self.openDescriptors()
        #expect(after - before < Self.slack, "descriptors before \(before), after \(after)")
    }

    /// The owners keep closures that hold the stream; once it ended, it lets go of them, so it is
    /// freed with its process and pipes (they were kept for ever, a few for every restart).
    @Test func aStreamThatEndedIsFreed() async throws {
        let before = Self.openDescriptors()
        final class Box: @unchecked Sendable { weak var stream: RemoteStream? }
        let box = Box()
        for _ in 0..<20 {
            let (text, _) = await withCheckedContinuation { (cont: CheckedContinuation<(String, Int32), Never>) in
                let s = RemoteStream(separator: "\n")
                var lines = ""
                s.onRecord = { lines += $0 }
                // Strongly, as an owner might: the stream must still be freed.
                s.onEnd = { status, _ in _ = s; cont.resume(returning: (lines, status)) }
                s.start(executor: RemoteExecutor(target: .local, options: SSHOptions()), script: "echo one; echo two",
                        arguments: [], purpose: "monitor")
                box.stream = s
            }
            #expect(text == "one\ntwo\n")
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(box.stream == nil)
        let after = Self.openDescriptors()
        #expect(after - before < Self.slack, "descriptors before \(before), after \(after)")
    }

    @Test func aStoppedStreamEndsAndIsFreed() async throws {
        final class Box: @unchecked Sendable { weak var stream: RemoteStream? }
        let box = Box()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let s = RemoteStream(separator: "\n")
            s.onRecord = { _ in s.stop() }
            s.onEnd = { _, _ in cont.resume() }
            s.start(executor: RemoteExecutor(target: .local, options: SSHOptions()), script: "while :; do echo tick; sleep 0.1; done",
                    arguments: [], purpose: "monitor")
            box.stream = s
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(box.stream == nil)
    }

    @Test func noDescriptorLeftIsAnAnswerNotACrash() {
        #expect(ChildPipe(make: { _ in errno = EMFILE; return -1 }) == nil)
        guard let pipe = ChildPipe() else { Issue.record("no pipe made"); return }
        // Close-on-exec: no other child inherits a copy.
        #expect(fcntl(pipe.read.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0)
        #expect(fcntl(pipe.write.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0)
    }

    @Test func descriptorsAreNotHandedToTerminalPrograms() {
        var fds: [Int32] = [-1, -1]
        #expect(pipe(&fds) == 0)
        defer { fds.forEach { close($0) } }
        ChildDescriptors.closeOnExecAboveStdio()
        for fd in fds { #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0) }
    }

    /// The askpass listener keeps answering after a passing error (out of descriptors); it ended for
    /// good before, and every later ssh question went unanswered.
    @Test func askPassListenerOutlivesPassingErrors() {
        #expect(AskPassBridge.acceptFailure(EMFILE) == .retryLater)
        #expect(AskPassBridge.acceptFailure(ENFILE) == .retryLater)
        #expect(AskPassBridge.acceptFailure(ENOBUFS) == .retryLater)
        #expect(AskPassBridge.acceptFailure(ECONNABORTED) == .retryNow)
        #expect(AskPassBridge.acceptFailure(EINTR) == .retryNow)
        #expect(AskPassBridge.acceptFailure(EBADF) == .stop)
    }
}
