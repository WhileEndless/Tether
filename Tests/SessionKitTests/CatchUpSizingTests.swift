import Foundation
import Testing
@testable import SessionKit
import TmuxControl

/// Re-attaching first asks tmux for about as many rows as the pane's history gained since this tab
/// last looked (not always the last 1,000), and finds its place by the rows themselves — also when
/// the bottom rows seen last were redrawn in place (a coding agent's prompt box), which used to
/// send it through 1,000, 10,000 rows and then the whole history. A count it cannot trust (another
/// pane, a history near its limit, a resize, a cleared history) only changes the first look's size:
/// output is never skipped because of it.
@MainActor
@Suite struct CatchUpSizingTests {
    typealias Position = TmuxDriver.HistoryPosition

    func info(_ line: String) -> TmuxPaneInfo { TmuxPaneInfo(line: line)! }
    /// Pane info as tmux answers it: id, alternate, cursor x y, width, height, history, modes, limit, pid.
    func paneLine(history: Int, limit: Int = 50_000, pid: Int = 4242, width: Int = 80, height: Int = 2) -> String {
        "%1 0 0 1 \(width) \(height) \(history) cursor=1;paste=0 \(limit) \(pid)"
    }
    func position(size: Int, pane: String = "%1", pid: Int = 4242, limit: Int = 50_000, width: Int = 80, height: Int = 2) -> Position {
        Position(paneID: pane, panePID: pid, size: size, limit: limit, width: width, height: height)
    }

