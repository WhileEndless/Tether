import Foundation
import Testing
import TetherCore
@testable import SessionKit

/// Small rules of re-attaching and of what comes back after a relaunch.
@Suite struct ReattachRulesTests {
    /// Lines only Tether writes (a recording's marks, its notices) are never looked for in the
    /// server's history: they are not there, and the place to continue from would not be found.
    @Test func tetherLinesAreNotPartOfTheAnchor() {
        #expect(HistoryCatchUp.isTetherLine("── Connection lost 10:42:01 ──"))
        #expect(HistoryCatchUp.isTetherLine("── Paused while the Mac slept 23:10:00 ──"))
        #expect(HistoryCatchUp.isTetherLine("[Tether] A new shell starts here; the one above ended with the connection."))
        #expect(!HistoryCatchUp.isTetherLine("user@example:~$ ls"))
        #expect(!HistoryCatchUp.isTetherLine("── a heading someone printed"))
        // A program's own boxed heading is its output, not Tether's mark.
        #expect(!HistoryCatchUp.isTetherLine("── Summary ──"))
        #expect(HistoryCatchUp.isTetherLine("── Reconnected 08:01:02 ──"))
    }

    /// After a relaunch, forwards listening only on this Mac come back by themselves; one open to
    /// the network, or one on the server, is asked about first.
    @Test func forwardsThatComeBackByThemselves() {
        #expect(PortForward(kind: .local, listenPort: 8080, destinationPort: 80).listensOnlyOnThisMac)
        #expect(PortForward(kind: .dynamic, bindAddress: "127.0.0.1", listenPort: 1080, destinationPort: 0).listensOnlyOnThisMac)
        #expect(!PortForward(kind: .local, bindAddress: "0.0.0.0", listenPort: 8080, destinationPort: 80).listensOnlyOnThisMac)
        #expect(!PortForward(kind: .remote, listenPort: 9000, destinationPort: 9000).listensOnlyOnThisMac)
    }
}
