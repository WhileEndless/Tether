import AppKit
import Testing
import TetherCore
import SwiftTerm
@testable import RecordingKit
@testable import SessionKit
@testable import TerminalUI

/// ⌘↑ / ⌘↓ (the previous / next command) and ⇧⌘↑ / ⇧⌘↓ (whole commands), as Terminal.app's marks:
/// from where the view is, through memory and the recording, while output goes on.
@MainActor
@Suite(.serialized) struct CommandJumpTests {
    typealias Fixture = HistoryBrowsingTests.Fixture

    // MARK: Commands in memory

    /// Commands typed here (their marks made as Return is pressed), each with `output` lines.
    static func run(_ f: Fixture, _ name: String, output: Int, extra: String = "") {
        f.view.feed(Array("$ \(name)\(extra)".utf8)[...])
        f.view.heldCommandSent()
        f.view.feed(Array("\r\n".utf8)[...])
        for i in 0..<output { f.view.feed(Array("\(name)-out-\(i)\r\n".utf8)[...]) }
    }

    static func make(_ commands: Int, output: Int = 40, scrollback: Int = 2000, prompt: Bool = true) throws -> Fixture {
        let f = try Fixture(lines: [], scrollback: scrollback)
        for c in 1...max(commands, 1) where commands > 0 { run(f, "c\(c)", output: output) }
        if prompt { f.view.feed(Array("$ ".utf8)[...]) }
        return f
    }

    /// The text of the row at buffer row `row` of the live terminal.
    static func text(_ view: TetherTerminalView, row: Int) -> String {
        let t = view.getTerminal()
        return t.getLine(row: row - t.getTopVisibleRow())?.translateToString(trimRight: true) ?? "?"
    }

    /// The command line jumped to (the live terminal), "-" when none.
    static func landed(_ f: Fixture) -> String { f.view.jumpCursor.map { text(f.view, row: $0) } ?? "-" }

    /// Scrolls the live terminal so the line starting with `prefix` is at the top.
    static func scroll(_ f: Fixture, toLineStarting prefix: String) {
        let t = f.view.getTerminal()
        let trimmed = t.buffer.totalLinesTrimmed
        let row = (0..<f.view.bufferLineCount).first {
            t.getScrollInvariantLine(row: $0 + trimmed)?.translateToString(trimRight: true).hasPrefix(prefix) == true
        }
        f.view.scrollTo(row: row ?? 0)
    }

    static func atBottom(_ f: Fixture) -> Bool {
        f.view.getTerminal().buffer.yDisp >= f.view.bufferLineCount - f.view.getTerminal().rows
    }

    @Test func jumpsGoOnFromWhereTheViewWasScrolledTo() throws {
        let f = try Self.make(6)
        f.view.jumpToMark(up: true)
        #expect(Self.landed(f) == "$ c6")
        f.view.jumpToMark(up: true)
        #expect(Self.landed(f) == "$ c5")
        // Scrolled with the wheel or the scroller since: from what is on screen, not from c5.
        Self.scroll(f, toLineStarting: "c2-out-10")
        f.view.jumpToMark(up: true)
        #expect(Self.landed(f) == "$ c2", "the nearest command above the screen (\(Self.landed(f)))")
        Self.scroll(f, toLineStarting: "c3-out-5")
        f.view.jumpToMark(up: false)
        #expect(Self.landed(f) == "$ c4", "the nearest command below (\(Self.landed(f)))")
        // Not scrolled since: on from the command jumped to.
        f.view.jumpToMark(up: false)
        #expect(Self.landed(f) == "$ c5")
    }

    @Test func scrolledFromThePromptUpGoesToTheCommandAboveTheScreen() throws {
        let f = try Self.make(6)
        Self.scroll(f, toLineStarting: "c3-out-10")
        f.view.jumpToMark(up: true)
        #expect(Self.landed(f) == "$ c3", "\(Self.landed(f))")
        // Typed since (the view still scrolled back): from the line being typed on again.
        Self.scroll(f, toLineStarting: "c3-out-10")
        f.view.sendsAreTyping = true
        f.view.send(source: f.view, data: Array("l".utf8)[...])
        f.view.jumpToMark(up: true)
        #expect(Self.landed(f) == "$ c6", "\(Self.landed(f))")
    }

