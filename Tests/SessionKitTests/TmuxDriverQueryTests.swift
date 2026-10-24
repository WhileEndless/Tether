import Foundation
import Testing
@testable import SessionKit

/// tmux answers questions in the order they were asked. A question that timed out must still take
/// its own late answer — otherwise every later answer is off by one (e.g. "which program is in the
/// foreground?" answered with a tty), and a waiting sudo is not recognised.
@MainActor
@Suite struct TmuxDriverQueryTests {
    func readyDriver() -> TmuxDriver {
        let driver = TmuxDriver(version: "3.4", isReattach: false, terminalIsEmpty: true, historyLines: 100, ownSession: false)
        driver.receive(Array("\u{1b}P1000p".utf8))
        driver.receive(Array("%begin 1 0 0\n%end 1 0 0\n".utf8))                     // the attach command
        driver.receive(Array("%begin 1 1 0\n%1 0 0 0 80 24 0\n%end 1 1 0\n".utf8))  // pane info
        driver.receive(Array("%begin 1 2 0\n%end 1 2 0\n".utf8))                     // resize
        return driver
    }

    @Test func lateAnswerGoesToTheQuestionThatTimedOut() async throws {
        let driver = readyDriver()
        #expect(driver.ready)
        let slow = Task { await driver.query("#{pane_tty}", timeout: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await slow.value == nil)

        let next = Task { await driver.query("#{pane_current_command}", timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        driver.receive(Array("%begin 1 3 0\n/dev/pts/7\n%end 1 3 0\n".utf8))        // late, for the first
        driver.receive(Array("%begin 1 4 0\nsudo\n%end 1 4 0\n".utf8))
        #expect(await next.value == "sudo")
    }

    @Test func exitAnswersEveryWaitingQuestion() async throws {
        let driver = readyDriver()
        let waiting = Task { await driver.query("#{pane_tty}", timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        driver.receive(Array("%exit\n".utf8))
        #expect(await waiting.value == nil)
        #expect(await driver.query("#{pane_tty}") == nil)
    }
}
