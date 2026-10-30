import Foundation
import Testing
import TetherCore
import TestSupport
@testable import SessionKit

/// Why a session ended by itself, from one read-only look at the server.
@Suite struct ServerDiagnosisTests {
    @Test func hintsFromTheServersAnswers() {
        let hints = ServerDiagnosis.hints(from: "@@mem 96\n@@oom 2026-01-05T09:30:12+0000 host kernel: Out of memory: Killed process 4321 (example-worker) total-vm:1048576kB\n@@uptime 120.5\n@@tmout 900\n")
        #expect(hints == ["the server is low on memory (96% used)", "the server's kernel ended example-worker for lack of memory at 09:30",
                          "the server restarted 2 min ago", "the shell has an idle limit (TMOUT=900 s)"])
        #expect(ServerDiagnosis.hints(from: "@@mem 40\n@@uptime 86400\n").isEmpty, "nothing unusual: nothing said")
        #expect(ServerDiagnosis.oomHint("[123.4] Out of memory: Killed process 4242 (node)") == "the server's kernel ended node for lack of memory recently")
    }

    /// The script runs with any POSIX shell and ends at once, also without /proc (as on macOS).
    @Test func scriptRunsLocally() {
        let r = BoundedProcess.run("/bin/sh", ["-s"], environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh"],
                                   input: ServerDiagnosis.script, timeout: 15)
        #expect(!r.timedOut && r.status == 0)
        #expect(r.output.split(separator: "\n").allSatisfy { $0.hasPrefix("@@") })
    }

    /// `exit`, `logout` or Ctrl-D typed a moment before: the shell ending is no surprise.
    @MainActor @Test func theUserEndingTheShellIsNoticed() {
        var s = AppSettings()
        s.recordingEnabled = false
        let cfg = SessionConfiguration(settings: s)
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("example"), persistence: .off)) { cfg }
        session.send(Array("exi".utf8)[...])
        #expect(!session.endedByUser)
        session.send(Array("t\r".utf8)[...])
        #expect(session.endedByUser)
        let other = TerminalSession(descriptor: SessionDescriptor(target: .alias("example"), persistence: .off)) { cfg }
        other.send(Array("echo exit\r".utf8)[...])
        #expect(!other.endedByUser)
        other.send([0x04][...])
        #expect(other.endedByUser)
    }
}