    @Test func atTheLivePromptDownStaysThere() throws {
        let f = try Self.make(3, output: 2)       // every command on screen
        let beeps = f.view.beeps
        f.view.jumpToMark(up: false)
        #expect(f.view.jumpCursor == nil, "no command on screen is jumped to (\(Self.landed(f)))")
        #expect(Self.atBottom(f))
        #expect(f.view.beeps == beeps + 1)
        // From the prompt: the last command, though it is on screen.
        f.view.jumpToMark(up: true)
        #expect(Self.landed(f) == "$ c3")
        // Down past the last one: the line being typed on, then nowhere further.
        f.view.jumpToMark(up: false)
        #expect(f.view.jumpCursor == nil && Self.atBottom(f))
        f.view.jumpToMark(up: false)
        #expect(f.view.beeps == beeps + 2 && Self.atBottom(f))
    }

    @Test func theFirstCommandIsTheLastStopUpwards() throws {
        let f = try Self.make(3, output: 30)
        for _ in 0..<3 { f.view.jumpToMark(up: true) }
        #expect(Self.landed(f) == "$ c1")
        let beeps = f.view.beeps
        let top = f.view.getTerminal().buffer.yDisp
        f.view.jumpToMark(up: true)
        f.view.jumpToMark(up: true)
        #expect(Self.landed(f) == "$ c1" && f.view.getTerminal().buffer.yDisp == top, "stays (\(Self.landed(f)))")
        #expect(f.view.beeps == beeps + 2)
        f.view.jumpToMark(up: false)
        #expect(Self.landed(f) == "$ c2")
    }

    @Test func commandsWithoutOutput() throws {
        let f = try Fixture(lines: [], scrollback: 2000)
        Self.run(f, "c1", output: 50)
        Self.run(f, "c2", output: 0)
        Self.run(f, "c3", output: 0)
        Self.run(f, "c4", output: 50)
        f.view.feed(Array("$ ".utf8)[...])
        var seen: [String] = []
        for _ in 0..<4 { f.view.jumpToMark(up: true); seen.append(Self.landed(f)) }
        #expect(seen == ["$ c4", "$ c3", "$ c2", "$ c1"])
        f.view.jumpToMark(up: false)
        f.view.selectToMark(up: false)
        #expect(f.view.getSelection()?.trimmingCharacters(in: .whitespacesAndNewlines) == "$ c2", "\(f.view.getSelection() ?? "")")
    }

    /// A command line longer than the terminal is wide: jumped to on its first row (the prompt), and
    /// selected from there.
    @Test func aWrappedCommandLineIsJumpedToOnItsFirstRow() throws {
        let f = try Fixture(lines: [], scrollback: 2000)
        Self.run(f, "c1", output: 40)
        Self.run(f, "long", output: 40, extra: " " + String(repeating: "x", count: 190))
        Self.run(f, "c3", output: 40)
        f.view.feed(Array("$ ".utf8)[...])
        f.view.jumpToMark(up: true)
        f.view.jumpToMark(up: true)
        #expect(Self.landed(f).hasPrefix("$ long"), "\(Self.landed(f))")
        // The next one up is the command before it (not the long line's own first row), and back.
        f.view.jumpToMark(up: true)
        #expect(Self.landed(f) == "$ c1", "\(Self.landed(f))")
        f.view.jumpToMark(up: false)
        #expect(Self.landed(f).hasPrefix("$ long"), "\(Self.landed(f))")
        f.view.selectToMark(up: true)
        let selected = f.view.getSelection() ?? ""
        #expect(selected.hasPrefix("$ long") && selected.contains("long-out-39") && !selected.contains("c3"), "\(selected.prefix(90))")
    }

