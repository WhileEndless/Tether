import Foundation
import Testing
@testable import SessionKit

/// Re-attaching over a slow link: the tab is not taken for a plain shell while the server is slow
/// to answer, and output printed meanwhile is fetched in steps instead of all history at once.
@MainActor
@Suite struct SlowReattachTests {
    @Test func reattachingToTmuxIsNeverGuessedPlain() {
        #expect(!TerminalSession.shouldGuessPlain(reattachingPersistent: true, receivedThisAttempt: true,
                                                  quietFor: 60, promptShown: false, asking: false))
    }

    @Test func guessNeedsOutputOfThisAttemptAndQuiet() {
        // Nothing from this ssh yet (what the screen shows is from the previous connection).
        #expect(!TerminalSession.shouldGuessPlain(reattachingPersistent: false, receivedThisAttempt: false,
                                                  quietFor: 60, promptShown: false, asking: false))
        #expect(!TerminalSession.shouldGuessPlain(reattachingPersistent: false, receivedThisAttempt: true,
                                                  quietFor: 2, promptShown: false, asking: false))
        #expect(TerminalSession.shouldGuessPlain(reattachingPersistent: false, receivedThisAttempt: true,
                                                 quietFor: 6, promptShown: false, asking: false))
    }

    @Test func noGuessWhileAPasswordIsAskedFor() {
        #expect(!TerminalSession.shouldGuessPlain(reattachingPersistent: false, receivedThisAttempt: true,
                                                  quietFor: 60, promptShown: true, asking: false))
        #expect(!TerminalSession.shouldGuessPlain(reattachingPersistent: false, receivedThisAttempt: true,
                                                  quietFor: 60, promptShown: false, asking: true))
    }

    @Test func catchUpSteps() {
        #expect(TmuxDriver.nextCatchUp(after: 1_000, available: 500) == nil)
        #expect(TmuxDriver.nextCatchUp(after: 1_000, available: 4_000) == 4_000)
        #expect(TmuxDriver.nextCatchUp(after: 1_000, available: 100_000) == 10_000)
        #expect(TmuxDriver.nextCatchUp(after: 10_000, available: 100_000) == 100_000)
        #expect(TmuxDriver.nextCatchUp(after: 100_000, available: 100_000) == nil)
    }

    @Test func catchUpLooksFurtherBackInSteps() {
        let driver = TmuxDriver(version: "3.4", isReattach: true, terminalIsEmpty: false, historyLines: 10, ownSession: false)
        var written: [String] = []
        driver.write = { written.append($0) }
        driver.size = { (80, 2) }
        driver.screenTail = { HistoryCatchUp.Anchor(lines: ["last line seen here"], lastRow: 0) }
        driver.catchUpLimit = 100_000
        driver.receive(Array("\u{1b}P1000p".utf8))
        driver.receive(Array("%begin 1 0 0\n%end 1 0 0\n".utf8))                          // the attach command
        driver.receive(Array("%begin 1 1 0\n%1 0 0 1 80 2 50000\n%end 1 1 0\n".utf8))    // pane info: 50 000 rows kept
        #expect(written.joined().contains("capture-pane -p -e -S -1000 -t %1"))
        written = []
        driver.receive(Array("%begin 1 5 0\n%end 1 5 0\n".utf8))                          // the resize
        driver.receive(Array("%begin 1 2 0\nnew 1\nnew 2\n%end 1 2 0\n".utf8))            // anchor not in it
        #expect(written.joined().contains("capture-pane -p -e -S -10000 -t %1"))
        written = []
        driver.receive(Array("%begin 1 3 0\nnew 1\nnew 2\n%end 1 3 0\n".utf8))            // still not in it
        #expect(written.joined().contains("capture-pane -p -e -S -50000 -t %1"))
        #expect(!driver.ready)
        driver.receive(Array("%begin 1 4 0\nlast line seen here\nnew 1\n%end 1 4 0\n".utf8))
        #expect(driver.ready)
    }
}