    @Test func theCountIsUsedOnlyWhenItCanBeTrusted() {
        let now = info(paneLine(history: 1_500))
        let size = (cols: 80, rows: 2)
        #expect(TmuxDriver.rowsAdded(since: position(size: 1_200), now: now, sizeToSend: size) == 300)
        #expect(TmuxDriver.rowsAdded(since: position(size: 1_200), now: now, sizeToSend: nil) == 300, "size not known yet")
        #expect(TmuxDriver.rowsAdded(since: nil, now: now, sizeToSend: size) == nil, "never looked")
        #expect(TmuxDriver.rowsAdded(since: position(size: 1_200, pane: "%2"), now: now, sizeToSend: size) == nil, "another pane")
        #expect(TmuxDriver.rowsAdded(since: position(size: 1_200, pid: 99), now: now, sizeToSend: size) == nil, "tmux started again")
        #expect(TmuxDriver.rowsAdded(since: position(size: 2_000), now: now, sizeToSend: size) == nil, "cleared since")
        #expect(TmuxDriver.rowsAdded(since: position(size: 1_200, width: 120), now: now, sizeToSend: size) == nil, "another width then")
        #expect(TmuxDriver.rowsAdded(since: position(size: 1_200), now: now, sizeToSend: (100, 2)) == nil, "resized now: re-wrapped")
        // Near the limit tmux drops a tenth of the history at once: the count says nothing there.
        #expect(TmuxDriver.rowsAdded(since: position(size: 45_500), now: info(paneLine(history: 45_600)), sizeToSend: size) == nil)
        #expect(TmuxDriver.rowsAdded(since: position(size: 40_000), now: info(paneLine(history: 44_000)), sizeToSend: size) == 4_000)
        #expect(TmuxDriver.rowsAdded(since: position(size: 1_200), now: info("%1 0 0 1 80 2 1500"), sizeToSend: size) == nil,
                "an older answer without the limit")
    }

    func attach(_ driver: TmuxDriver, history: Int) {
        driver.receive(Array("\u{1b}P1000p".utf8))
        driver.receive(Array("%begin 1 0 0\n%end 1 0 0\n".utf8))                                   // the attach command
        driver.receive(Array("%begin 1 1 0\n\(paneLine(history: history))\n%end 1 1 0\n".utf8))    // pane info
    }

    final class Log {
        var written: [String] = []
        var shown: [UInt8] = []
        var text: String { String(decoding: shown, as: UTF8.self) }
        func clear() { written = [] }
        var asked: String { written.joined() }
    }

    func makeDriver(last: Position?, anchor: [String], lastRow: Int) -> (TmuxDriver, Log) {
        let driver = TmuxDriver(version: "3.4", isReattach: true, terminalIsEmpty: false, historyLines: 10, ownSession: false)
        let log = Log()
        driver.write = { log.written.append($0) }
        driver.display = { log.shown += $0 }
        driver.size = { (80, 2) }
        driver.screenTail = { HistoryCatchUp.Anchor(lines: anchor, lastRow: lastRow) }
        driver.lastPosition = { last }
        return (driver, log)
    }

    func reply(_ driver: TmuxDriver, _ number: Int, _ rows: [String]) {
        driver.receive(Array(("%begin 1 \(number) 0\n" + rows.map { $0 + "\n" }.joined() + "%end 1 \(number) 0\n").utf8))
    }

    /// The history grew by 40 rows since the last look: 40 + the margin are asked for first.
    @Test func theFirstLookIsSizedByWhatWasAdded() {
        let (driver, log) = makeDriver(last: position(size: 30_000), anchor: ["last line seen here"], lastRow: 0)
        attach(driver, history: 30_040)
        #expect(log.asked.contains("capture-pane -p -e -S -\(40 + TmuxDriver.catchUpMargin) -t %1"))
        #expect(!log.asked.contains("-S -1000 "))
    }

    /// Cleared, then more printed than before (the count says 200 where 300 are new): the rows
    /// seen last are not found, and nothing printed meanwhile is skipped.
    @Test func aClearedHistoryThatGrewAgainSkipsNothing() {
        let (driver, log) = makeDriver(last: position(size: 100), anchor: ["echo before-one", "before-one", "echo before-two", "before-two"], lastRow: 3)
        attach(driver, history: 300)
        #expect(log.asked.contains("capture-pane -p -e -S -300 -t %1"), "all the history there is (200 + the margin)")
        driver.receive(Array("%begin 1 5 0\n%end 1 5 0\n".utf8))                                   // the resize
        reply(driver, 2, (1...300).map { "away \($0)" } + ["$ "])
        #expect(driver.ready)
        #expect(log.text.contains("away 1\u{1b}") && log.text.contains("away 300"), "every row printed while away")
    }

    /// The first look, sized by the count, does not hold the rows seen last (more was printed than
    /// the count says — a history re-wrapped by another client): further back, in steps.
    @Test func notFoundInTheFirstLookItLooksFurtherBack() {
        let (driver, log) = makeDriver(last: position(size: 20_000), anchor: ["last line seen here"], lastRow: 0)
        attach(driver, history: 20_100)
        #expect(log.asked.contains("capture-pane -p -e -S -400 -t %1"))
        driver.receive(Array("%begin 1 5 0\n%end 1 5 0\n".utf8))                                   // the resize
        log.clear()
        reply(driver, 2, ["new 1", "new 2"])
        #expect(log.asked.contains("capture-pane -p -e -S -10000 -t %1"))
        #expect(!driver.ready)
    }

    /// Without a known position (Tether reopened): as before, in steps.
    @Test func withoutAPositionItLooksInSteps() {
        let (driver, log) = makeDriver(last: nil, anchor: ["last line seen here"], lastRow: 0)
        attach(driver, history: 30_000)
        #expect(log.asked.contains("capture-pane -p -e -S -1000 -t %1"))
    }

    /// The position comes with every activity check, and with the pane's info on attach.
    @Test func positionsAreReported() {
        let driver = TmuxDriver(version: "3.4", isReattach: false, terminalIsEmpty: true, historyLines: 10, ownSession: false)
        var positions: [Position] = []
        var activity: [String] = []
        driver.write = { _ in }
        driver.size = { (80, 2) }
        driver.onPosition = { positions.append($0) }
        driver.onActivity = { command, path, _ in activity.append(command + " " + path) }
        attach(driver, history: 10)
        #expect(positions.last == position(size: 10))
        driver.receive(Array("%begin 1 2 0\n%end 1 2 0\n".utf8))                                   // our size
        #expect(driver.ready)
        driver.requestActivity()
        driver.receive(Array("%begin 1 3 0\n250\t50000\t120\t40\tzsh\t/home/user/my\tproject\n%end 1 3 0\n".utf8))
        #expect(positions.last == position(size: 250, width: 120, height: 40))
        #expect(activity.last == "zsh /home/user/my\tproject", "a path with a tab stays whole")
    }

    /// Claude Code's screen: the conversation stays, its prompt box stays at the bottom, and new
    /// messages take the old box's place. Found by the conversation rows; the new messages follow
    /// them and are printed over the old box (nothing skipped, the old box not kept).
    @Test func newMessagesWhereTheOldPromptBoxWasAreAdded() {
        let conversation = ["● Read the parser and its tests", "  ⎿  Read 120 lines", "● The failing case is the empty input",
                            "  which returns nil before the check", "● I will add a guard and a test"]
        let footerThen = ["╭──────────────╮", "│ > fix it     │", "╰──────────────╯", "  ✻ Thinking… (3s) · esc to interrupt"]
        let footerNow = ["╭──────────────╮", "│ >            │", "╰──────────────╯", "  ? for shortcuts"]
        let anchor = conversation + footerThen
        let captured = ["earlier output"] + conversation + ["● Added the guard", "● Tests pass"] + footerNow
        let resume = HistoryCatchUp.resume(captured: captured, anchor: anchor)
        #expect(resume == HistoryCatchUp.Resume(index: 1 + conversation.count, replacesLastRow: false, rowsBack: footerThen.count))
        // Printed from the row of the conversation's last line on: over the old box.
        let out = HistoryCatchUp.output(captured: captured.map { Array($0.utf8) }, from: resume!.index,
                                        anchorRow: 20 - resume!.rowsBack, height: 0, cursor: (0, 0))
        let text = String(decoding: out.stream, as: UTF8.self)
        #expect(text.hasPrefix("\u{1b}[17;1H"), "starts below the conversation's last row")
        #expect(text.contains("● Added the guard") && text.contains("● Tests pass"))
        #expect(!text.contains("fix it"), "the old box is not printed again")
    }

    /// The driver does the same end to end, in the first, small look.
    @Test func anAgentsRedrawnBoxDoesNotSendItFurtherBack() {
        let conversation = ["● Read the parser and its tests", "  ⎿  Read 120 lines", "● The failing case is the empty input",
                            "  which returns nil before the check", "● I will add a guard and a test"]
        let anchor = conversation + ["╭──────────────╮", "│ > fix it     │", "╰──────────────╯", "  ✻ Thinking… (3s)"]
        let (driver, log) = makeDriver(last: position(size: 1_000), anchor: anchor, lastRow: 8)
        attach(driver, history: 1_002)
        let rows = 2 + TmuxDriver.catchUpMargin
        #expect(log.asked.contains("capture-pane -p -e -S -\(rows) -t %1"))
        driver.receive(Array("%begin 1 5 0\n%end 1 5 0\n".utf8))                                   // the resize
        log.clear()
        let capture = (0..<(rows - 7)).map { "older \($0)" } + conversation + ["● Added the guard", "● Tests pass", "│ >   │", "  ? for shortcuts"]
        reply(driver, 2, capture)
        #expect(!log.asked.contains("-S -1000"), "not looked further back")
        #expect(log.asked.contains("capture-pane -p -e -J -S -\(rows) -t %1"), "joined once more for what is added")
        reply(driver, 6, capture)
        #expect(driver.ready)
        #expect(log.text.contains("● Added the guard") && log.text.contains("● Tests pass"))
        #expect(!log.text.contains("older"))
        #expect(!log.text.contains("may repeat"))
    }

    /// Too little text to tell apart: not guessed by the top rows.
    @Test func topRowsWithLittleTextAreNotTrusted() {
        #expect(HistoryCatchUp.resumeByTopRows(captured: ["a", "b", "c", "d", "x"], anchor: ["a", "b", "c", "y"]) == nil)
        #expect(HistoryCatchUp.resumeByTopRows(captured: ["╭────╮", "│    │", "╰────╯", "x"], anchor: ["╭────╮", "│    │", "╰────╯", "y"]) == nil)
    }

    /// The same block printed twice (an agent showing a file again): the newest place is taken, so
    /// what came after the older copy is not printed again.
    @Test func aRepeatedBlockResumesAfterItsNewestCopy() {
        let block = ["● Reading Sources/Parser.swift", "  line one of the file shown", "  line two of the file shown"]
        let anchor = block + ["╭────╮", "│ >  │", "╰────╯"]
        let captured = block + ["● between"] + block + ["● after"] + ["╭────╮", "│    │", "╰────╯"]
        let resume = HistoryCatchUp.resume(captured: captured, anchor: anchor)
        #expect(resume?.index == 7)
    }
}
