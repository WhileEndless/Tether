import Foundation
import Testing
import TetherCore
@testable import SessionKit

/// Collects everything the session displays.
@MainActor
final class RecordingSink: TerminalSink {
    var output: [UInt8] = []
    var text: String { String(decoding: output, as: UTF8.self) }
    func feed(_ bytes: ArraySlice<UInt8>) { output.append(contentsOf: bytes) }
    var cellSize: (cols: Int, rows: Int) { (100, 30) }
}

/// End-to-end tests that run the real bootstrap and tmux control mode locally.
/// A fake `ssh` executes the remote command with `sh` on this machine, using a private tmux server.
@MainActor
@Suite(.serialized) struct LocalSessionTests {
    let dir: URL
    let fakeSSH: URL

    init() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tether-it-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fakeSSH = dir.appendingPathComponent("ssh")
        let script = """
        #!/bin/sh
        # Fake ssh: run the last argument as the remote command on this machine.
        for a in "$@"; do case "$a" in -O) exit 1;; esac; done
        for last in "$@"; do :; done
        export TMUX_TMPDIR="\(dir.path)"
        unset TMUX
        export SHELL=/bin/sh
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        exec /bin/sh -c "$last"
        """
        try script.write(to: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)
    }

    func config() -> SessionConfiguration {
        var s = AppSettings()
        s.sshBinary = fakeSSH.path
        s.useControlMaster = false
        s.recordingEnabled = false
        s.autoReconnect = false
        return SessionConfiguration(settings: s)
    }

    /// Runs tmux against this suite's private server (never the user's own tmux).
    @discardableResult
    func tmux(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["tmux"] + args
        var env = ProcessInfo.processInfo.environment
        env["TMUX_TMPDIR"] = dir.path
        env["TMUX"] = nil
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func wait(_ what: String, timeout: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { Issue.record("Timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    nonisolated static var hasTmux: Bool {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @Test func plainShellRoundTrip() async throws {
        let cfg = config()
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("local"), persistence: .off)) { cfg }
        let sink = RecordingSink()
        session.attach(sink: sink)
        session.start()
        try await wait("online") { session.phase.isOnline }
        #expect(session.persistence == .plain)
        session.send(Array("echo tether-$((40+2))\r".utf8)[...])
        try await wait("echo") { sink.text.contains("tether-42") }
        session.send(Array("exit 3\r".utf8)[...])
        try await wait("dead") { session.phase.isDead }
        #expect(!sink.text.contains("7770;"), "bootstrap marker must not reach the terminal")
    }

    @Test(.enabled(if: LocalSessionTests.hasTmux)) func tmuxControlModePersistsAcrossReattach() async throws {
        let cfg = config()
        let descriptor = SessionDescriptor(target: .alias("local"), persistence: .tmux)
        let first = TerminalSession(descriptor: descriptor) { cfg }
        let sink1 = RecordingSink()
        first.attach(sink: sink1)
        first.start()
        try await wait("tmux online") { first.phase.isOnline }
        #expect(first.persistence == .tmux)
        first.send(Array("export X=persist; echo marker-$((6*7))\r".utf8)[...])
        try await wait("tmux echo") { sink1.text.contains("marker-42") }
        #expect(!sink1.text.contains("%output"), "control mode protocol must not leak into the terminal")

        // Simulate the app quitting: drop the client, keep the remote session.
        first.abandon()
        try await Task.sleep(for: .milliseconds(500))

        // Re-attach like a restored tab and check the shell state survived.
        let second = TerminalSession(descriptor: descriptor) { cfg }
        let sink2 = RecordingSink()
        second.attach(sink: sink2)
        second.restore(previous: .tmux)
        try await wait("re-attached") { second.phase.isOnline }
        #expect(sink2.text.contains("marker-42"), "screen content should be restored on re-attach")
        second.send(Array("echo again-$X\r".utf8)[...])
        try await wait("state survived") { sink2.text.contains("again-persist") }

        second.close(killRemote: true)
        try await Task.sleep(for: .milliseconds(800))

        // The remote session is gone now; a re-attach must report it dead.
        let third = TerminalSession(descriptor: descriptor) { cfg }
        third.attach(sink: RecordingSink())
        var archived = false
        third.onDeath = { _ in archived = true }
        third.restore(previous: .tmux)
        try await wait("gone") { third.phase.isDead }
        #expect(archived)
        tmux(["kill-server"])
    }

    @Test(.enabled(if: LocalSessionTests.hasTmux)) func detectsStalledServerAndReattaches() async throws {
        var settings = AppSettings()
        settings.sshBinary = fakeSSH.path
        settings.useControlMaster = false
        settings.recordingEnabled = false
        settings.autoReconnect = true
        settings.reconnectBaseDelay = 1
        settings.stallTimeout = 3
        let cfg = SessionConfiguration(settings: settings)
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("local"), persistence: .tmux)) { cfg }
        let sink = RecordingSink()
        session.attach(sink: sink)
        session.start()
        try await wait("online") { session.phase.isOnline }
        try await wait("latency") { session.latency.last != nil }
        #expect(session.latency.median ?? 1 < 0.5)

        let pid = tmux(["display-message", "-p", "#{pid}"])
        #expect(!pid.isEmpty)
        kill(pid_t(pid)!, SIGSTOP)
        let stoppedAt = Date()
        try await wait("waiting", timeout: 10) { if case .waiting = session.phase { true } else { false } }
        #expect(Date().timeIntervalSince(stoppedAt) < 8, "stall should be detected within a few seconds")
        kill(pid_t(pid)!, SIGCONT)
        try await wait("back online", timeout: 15) { session.phase.isOnline }
        session.close(killRemote: true)
        try await Task.sleep(for: .milliseconds(600))
        tmux(["kill-server"])
    }

    @Test func localTerminalRunsWithoutSSH() async throws {
        var settings = AppSettings()
        settings.sshBinary = "/nonexistent/ssh"   // must not be used for local sessions
        settings.recordingEnabled = false
        let cfg = SessionConfiguration(settings: settings)
        let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) { cfg }
        let sink = RecordingSink()
        session.attach(sink: sink)
        session.start()
        try await wait("online") { session.phase.isOnline }
        session.send(Array("echo local-$((20+3))\r".utf8)[...])
        try await wait("echo") { sink.text.contains("local-23") }
        session.close(killRemote: true)
    }

    @Test(.enabled(if: LocalSessionTests.hasTmux)) func suspendKeepsRemoteSessionAndResumes() async throws {
        let cfg = config()
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("local"), persistence: .tmux)) { cfg }
        let sink = RecordingSink()
        session.attach(sink: sink)
        session.start()
        try await wait("online") { session.phase.isOnline }
        session.send(Array("export K=kept\r".utf8)[...])
        try await Task.sleep(for: .milliseconds(400))
        #expect(session.canSuspend)
        session.suspend()
        #expect(session.phase.isSuspended)
        try await Task.sleep(for: .milliseconds(800))
        #expect(!tmux(["has-session", "-t", session.descriptor.remoteSessionName]).contains("can't find"))
        #expect(tmux(["list-sessions", "-F", "#{session_name}"]).contains(session.descriptor.remoteSessionName))
        session.send(Array("x".utf8)[...])   // ignored while suspended
        session.resume()
        try await wait("resumed") { session.phase.isOnline }
        session.send(Array("echo again-$K\r".utf8)[...])
        try await wait("state kept") { sink.text.contains("again-kept") }
        session.close(killRemote: true)
        try await Task.sleep(for: .milliseconds(600))
        tmux(["kill-server"])
    }

    @Test func connectsThroughMasterStepAndClearsProgress() async throws {
        var settings = AppSettings()
        settings.sshBinary = fakeSSH.path
        settings.useControlMaster = true      // exercises the separate "open shared connection" step
        settings.recordingEnabled = false
        settings.autoReconnect = false
        let cfg = SessionConfiguration(settings: settings)
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("local"), persistence: .off)) { cfg }
        let sink = RecordingSink()
        session.attach(sink: sink)
        session.start()
        #expect(session.progress != nil)
        try await wait("online") { session.phase.isOnline }
        #expect(session.progress == nil, "progress is cleared once online")
        session.send(Array("echo via-master\r".utf8)[...])
        try await wait("echo") { sink.text.contains("via-master") }
        session.close(killRemote: true)
    }

    @Test func retryAfterFailedConnectionReusesTheSession() async throws {
        // A fake ssh that refuses while a "down" file exists.
        let down = dir.appendingPathComponent("down")
        FileManager.default.createFile(atPath: down.path, contents: Data())
        let flaky = dir.appendingPathComponent("flaky-ssh")
        try """
        #!/bin/sh
        if [ -e "\(down.path)" ]; then echo "ssh: connect to host example.invalid port 22: Connection refused" >&2; exit 255; fi
        exec "\(fakeSSH.path)" "$@"
        """.write(to: flaky, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: flaky.path)
        var settings = AppSettings()
        settings.sshBinary = flaky.path
        settings.useControlMaster = false
        settings.recordingEnabled = false
        settings.reconnectBaseDelay = 0.5      // gives up after a few quick attempts
        let cfg = SessionConfiguration(settings: settings)
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("down-host"), persistence: .off)) { cfg }
        let sink = RecordingSink()
        session.attach(sink: sink)
        session.start()
        try await wait("gave up") { session.phase.isDead }
        #expect(session.endedByConnectionFailure)
        let id = session.id
        try FileManager.default.removeItem(at: down)
        session.retryAfterFailure()
        try await wait("online after retry") { session.phase.isOnline }
        #expect(session.id == id && !session.endedByConnectionFailure)
        session.close(killRemote: true)
    }

    @Test func manyTabsToOneHostLogInOneAtATime() async throws {
        // A fake ssh whose login step (the shared-connection setup) takes a moment and logs when it runs.
        let log = dir.appendingPathComponent("logins.log")
        let slow = dir.appendingPathComponent("slow-ssh")
        try """
        #!/bin/sh
        for a in "$@"; do if [ "$a" = "-E" ]; then
          echo "start $(date +%s.%N 2>/dev/null || date +%s)" >> "\(log.path)"; sleep 0.3
          echo "end $(date +%s.%N 2>/dev/null || date +%s)" >> "\(log.path)"; exit 0
        fi; done
        exec "\(fakeSSH.path)" "$@"
        """.write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)
        var settings = AppSettings()
        settings.sshBinary = slow.path
        settings.useControlMaster = true
        settings.recordingEnabled = false
        settings.autoReconnect = false
        let cfg = SessionConfiguration(settings: settings)
        let sessions = (0..<5).map { _ in
            TerminalSession(descriptor: SessionDescriptor(target: .alias("busy-host"), persistence: .off)) { cfg }
        }
        for s in sessions { s.attach(sink: RecordingSink()); s.start() }
        try await wait("all online") { sessions.allSatisfy { $0.phase.isOnline } }
        // Logins never overlapped: every "start" is followed by its "end" before the next "start".
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map { $0.split(separator: " ")[0] }
        #expect(lines.count == 10)
        #expect(lines == Array(repeating: ["start", "end"], count: 5).flatMap { $0 }.map { Substring($0) })
        for s in sessions { s.close(killRemote: true) }
    }

    @Test func sessionIsUnusedUntilACommandIsRun() async throws {
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("local"), persistence: .off)) { config() }
        session.attach(sink: RecordingSink())
        session.start()
        try await wait("online") { session.phase.isOnline }
        #expect(session.isUnused)
        session.send(Array("\r".utf8)[...])           // an empty line is not a command
        #expect(session.isUnused)
        session.send(Array("echo hi".utf8)[...])
        #expect(session.isUnused, "typed but not sent yet")
        session.send(Array("\r".utf8)[...])
        #expect(!session.isUnused && session.hasRunCommands)
        session.close(killRemote: true)
    }
}