    /// Output goes on (old lines leave the top of a full scrollback) while the user is scrolled
    /// back at a command: the next jump goes on from that command.
    @Test func outputStreamingWhileJumping() throws {
        let f = try Self.make(4, output: 60, scrollback: 300, prompt: false)
        f.view.jumpToMark(up: true)
        f.view.jumpToMark(up: true)
        #expect(Self.landed(f) == "$ c3", "\(Self.landed(f))")
        for i in 0..<100 { f.view.feed(Array("stream-\(i)\r\n".utf8)[...]) }
        #expect(f.view.getTerminal().buffer.totalLinesTrimmed > 0, "old lines left")
        f.view.jumpToMark(up: true)
        #expect(Self.landed(f) == "$ c2", "\(Self.landed(f))")
        f.view.jumpToMark(up: false)
        #expect(Self.landed(f) == "$ c3", "\(Self.landed(f))")
    }

    @Test func aFullScreenProgramUpJumpsNowhere() throws {
        let f = try Self.make(3, output: 30)
        f.view.feed(Array("\u{1b}[?1049h\u{1b}[Hvim screen".utf8)[...])
        let beeps = f.view.beeps
        f.view.jumpToMark(up: true)
        f.view.selectToMark(up: true)
        #expect(f.view.jumpCursor == nil && !f.view.selectionActive)
        #expect(f.view.beeps == beeps + 2)
        #expect(f.view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true) == "vim screen")
        f.view.feed(Array("\u{1b}[?1049l".utf8)[...])
        f.view.jumpToMark(up: true)
        #expect(Self.landed(f) == "$ c3")
    }

    /// A find showed a match: ⌘↑ goes to the command whose output it is in.
    @Test func fromAFindMatchUpGoesToItsCommand() throws {
        let f = try Self.make(6)
        f.view.setFind(TerminalFindQuery(term: "c2-out-30"))
        f.view.jumpToMark(up: true)
        #expect(Self.landed(f) == "$ c2", "\(Self.landed(f))")
        f.view.setFind(TerminalFindQuery(term: "c4-out-30"))
        f.view.jumpToMark(up: false)
        #expect(Self.landed(f) == "$ c5", "\(Self.landed(f))")
        f.view.setFind(nil)
    }

    @Test func shiftSelectsWholeCommandsBothWays() throws {
        let f = try Self.make(6, output: 5)
        func selected() -> [String] {
            (f.view.getSelection() ?? "").components(separatedBy: "\n").filter { $0.hasPrefix("$ ") }
        }
        for _ in 0..<3 { f.view.jumpToMark(up: true) }
        f.view.selectToMark(up: true)
        #expect(selected() == ["$ c4"], "the command jumped to (\(selected()))")
        f.view.selectToMark(up: true)
        #expect(selected() == ["$ c3", "$ c4"])
        f.view.selectToMark(up: false)
        #expect(selected() == ["$ c3", "$ c4", "$ c5"])
        // Without a jump, scrolled back: the command at the top of the screen.
        let g = try Self.make(6, output: 40)
        Self.scroll(g, toLineStarting: "c3-out-10")
        g.view.selectToMark(up: true)
        let first = (g.view.getSelection() ?? "").components(separatedBy: "\n").first ?? ""
        #expect(first == "$ c3", "\(first)")
    }

    /// The window made narrower (lines wrap again): the command jumped to and the next ones stay.
    @Test func aResizeKeepsTheCommandJumpedTo() throws {
        let f = try Fixture(lines: [], scrollback: 2000)
        f.view.setFrameSize(NSSize(width: 900, height: 400))
        let wide = f.view.getTerminal().cols
        for c in 1...5 {
            Self.run(f, "c\(c)", output: 0)
            for i in 0..<30 { f.view.feed(Array(("\(i) " + String(repeating: "w", count: wide - 8) + "\r\n").utf8)[...]) }
        }
        f.view.feed(Array("$ ".utf8)[...])
        f.view.jumpToMark(up: true)
        f.view.jumpToMark(up: true)
        #expect(Self.landed(f) == "$ c4")
        f.view.setFrameSize(NSSize(width: 450, height: 400))
        #expect(f.view.getTerminal().cols < wide)
        f.view.jumpToMark(up: true)
        #expect(Self.landed(f) == "$ c3", "\(Self.landed(f))")
    }

