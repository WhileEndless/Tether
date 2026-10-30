import Foundation
import Testing
import TetherCore
import TestSupport
import SSHTransport
import SwiftTerm
import RecordingKit
@testable import SessionKit

/// Collects everything the session displays.
@MainActor
final class RecordingSink: TerminalSink {
    var output: [UInt8] = []
    var text: String { String(decoding: output, as: UTF8.self) }
    func feed(_ bytes: ArraySlice<UInt8>) { output.append(contentsOf: bytes) }
    var cellSize: (cols: Int, rows: Int) { (100, 30) }
}

/// A terminal without a view (SwiftTerm's emulator): what the session shows, as a screen.
@MainActor
final class ScreenSink: TerminalSink, TerminalDelegate {
    lazy var terminal = Terminal(delegate: self, options: TerminalOptions(cols: 100, rows: 30, scrollback: 5_000))
    func feed(_ bytes: ArraySlice<UInt8>) { terminal.feed(buffer: bytes) }
    var cellSize: (cols: Int, rows: Int) { (100, 30) }
    nonisolated func send(source: Terminal, data: ArraySlice<UInt8>) {}

    func screenTail(maxRows: Int) -> (lines: [String], lastRow: Int)? {
        guard !terminal.isCurrentBufferAlternate else { return nil }
        let rows = (0..<terminal.rows).map { row -> String in
            var line = terminal.getLine(row: row)?.translateToString(trimRight: true) ?? ""
            while line.last == " " { line.removeLast() }
            return line
        }
        guard let last = rows.lastIndex(where: { !$0.isEmpty }) else { return nil }
        return (Array(rows[max(0, last - maxRows + 1)...last]), last)
    }
}

/// End-to-end tests that run the real bootstrap and tmux control mode locally.
/// A fake `ssh` executes the remote command with `sh` on this machine, using a private tmux server.
@MainActor
@Suite(.serialized) final class LocalSessionTests {
    let dir: URL
    let fakeSSH: URL

    nonisolated static let prefix = "tether-it-"

    /// Each test leaves nothing behind: a server it stopped is resumed, then its tmux server and its
    /// folder go. Nothing here may wait forever (a stopped tmux server never answers).
    deinit { Self.cleanUp(dir) }

