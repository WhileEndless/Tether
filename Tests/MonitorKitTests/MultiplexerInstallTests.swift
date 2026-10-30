import Foundation
import Testing
import TestSupport
@testable import MonitorKit

@Suite struct MultiplexerInstallTests {
    @Test func theCommandFitsTheHost() {
        func s(_ text: String) -> MultiplexerInstall.Suggestion { MultiplexerInstall.suggestion(from: text) }
        #expect(s("os=Linux\nuid=1000\nsudo=1\npm=apt-get\n").command == "sudo apt-get install tmux")
        #expect(s("os=Linux\nuid=0\npm=dnf\n").command == "dnf install tmux", "root needs no sudo")
        #expect(s("os=Darwin\nuid=501\nsudo=1\npm=brew\n").command == "brew install tmux", "never sudo for Homebrew")
        #expect(s("os=Linux\nuid=1000\npm=apk\n").note.contains("as root"), "no sudo: said so")
        #expect(s("os=Linux\nuid=1000\nsudo=1\n").command == nil)
        #expect(s("os=Darwin\nuid=501\n").note.contains("Homebrew"))
    }

    /// The probe runs with the local shell and reads nothing but what is there.
    @Test func theProbeRunsWithTheLocalShell() {
        let r = BoundedProcess.run("/bin/sh", ["-c", MultiplexerInstall.probe.posix], timeout: 20)
        #expect(r.status == 0 && r.output.contains("os=Darwin") && r.output.contains("uid="), "\(r.output)")
    }
}