    // MARK: Commands in the recording

    /// A tab restored after Tether reopened: its output (and the command markers in it) shown
    /// again from the recording; only the last command is still in memory.
    static func restored(commands: Int = 8, output: Int = 300) throws -> Fixture {
        let f = try Fixture(lines: [], scrollback: 500, maxLines: 1500, chunk: 400)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for c in 1...commands {
            let line = Array("$ run \(c)".utf8)
            f.recorder.append(line)
            let time = start.addingTimeInterval(Double(c))
            f.recorder.markCommand(at: time)
            f.recorder.append(Array("\r\n".utf8))
            var bytes = line + RecordingIndex.markBytes(at: time) + Array("\r\n".utf8)
            var out: [UInt8] = []
            for i in 1...output { out += Array("out \(c)-\(i)\r\n".utf8) }
            f.recorder.append(out)
            bytes += out
            f.view.showEarlierOutput(bytes[...])
        }
        f.recorder.append(Array("$ ".utf8))
        f.view.showEarlierOutput(Array("$ ".utf8)[...])
        return f
    }

    /// The command line shown near the top of the view (the live terminal or the history view).
    static func shownCommand(_ f: Fixture) -> String {
        let t = f.shown.getTerminal()
        return (0..<min(t.rows, 4)).compactMap { t.getLine(row: $0)?.translateToString(trimRight: true) }
            .first { $0.hasPrefix("$ run") } ?? "-"
    }

    static func settle(_ f: Fixture) async throws {
        for _ in 0..<300 {
            try await Task.sleep(for: .milliseconds(10))
            if f.view.history?.loading != true { try await Task.sleep(for: .milliseconds(30)); if f.view.history?.loading != true { return } }
        }
    }