    nonisolated static func cleanUp(_ dir: URL) {
        let pidFile = dir.appendingPathComponent("stopped.pid")
        if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGCONT)
        }
        // By its socket only: with the folder gone (another test sweeping it at the same time),
        // TMUX_TMPDIR would let tmux end the user's own server.
        PrivateTmux.killServer(in: dir)
        // Fake shared connections a test opened (`FakeSharedSSH`), also when it failed half-way.
        FakeSharedSSH.stopMasters(in: dir)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Folders left by runs that were interrupted (older than an hour).
    nonisolated static func sweepLeftovers() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-3600)
        for url in (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where url.lastPathComponent.hasPrefix(prefix) {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < cutoff { cleanUp(url) }
        }
    }

    init() throws {
        Self.sweepLeftovers()
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(Self.prefix)\(UUID().uuidString.prefix(6))")
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
        // Never without the folder: tmux would use the user's own server instead.
        guard FileManager.default.fileExists(atPath: dir.path) else { return "" }
        if args == ["kill-server"] { PrivateTmux.killServer(in: dir); return "" }
        var env = ProcessInfo.processInfo.environment
        env["TMUX_TMPDIR"] = dir.path
        env["TMUX"] = nil
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        return BoundedProcess.run("/usr/bin/env", ["tmux"] + args, environment: env, timeout: 10).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func wait(_ what: String, timeout: Double = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { Issue.record("Timed out waiting for \(what)"); return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    nonisolated static var hasTmux: Bool {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Retry while an attempt hangs (an ssh waiting on a connection that went dead): the attempt is
    /// stopped and a new one starts at once, instead of Retry doing nothing.
    @Test func retryStartsAgainWhileAnAttemptHangs() async throws {
        let hang = dir.appendingPathComponent("hang")
        FileManager.default.createFile(atPath: hang.path, contents: nil)
        let hanging = dir.appendingPathComponent("ssh-hang")
        try """
        #!/bin/sh
        # The terminal's own ssh (-tt) hangs, as on a connection that went dead.
        if [ -e "\(hang.path)" ]; then for a in "$@"; do [ "$a" = "-tt" ] && exec sleep 30; done; fi
        exec "\(fakeSSH.path)" "$@"
        """.write(to: hanging, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hanging.path)
        var settings = AppSettings()
        settings.sshBinary = hanging.path
        settings.useControlMaster = false
        settings.recordingEnabled = false
        settings.autoReconnect = false
        let cfg = SessionConfiguration(settings: settings)
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("local"), persistence: .off)) { cfg }
        session.attach(sink: RecordingSink())
        session.start()
        try await Task.sleep(for: .milliseconds(800))
        #expect(!session.phase.isOnline, "the first attempt hangs")
        try FileManager.default.removeItem(at: hang)
        session.restartAttempt()
        try await wait("online after retry", timeout: 10) { session.phase.isOnline }
        #expect(session.phase.isOnline)
        session.close(killRemote: true)
    }

    /// ⌘T: the new tab starts where the current tab's shell is now (asked from tmux, not a stale value).
    @Test(.enabled(if: LocalSessionTests.hasTmux)) func newTabStartsInTheCurrentFolder() async throws {
        let cfg = config()
        let folder = dir.appendingPathComponent("work dir")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let real = URL(fileURLWithPath: realpath(folder.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? folder.path)
        let first = TerminalSession(descriptor: SessionDescriptor(target: .alias("local"), persistence: .tmux)) { cfg }
        let sink1 = RecordingSink()
        first.attach(sink: sink1)
        first.start()
        try await wait("online") { first.phase.isOnline }
        first.send(Array("cd '\(folder.path)' && echo moved-$((1+1))\r".utf8)[...])
        try await wait("cd") { sink1.text.contains("moved-2") }
        try await Task.sleep(for: .milliseconds(300))
        let current = await first.workingDirectory()
        #expect(current == real.path, "got \(current ?? "nil")")

        var descriptor = SessionDescriptor(target: .alias("local"), persistence: .tmux)
        descriptor.initialDirectory = current
        let second = TerminalSession(descriptor: descriptor) { cfg }
        let sink2 = RecordingSink()
        second.attach(sink: sink2)
        second.start()
        try await wait("second online") { second.phase.isOnline }
        second.send(Array("echo \"at:$(pwd)\"\r".utf8)[...])
        try await wait("pwd") { sink2.text.contains("at:\(real.path)") }
        first.close(killRemote: true)
        second.close(killRemote: true)
        try await Task.sleep(for: .milliseconds(500))
    }

    /// A network device gets `ssh -tt host` with no remote command (its own CLI, not Tether's
    /// bootstrap) and is online at once; nothing else is sent to it.
    @Test func deviceGetsAPlainLogin() async throws {
        let args = dir.appendingPathComponent("device-args")
        let device = dir.appendingPathComponent("device-ssh")
        try """
        #!/bin/sh
        printf '%s\n' "$@" > '\(args.path)'
        printf 'Router> '
        exec cat
        """.write(to: device, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: device.path)
        var s = AppSettings()
        s.sshBinary = device.path
        s.useControlMaster = false
        s.recordingEnabled = false
        s.autoReconnect = false
        let cfg = SessionConfiguration(settings: s)
        let target = ConnectionTarget.alias("router-\(UUID().uuidString.prefix(6))")
        PlatformCache.shared.setAccess(.device, for: target.key)
        defer { PlatformCache.shared.setAccess(.automatic, for: target.key) }
        let session = TerminalSession(descriptor: SessionDescriptor(target: target, persistence: .auto)) { cfg }
        let sink = RecordingSink()
        session.attach(sink: sink)
        session.start()
        try await wait("online") { session.phase.isOnline }
        try await wait("prompt") { sink.text.contains("Router>") }
        let sent = try String(contentsOf: args, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(sent.contains("-tt"))
        #expect(sent.last == target.key, "no remote command after the host: \(sent.suffix(3))")
        #expect(!sent.contains { $0.contains("sh -c") || $0.contains("7770") })
        session.close(killRemote: false)
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

        let text = tmux(["display-message", "-p", "#{pid}"])
        // A pid of 0 or below would signal a whole process group (or every process): never.
        guard let pid = pid_t(text), pid > 1 else {
            Issue.record("no tmux server pid: \(text)")
            return
        }
        // Written first, so the server is resumed even if this test is cut short (see deinit).
        try String(pid).write(to: dir.appendingPathComponent("stopped.pid"), atomically: true, encoding: .utf8)
        kill(pid, SIGSTOP)
        defer { kill(pid, SIGCONT) }
        let stoppedAt = Date()
        try await wait("waiting", timeout: 10) { if case .waiting = session.phase { true } else { false } }
        #expect(Date().timeIntervalSince(stoppedAt) < 8, "stall should be detected within a few seconds")
        kill(pid, SIGCONT)
        try await wait("back online", timeout: 15) { session.phase.isOnline }
        session.close(killRemote: true)
        try await Task.sleep(for: .milliseconds(600))
        tmux(["kill-server"])
    }

    /// While the network is away (or the Mac sleeps) nothing is judged: plain ssh waits too, and
    /// the connection often survives. Once it is back, a server that still says nothing is noticed.
    @Test(.enabled(if: LocalSessionTests.hasTmux)) func noStallIsJudgedWhileTheNetworkIsAway() async throws {
        var settings = AppSettings()
        settings.sshBinary = fakeSSH.path
        settings.useControlMaster = false
        settings.recordingEnabled = false
        settings.autoReconnect = true
        settings.reconnectBaseDelay = 1
        settings.stallTimeout = 3
        let cfg = SessionConfiguration(settings: settings)
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("local"), persistence: .tmux)) { cfg }
        session.attach(sink: RecordingSink())
        session.start()
        try await wait("online") { session.phase.isOnline }
        let text = tmux(["display-message", "-p", "#{pid}"])
        guard let pid = pid_t(text), pid > 1 else { Issue.record("no tmux server pid: \(text)"); return }
        try String(pid).write(to: dir.appendingPathComponent("stopped.pid"), atomically: true, encoding: .utf8)
        session.connectivityHeld = true
        kill(pid, SIGSTOP)
        defer { kill(pid, SIGCONT) }
        try await Task.sleep(for: .seconds(6))
        #expect(session.phase.isOnline, "no answer while the network is away is not a stall")
        session.connectivityHeld = false
        try await wait("waiting", timeout: 10) { if case .waiting = session.phase { true } else { false } }
        kill(pid, SIGCONT)
        try await wait("back online", timeout: 15) { session.phase.isOnline }
        session.close(killRemote: true)
        try await Task.sleep(for: .milliseconds(600))
        tmux(["kill-server"])
    }

    /// Typed while the connection was away: sent once the tab is back in the same tmux session;
    /// Ctrl-C drops it.
    @Test(.enabled(if: LocalSessionTests.hasTmux)) func textTypedWhileAwayIsSentOnReattach() async throws {
        var settings = AppSettings()
        settings.sshBinary = fakeSSH.path
        settings.useControlMaster = false
        settings.recordingEnabled = false
        settings.autoReconnect = false
        let cfg = SessionConfiguration(settings: settings)
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("local"), persistence: .tmux)) { cfg }
        let sink = RecordingSink()
        session.attach(sink: sink)
        session.start()
        defer { session.close(killRemote: true) }
        try await wait("online") { session.phase.isOnline }
        session.networkBecameUnavailable()
        try await wait("waiting") { if case .waiting = session.phase { true } else { false } }
        session.send(Array("echo dropped".utf8)[...])
        session.send([0x03][...])
        #expect(session.heldInput.isEmpty, "Ctrl-C drops what was held")
        session.send(Array("echo held-$((40+2))\r".utf8)[...])
        #expect(!session.heldInput.isEmpty)
        session.reconnectNow()
        try await wait("back online", timeout: 15) { session.phase.isOnline }
        try await wait("held text ran") { sink.text.contains("held-42") }
        #expect(session.heldInput.isEmpty && !sink.text.contains("dropped"))
    }

    /// A plain shell ends with its connection: nothing typed meanwhile is kept for the next one.
    @Test func plainShellsKeepNothingTypedWhileAway() async throws {
        let cfg = config()
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("local"), persistence: .off)) { cfg }
        session.attach(sink: RecordingSink())
        session.start()
        defer { session.close(killRemote: true) }
        try await wait("online") { session.phase.isOnline }
        #expect(session.persistence == .plain)
        session.send(Array("x".utf8)[...])
        #expect(session.heldInput.isEmpty)
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

    /// A tab restored after a relaunch goes on with its recording: what it held before is shown
    /// again (not recorded twice), and what the server printed while Tether was closed is added once.
    @Test(.enabled(if: LocalSessionTests.hasTmux)) func restoredTabContinuesItsRecording() async throws {
        let cfg = config()
        let descriptor = SessionDescriptor(target: .alias("local"), persistence: .tmux)
        let first = TerminalSession(descriptor: descriptor) { cfg }
        let sink1 = RecordingSink()
        first.attach(sink: sink1)
        first.start()
        try await wait("tmux online") { first.phase.isOnline }
        first.send(Array("echo marker-$((6*7))\r".utf8)[...])
        try await wait("echo") { sink1.text.contains("marker-42") }
        try await Task.sleep(for: .milliseconds(300))
        // What the first run recorded (recording is off in these tests: written here as it would be).
        let recorder = try #require(SessionRecorder(targetKey: "local", sessionID: first.id,
                                                    directory: dir.appendingPathComponent("rec"), key: nil))
        recorder.append(sink1.output)
        recorder.close()
        first.abandon()                                   // Tether quits; the session keeps running
        try await Task.sleep(for: .milliseconds(300))
        tmux(["send-keys", "-t", descriptor.remoteSessionName, "for i in 1 2 3; do echo gap-$((i*11)); done", "Enter"])
        try await wait("printed while away") { self.tmux(["capture-pane", "-p", "-t", descriptor.remoteSessionName]).contains("gap-33") }

        var recording = cfg
        recording.recordingEnabled = true
        let second = TerminalSession(descriptor: descriptor) { recording }
        let sink2 = ScreenSink()
        second.attach(sink: sink2)
        var ready = false
        second.continueRecording(recorder.url) { ready = true }
        try await wait("recording continued") { ready }
        #expect(second.recordingURL == recorder.url)
        second.restore(previous: .tmux)
        try await wait("re-attached") { second.phase.isOnline }
        second.send(Array("echo after-$((2*50))\r".utf8)[...])
        try await wait("live again") { (try? self.recordingText(second)).map { $0.contains("after-100") } ?? false }
        let text = try recordingText(second)
        #expect(text.components(separatedBy: "marker-42").count - 1 == 1, "recording: \(text.suffix(1500))")
        for line in ["gap-11", "gap-22", "gap-33"] {
            #expect(text.components(separatedBy: line).count - 1 == 1, "\(line) once in: \(text.suffix(1500))")
        }
        #expect(second.recordingIndex?.isExact == true)
        second.close(killRemote: true)
        try await Task.sleep(for: .milliseconds(600))
        tmux(["kill-server"])
    }

    /// A server that asks something before its shell starts (a notice to accept, a forced password
    /// change, a menu): the terminal is shown for the answer, and the session starts once it is given.
    @Test func aQuestionBeforeTheShellIsShownAndAnswered() async throws {
        let asking = dir.appendingPathComponent("ssh-asking")
        try """
        #!/bin/sh
        # Never the user's tmux: this suite's private server only.
        export TMUX_TMPDIR="\(dir.path)"
        unset TMUX
        for last in "$@"; do :; done
        printf 'Authorized use only. Type yes to continue: '
        read answer
        [ "$answer" = yes ] || exit 1
        export SHELL=/bin/sh PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        exec /bin/sh -c "$last"
        """.write(to: asking, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: asking.path)
        var s = AppSettings()
        s.sshBinary = asking.path
        s.useControlMaster = false
        s.recordingEnabled = false
        s.autoReconnect = false
        let cfg = SessionConfiguration(settings: s)
        // A host known to run a shell (a host never seen is asked first, and one that answers with a
        // question is taken as a device: it gets a plain login, shown at once).
        let host = "asking-\(UUID().uuidString.prefix(6))"
        PlatformCache.shared.seed([host: .posix])
        defer { PlatformCache.shared.forget(host) }
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias(host), persistence: .off)) { cfg }
        let sink = RecordingSink()
        session.attach(sink: sink)
        session.start()
        try await wait("question shown") { sink.text.contains("Type yes") }
        try await wait("terminal shown for it", timeout: 6) { session.serverWaitsInTerminal }
        #expect(!session.phase.isOnline)
        session.send(Array("yes\r".utf8)[...])
        try await wait("shell started") { session.phase.isOnline }
        #expect(!session.serverWaitsInTerminal)
        session.close(killRemote: false)
        try await Task.sleep(for: .milliseconds(400))
    }

    /// An account with a restricted shell (`rbash`): it answers like a shell but
    /// refuses Tether's start-up script. The host is then remembered as a limited shell and the tab
    /// opens a plain login at once.
    @Test func aRestrictedShellGetsAPlainLogin() async throws {
        let fake = dir.appendingPathComponent("ssh-restricted")
        try """
        #!/bin/sh
        # Never the user's tmux: this suite's private server only.
        export TMUX_TMPDIR="\(dir.path)"
        unset TMUX
        for last in "$@"; do :; done
        # What rbash says to the start-up script (its redirections), then nothing runs.
        case "$last" in *"mark()"*) echo "rbash: /dev/null: restricted: cannot redirect output"; exit 1;; esac
        printf 'plain-login-ok\r\n'
        exec /bin/sh
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        var s = AppSettings()
        s.sshBinary = fake.path
        s.useControlMaster = false
        s.recordingEnabled = false
        s.autoReconnect = false
        let cfg = SessionConfiguration(settings: s)
        let host = "restricted-\(UUID().uuidString.prefix(6))"
        PlatformCache.shared.seed([host: .posix])
        defer { PlatformCache.shared.forget(host) }
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias(host), persistence: .auto)) { cfg }
        let sink = RecordingSink()
        session.attach(sink: sink)
        session.start()
        try await wait("plain login") { sink.text.contains("plain-login-ok") }
        try await wait("online") { session.phase.isOnline }
        #expect(PlatformCache.shared.isDevice(host))
        #expect(session.persistence == .plain)
        #expect(sink.text.contains("restricted"))
        session.close(killRemote: false)
        try await Task.sleep(for: .milliseconds(400))
    }

    /// Everything the session's recording holds, written out first.
    func recordingText(_ session: TerminalSession) throws -> String {
        guard let url = session.flushedRecordingURL() else { return "" }
        var data = Data()
        try RecordingReader.forEachChunk(of: url, key: nil) { data.append($0); return true }
        return String(decoding: data, as: UTF8.self)
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
        settings.sshBinary = try FakeSharedSSH.install(in: dir).path
        await SharedConnectionsTestLock.shared.acquire()
        await SharedConnections.shared.useSocketDirectory(dir)
        settings.useControlMaster = true      // exercises the separate "open shared connection" step
        settings.recordingEnabled = false
        settings.autoReconnect = false
        let cfg = SessionConfiguration(settings: settings)
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("local-\(UUID().uuidString.prefix(4))"), persistence: .off)) { cfg }
        let sink = RecordingSink()
        session.attach(sink: sink)
        session.start()
        #expect(session.progress != nil)
        try await wait("online") { session.phase.isOnline }
        #expect(session.progress == nil, "progress is cleared once online")
        session.send(Array("echo via-master\r".utf8)[...])
        try await wait("echo") { sink.text.contains("via-master") }
        #expect(FakeSharedSSH.logins(in: dir) == ["start", "end"])
        session.close(killRemote: true)
        await SharedConnections.shared.reset()
        await SharedConnectionsTestLock.shared.release()
        FakeSharedSSH.stopMasters(in: dir)
    }

    @Test func retryAfterFailedConnectionReusesTheSession() async throws {
        // A fake ssh that refuses the sign-in while a "down" file exists (a server that does not
        // answer is waited for instead: see `anUnreachableServerIsTriedOncePerRoundNotPerTab`).
        let down = dir.appendingPathComponent("down")
        FileManager.default.createFile(atPath: down.path, contents: Data())
        let flaky = dir.appendingPathComponent("flaky-ssh")
        try """
        #!/bin/sh
        if [ -e "\(down.path)" ]; then echo "user@example.invalid: Permission denied (publickey)." >&2; exit 255; fi
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

    /// Without connection sharing every tab signs in by itself, one at a time. A server that does
    /// not answer is still tried once per round, not once per tab: tabs queued behind a failed
    /// attempt take that failure as theirs and wait for the server's next round. New tabs keep
    /// waiting for it (it may come back) instead of giving up.
    @Test func anUnreachableServerIsTriedOncePerRoundNotPerTab() async throws {
        let attempts = dir.appendingPathComponent("attempts")
        let unreachable = dir.appendingPathComponent("unreachable-ssh")
        try """
        #!/bin/sh
        for a in "$@"; do [ "$a" = "-tt" ] && echo x >> "\(attempts.path)"; done
        sleep 1
        echo "ssh: connect to host example.invalid port 22: Operation timed out" >&2
        exit 255
        """.write(to: unreachable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreachable.path)
        var settings = AppSettings()
        settings.sshBinary = unreachable.path
        settings.useControlMaster = false
        settings.recordingEnabled = false
        settings.reconnectBaseDelay = 0.5
        let cfg = SessionConfiguration(settings: settings)
        let host = "unreachable-\(UUID().uuidString.prefix(6))"
        let sessions = (0..<5).map { _ in
            TerminalSession(descriptor: SessionDescriptor(target: .alias(host), persistence: .off)) { cfg }
        }
        for s in sessions { s.attach(sink: RecordingSink()); s.start() }
        try await wait("four rounds", timeout: 60) { sessions.allSatisfy { $0.attempt >= 4 } }
        let tries = ((try? String(contentsOf: attempts, encoding: .utf8)) ?? "").split(separator: "\n").count
        #expect(tries >= 4 && tries <= 5, "one attempt per round for five tabs, not \(tries)")
        #expect(sessions.allSatisfy { !$0.phase.isDead }, "new tabs wait for a server that does not answer")
        for s in sessions { s.close(killRemote: false) }
        HostRetryClock.shared.reset(host)
    }

    /// Many tabs to one server opened at once sign in once: the others use that connection.
    @Test func manyTabsToOneHostSignInOnce() async throws {
        var settings = AppSettings()
        settings.sshBinary = try FakeSharedSSH.install(in: dir).path
        await SharedConnectionsTestLock.shared.acquire()
        await SharedConnections.shared.useSocketDirectory(dir)
        settings.useControlMaster = true
        settings.recordingEnabled = false
        settings.autoReconnect = false
        let cfg = SessionConfiguration(settings: settings)
        let host = "busy-\(UUID().uuidString.prefix(4))"
        let sessions = (0..<5).map { _ in
            TerminalSession(descriptor: SessionDescriptor(target: .alias(host), persistence: .off)) { cfg }
        }
        for s in sessions { s.attach(sink: RecordingSink()); s.start() }
        try await wait("all online") { sessions.allSatisfy { $0.phase.isOnline } }
        #expect(FakeSharedSSH.logins(in: dir) == ["start", "end"], "one sign-in for five tabs")
        for s in sessions { s.close(killRemote: true) }
        await SharedConnections.shared.reset()
        await SharedConnectionsTestLock.shared.release()
        FakeSharedSSH.stopMasters(in: dir)
    }

    @Test func sessionIsUnusedUntilACommandIsRun() async throws {
        let cfg = config()
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("local"), persistence: .off)) { cfg }
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
