import Network
import Testing
@testable import SessionKit

/// A new tab stops trying only for a failure that will not pass by itself, judged by what ssh said
/// itself — not by its `-v` steps, which name files that are missing on every connection.
@Suite struct NewTabFailureTests {
    func said(_ lines: [String]) -> [String] {
        var p = ConnectionProgress()
        lines.forEach { p.ingest($0) }
        return p.sshSaid
    }

    @Test func aBrokenPipeWhileSigningInIsTriedAgain() {
        let lines = said([
            "debug1: Connecting to 192.0.2.34 [192.0.2.34] port 22.",
            "debug1: load_hostkeys: fopen /home/user/.ssh/known_hosts2: No such file or directory",
            "debug1: Next authentication method: password",
            "ssh_dispatch_run_fatal: Connection to 192.0.2.34 port 22: Broken pipe",
        ])
        #expect(!TerminalSession.failedForGood(lines))
        #expect(!lines.contains { $0.contains("known_hosts2") }, "ssh's -v steps are not what it said")
    }

    @Test func aRefusalOrAnUnknownHostStops() {
        #expect(TerminalSession.failedForGood(said(["user@example.com: Permission denied (publickey,password)."])))
        #expect(TerminalSession.failedForGood(said(["ssh: Could not resolve hostname nowhere.example.com: nodename nor servname provided"])))
        // Right after waking, or while a VPN comes up, names do not resolve for a moment: a few tries first.
        #expect(!TerminalSession.failedForGood(said(["ssh: Could not resolve hostname nowhere.example.com: nodename nor servname provided"]), attempt: 1))
        #expect(TerminalSession.failedForGood(said(["user@example.com: Permission denied (publickey,password)."]), attempt: 0))
        #expect(TerminalSession.failedForGood(said(["Host key verification failed."])))
    }

    @Test func aMissingKeyFileIsNotAFailure() {
        #expect(!TerminalSession.failedForGood(said(["no such identity: /home/user/.ssh/id_missing: No such file or directory",
                                                      "Connection closed by 192.0.2.34 port 22"])))
        #expect(!TerminalSession.isPermanentFailure("Warning: Identity file /home/user/.ssh/id_missing not accessible: No such file or directory."))
    }

    @Test func aRefusalThenABreakIsTriedAgain() {
        #expect(!TerminalSession.failedForGood(said(["user@example.com: Permission denied (publickey).",
                                                      "client_loop: send disconnect: Broken pipe"])))
    }

    /// A check that ran much later than planned was held up by macOS (App Nap, the display going to
    /// sleep), not by the server: such a check never lets a tab go.
    @Test func aLateCheckIsMacOSNotTheServer() {
        #expect(TerminalSession.lateCheck(interval: 2) == 7)
        #expect(TerminalSession.lateCheck(interval: 4) > 4 * 2)
    }
}

/// The network log tells the network as it is when the event goes out.
@MainActor @Suite struct ConnectivityEventTests {
    @Test func anEventReportsTheNewInterfaces() {
        let monitor = ConnectivityMonitor()
        var seen: [(ConnectivityMonitor.Event, [String])] = []
        monitor.update(status: .satisfied, interfaces: ["en0"])
        monitor.onEvent = { seen.append(($0, monitor.interfaces)) }
        monitor.update(status: .unsatisfied, interfaces: [])
        monitor.update(status: .satisfied, interfaces: ["en7"])
        monitor.update(status: .satisfied, interfaces: ["en7", "utun3"])
        #expect(seen.map(\.0) == [.lost, .restored, .changed])
        #expect(seen.map(\.1) == [[], ["en7"], ["en7", "utun3"]])
    }
}