    @Test func jumpsInTheRecordingGoOnFromWhereTheViewIs() async throws {
        let f = try Self.restored()
        f.view.jumpToMark(up: true)
        #expect(!f.view.isBrowsingHistory && Self.shownCommand(f) == "$ run 8", "in memory (\(Self.shownCommand(f)))")
        f.view.jumpToMark(up: true)
        try await Self.settle(f)
        #expect(f.view.isBrowsingHistory && Self.shownCommand(f) == "$ run 7", "\(Self.shownCommand(f))")
        f.view.jumpToMark(up: true)
        try await Self.settle(f)
        #expect(Self.shownCommand(f) == "$ run 6", "\(Self.shownCommand(f))")
        // Scrolled (the wheel) to the output of run 6: ⌘↑ goes to run 6, not to run 5.
        let h = try #require(f.view.history)
        let t = h.getTerminal()
        let row = try #require((0..<h.bufferRows).first {
            t.getScrollInvariantLine(row: $0 + t.buffer.totalLinesTrimmed)?.translateToString(trimRight: true) == "out 6-200"
        })
        h.scrollTo(row: row)
        try await Self.settle(f)
        f.view.jumpToMark(up: true)
        try await Self.settle(f)
        #expect(Self.shownCommand(f) == "$ run 6", "the command above the screen (\(Self.shownCommand(f)))")
        // ⇧⌘↑ right after a jump: that command.
        f.view.jumpToMark(up: true)
        try await Self.settle(f)
        #expect(Self.shownCommand(f) == "$ run 5")
        f.view.selectToMark(up: true)
        try await Self.settle(f)
        #expect(f.view.commandSelection == .init(first: 4, end: 5), "\(String(describing: f.view.commandSelection))")
    }

    @Test func fastPressesAreEachCounted() async throws {
        let f = try Self.restored()
        for _ in 0..<4 { f.view.jumpToMark(up: true) }
        try await Self.settle(f)
        try await Self.settle(f)
        #expect(Self.shownCommand(f) == "$ run 5", "four commands up (\(Self.shownCommand(f)))")
        f.view.jumpToMark(up: false)
        f.view.jumpToMark(up: false)
        try await Self.settle(f)
        #expect(Self.shownCommand(f) == "$ run 7", "\(Self.shownCommand(f))")
    }

    /// ⌘↑ while a part of the recording is being read (scrolled ahead): done once it is in, from
    /// the command shown before.
    @Test func aJumpWhileAPartIsBeingReadWaitsForIt() async throws {
        let f = try Self.restored()
        f.view.jumpToMark(up: true)
        f.view.jumpToMark(up: true)
        f.view.jumpToMark(up: true)
        try await Self.settle(f)
        #expect(Self.shownCommand(f) == "$ run 6")
        let h = try #require(f.view.history)
        h.slide(up: true)
        #expect(h.loading, "a part is being read")
        f.view.jumpToMark(up: true)
        try await Self.settle(f)
        try await Self.settle(f)
        #expect(f.view.isBrowsingHistory && Self.shownCommand(f) == "$ run 5", "\(Self.shownCommand(f))")
    }

    /// Down from the recording: the commands in memory, then the line being typed on, then nowhere.
    @Test func downFromTheRecordingReachesMemoryThenThePrompt() async throws {
        let f = try Self.restored()
        f.view.jumpToMark(up: true)
        f.view.jumpToMark(up: true)
        try await Self.settle(f)
        #expect(f.view.isBrowsingHistory && Self.shownCommand(f) == "$ run 7")
        f.view.jumpToMark(up: false)
        try await Self.settle(f)
        #expect(!f.view.isBrowsingHistory && Self.landed(f) == "$ run 8", "\(Self.landed(f))")
        f.view.jumpToMark(up: false)
        #expect(f.view.jumpCursor == nil && Self.atBottom(f))
        let beeps = f.view.beeps
        f.view.jumpToMark(up: false)
        #expect(f.view.beeps == beeps + 1 && Self.atBottom(f))
        // And back up across the seam.
        f.view.jumpToMark(up: true)
        f.view.jumpToMark(up: true)
        try await Self.settle(f)
        #expect(f.view.isBrowsingHistory && Self.shownCommand(f) == "$ run 7", "\(Self.shownCommand(f))")
    }

    /// Only the recording has the commands (none marked in memory): past the last, the prompt.
    @Test func pastTheLastRecordedCommandIsThePrompt() async throws {
        let f = try Fixture(lines: [], scrollback: 500)
        for c in 1...3 {
            f.recorder.append(Array("$ run \(c)".utf8)); f.view.feed(Array("$ run \(c)".utf8)[...])
            f.recorder.markCommand()
            for i in 1...800 { let b = Array("\r\nout \(c)-\(i)".utf8); f.view.feed(b[...]); f.recorder.append(b) }
            f.recorder.append(Array("\r\n".utf8)); f.view.feed(Array("\r\n".utf8)[...])
        }
        f.recorder.append(Array("$ ".utf8)); f.view.feed(Array("$ ".utf8)[...])
        f.view.jumpToMark(up: true)
        try await Self.settle(f)
        #expect(Self.shownCommand(f) == "$ run 3")
        f.view.jumpToMark(up: false)
        try await Self.settle(f)
        #expect(!f.view.isBrowsingHistory && Self.atBottom(f))
        let beeps = f.view.beeps
        f.view.jumpToMark(up: false)
        #expect(f.view.beeps == beeps + 1)
    }

    // MARK: Review findings

    /// A full-screen program started in the live terminal while the recording was browsed: ⌘↓ into
    /// memory goes back to it and beeps, marking nothing on the program's screen.
    @Test func downIntoMemoryWhileAFullScreenProgramIsUp() async throws {
        let f = try Self.restored()
        f.view.jumpToMark(up: true)
        f.view.jumpToMark(up: true)
        try await Self.settle(f)
        #expect(f.view.isBrowsingHistory && Self.shownCommand(f) == "$ run 7")
        f.view.feed(Array("\u{1b}[?1049h\u{1b}[Hvim screen".utf8)[...])
        let beeps = f.view.beeps
        f.view.jumpToMark(up: false)
        #expect(!f.view.isBrowsingHistory)
        #expect(f.view.beeps == beeps + 1, "nowhere to go on the program's screen")
        f.view.feed(Array("\u{1b}[?1049l".utf8)[...])
        f.view.jumpToMark(up: true)
        #expect(Self.landed(f) == "$ run 8", "from the prompt, not from a place set on the program's screen (\(Self.landed(f)))")
    }

    /// A selection of whole commands whose first lines left memory as output went on: ⇧⌘↓ extends
    /// what is still there.
    @Test func extendingASelectionWhoseStartLeftMemory() throws {
        let f = try Self.make(4, output: 60, scrollback: 300, prompt: false)
        for _ in 0..<4 { f.view.jumpToMark(up: true) }
        #expect(Self.landed(f) == "$ c1")
        f.view.selectToMark(up: false)
        #expect(f.view.getSelection()?.hasPrefix("$ c1") == true)
        for i in 0..<120 { f.view.feed(Array("stream-\(i)\r\n".utf8)[...]) }
        #expect(f.view.getTerminal().buffer.totalLinesTrimmed > 5, "c1's line left memory")
        f.view.selectToMark(up: false)
        let selected = f.view.getSelection() ?? ""
        #expect(selected.contains("c1-out-59") && selected.contains("$ c2") && selected.contains("c2-out-59") && !selected.contains("$ c3"),
                "\(selected.prefix(60))")
    }

    /// After a jump, the find's match moved to another line on the same screen (no scroll): ⌘↓ / ⌘↑
    /// go from the match.
    @Test func aFindMatchChosenAfterAJumpIsTheNewPlace() throws {
        let f = try Self.make(6, output: 5)
        for _ in 0..<3 { f.view.jumpToMark(up: true) }
        #expect(Self.landed(f) == "$ c4")
        let top = f.view.getTerminal().buffer.yDisp
        f.view.setFind(TerminalFindQuery(term: "c5-out-2"))
        #expect(f.view.getTerminal().buffer.yDisp == top, "the match is on screen: no scroll")
        f.view.jumpToMark(up: false)
        #expect(Self.landed(f) == "$ c6", "\(Self.landed(f))")
        f.view.setFind(nil)
    }

    /// ⌘K while a jump into the recording is on its way (or while browsing): the cleared terminal,
    /// not the recording over it.
    @Test func clearingTheTerminalEndsBrowsingAndJumps() async throws {
        let f = try Self.restored()
        f.view.jumpToMark(up: true)
        f.view.jumpToMark(up: true)       // being read
        f.view.clearBuffer()
        try await Self.settle(f)
        #expect(!f.view.isBrowsingHistory, "a load on its way is not shown")
        let g = try Self.restored()
        g.view.jumpToMark(up: true)
        g.view.jumpToMark(up: true)
        try await Self.settle(g)
        #expect(g.view.isBrowsingHistory)
        g.view.selectToMark(up: true)
        try await Self.settle(g)
        #expect(g.view.commandSelection != nil)
        g.view.clearBuffer()
        #expect(!g.view.isBrowsingHistory && g.view.commandSelection == nil)
    }

    /// The newest command is in memory but the recording's index has not noted it yet: ⌘↓ from the
    /// recording's last command goes to it, not past it to the prompt.
    @Test func aCommandTheRecordingHasNotNotedYetIsNotSkipped() async throws {
        let f = try Self.restored(output: 600)        // run 8 left memory
        let later = Date(timeIntervalSince1970: 1_700_000_100)
        var bytes = Array("new-cmd".utf8) + RecordingIndex.markBytes(at: later) + Array("\r\n".utf8)
        for i in 0..<5 { bytes += Array("new-out-\(i)\r\n".utf8) }
        bytes += Array("$ ".utf8)
        f.view.showEarlierOutput(bytes[...])
        f.view.jumpToMark(up: true)
        #expect(Self.landed(f) == "$ new-cmd", "\(Self.landed(f))")
        f.view.jumpToMark(up: true)
        try await Self.settle(f)
        #expect(f.view.isBrowsingHistory && Self.shownCommand(f) == "$ run 8", "\(Self.shownCommand(f))")
        f.view.jumpToMark(up: false)
        try await Self.settle(f)
        #expect(!f.view.isBrowsingHistory && Self.landed(f) == "$ new-cmd", "\(Self.landed(f))")
    }
}
