import AppKit
import Testing
import TetherCore
import SwiftTerm
@testable import RecordingKit
@testable import TerminalText
@testable import SessionKit
@testable import TerminalUI

/// ⌘↑ / ⌘↓ select the command itself (what was typed after the prompt), as the terminal and the
/// recording showed it — for shells and for programs that draw more around the line typed on.
@MainActor
@Suite(.serialized) struct CommandSelectTests {
    typealias Fixture = HistoryBrowsingTests.Fixture

    /// The prompt drawn, `command` typed (the first key notes where typing starts) and run.
    static func type(_ f: Fixture, prompt: String, _ command: String, output: Int) {
        f.view.feed(Array(prompt.utf8)[...])
        f.view.sendsAreTyping = true
        f.view.send(source: f.view, data: Array(command.prefix(1).utf8)[...])
        f.view.sendsAreTyping = nil
        f.view.feed(Array(command.utf8)[...])
        f.view.heldCommandSent()
        f.view.feed(Array("\r\n".utf8)[...])
        for i in 0..<output { f.view.feed(Array("\(command)-out-\(i)\r\n".utf8)[...]) }
    }

    static func selected(_ view: TerminalView) -> String {
        view.selection.active ? view.selection.getSelectedText() : "-"
    }

    @Test func upSelectsTheCommandWithoutThePrompt() throws {
        let f = try Fixture(lines: [], scrollback: 2000)
        for c in 1...3 { Self.type(f, prompt: "user@host ~/dir % ", "make c\(c)", output: 30) }
        f.view.feed(Array("user@host ~/dir % ".utf8)[...])
        f.view.jumpToMark(up: true)
        #expect(Self.selected(f.view) == "make c3")
        f.view.jumpToMark(up: true)
        #expect(Self.selected(f.view) == "make c2")
        f.view.jumpToMark(up: false)
        #expect(Self.selected(f.view) == "make c3")
    }

    @Test func aWrappedCommandIsSelectedWhole() throws {
        let f = try Fixture(lines: [], scrollback: 2000)
        let long = "echo " + String(repeating: "abcdefghij", count: 12)
        Self.type(f, prompt: "$ ", long, output: 10)
        Self.type(f, prompt: "$ ", "ls", output: 10)
        f.view.feed(Array("$ ".utf8)[...])
        f.view.jumpToMark(up: true)
        f.view.jumpToMark(up: true)
        #expect(Self.selected(f.view).replacingOccurrences(of: "\n", with: "") == long)
    }

    /// A REPL (no shell): its own prompt, typing after it.
    @Test func aProgramsOwnPromptIsLeftOut() throws {
        let f = try Fixture(lines: [], scrollback: 2000)
        Self.type(f, prompt: ">>> ", "print(1 + 1)", output: 1)
        Self.type(f, prompt: "mysql> ", "select * from t;", output: 3)
        f.view.feed(Array(">>> ".utf8)[...])
        f.view.jumpToMark(up: true)
        #expect(Self.selected(f.view) == "select * from t;")
        f.view.jumpToMark(up: true)
        #expect(Self.selected(f.view) == "print(1 + 1)")
    }

    /// ⇧⌘↑ after ⌘↑: whole commands from the one selected (as before), upwards.
    @Test func shiftAfterUpSelectsWholeCommands() throws {
        let f = try Fixture(lines: [], scrollback: 2000)
        for c in 1...3 { Self.type(f, prompt: "$ ", "c\(c)", output: 2) }
        f.view.feed(Array("$ ".utf8)[...])
        f.view.jumpToMark(up: true)
        f.view.selectToMark(up: true)
        #expect(Self.selected(f.view).hasPrefix("$ c3"))
        f.view.selectToMark(up: true)
        let text = Self.selected(f.view)
        #expect(text.hasPrefix("$ c2") && text.contains("c3-out-1"), "\(text)")
    }

    // MARK: In the recording

    /// An agent-like program: the line typed on with a footer drawn below it, the cursor taken
    /// back up to the line; the recording's last line break before Return is the footer's.
    static func footerSession(commands: Int = 8, output: Int = 300) throws -> Fixture {
        let f = try Fixture(lines: [], scrollback: 500, maxLines: 1500, chunk: 400)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for c in 1...commands {
            let typed = Array("> run \(c)\r\n-- footer --\u{1b}[1A\r\u{1b}[\(7 + String(c).count)C".utf8)
            f.recorder.append(typed)
            let time = start.addingTimeInterval(Double(c))
            f.recorder.markCommand(at: time, column: 2)
            var out: [UInt8] = Array("\r\n\u{1b}[2K".utf8)
            for i in 1...output { out += Array("out \(c)-\(i)\r\n".utf8) }
            f.recorder.append(out)
            f.view.showEarlierOutput((typed + RecordingIndex.markBytes(at: time, column: 2) + out)[...])
        }
        let prompt = Array("> ".utf8)
        f.recorder.append(prompt)
        f.view.showEarlierOutput(prompt[...])
        return f
    }

    @Test func commandsInTheRecordingAreSelectedOnTheirLine() async throws {
        let f = try Self.footerSession()
        f.view.jumpToMark(up: true)
        #expect(!f.view.isBrowsingHistory)
        #expect(Self.selected(f.view) == "run 8")
        for c in stride(from: 7, through: 4, by: -1) {
            f.view.jumpToMark(up: true)
            try await CommandJumpTests.settle(f)
            #expect(f.view.isBrowsingHistory)
            #expect(Self.selected(f.shown) == "run \(c)", "command \(c)")
        }
        f.view.jumpToMark(up: false)
        try await CommandJumpTests.settle(f)
        #expect(Self.selected(f.shown) == "run 5")
    }

    /// Up to the first command and down again to the prompt, one at a time, while the parts of the
    /// recording shown change underneath (more commands than one part holds).
    @Test func everyCommandInTurnBothWays() async throws {
        let f = try Self.footerSession(commands: 14, output: 260)
        var seen: [String] = []
        for _ in 0..<14 {
            f.view.jumpToMark(up: true)
            try await CommandJumpTests.settle(f)
            seen.append(Self.selected(f.shown))
        }
        #expect(seen == (1...14).reversed().map { "run \($0)" }, "\(seen)")
        f.view.jumpToMark(up: true)
        try await CommandJumpTests.settle(f)
        #expect(f.view.beeps == 1, "none before the first")
        seen = []
        for _ in 0..<13 {
            f.view.jumpToMark(up: false)
            try await CommandJumpTests.settle(f)
            seen.append(Self.selected(f.shown))
        }
        #expect(seen == (2...14).map { "run \($0)" }, "\(seen)")
    }

    /// Return pressed while a program's output goes on (nothing before the cursor) runs no
    /// command: no mark is made, and such marks an earlier version wrote in the recording are
    /// gone past by ⌘↑ / ⌘↓.
    @Test func returnPressedDuringOutputIsNoCommand() async throws {
        let f = try Fixture(lines: [], scrollback: 500, maxLines: 1500, chunk: 400)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func record(_ s: String) {
            let b = Array(s.utf8)
            f.recorder.append(b)
            f.view.showEarlierOutput(b[...])
        }
        for c in 1...6 {
            record("$ run \(c)")
            let time = start.addingTimeInterval(Double(c * 10))
            f.recorder.markCommand(at: time)
            f.view.showEarlierOutput(RecordingIndex.markBytes(at: time)[...])
            record("\r\n")
            for i in 1...150 {
                record("out \(c)-\(i)\r\n")
                // Return pressed twice while the output goes on (an earlier version marked it).
                if i == 50 || i == 120 {
                    let extra = start.addingTimeInterval(Double(c * 10 + i / 50))
                    f.recorder.markCommand(at: extra)
                    f.view.showEarlierOutput(RecordingIndex.markBytes(at: extra)[...])
                }
            }
        }
        record("$ ")
        var seen: [String] = []
        for _ in 0..<6 {
            f.view.jumpToMark(up: true)
            try await CommandJumpTests.settle(f)
            seen.append(Self.selected(f.shown))
        }
        #expect(seen == (1...6).reversed().map { "$ run \($0)" }, "\(seen)")
        seen = []
        for _ in 0..<5 {
            f.view.jumpToMark(up: false)
            try await CommandJumpTests.settle(f)
            seen.append(Self.selected(f.shown))
        }
        #expect(seen == (2...6).map { "$ run \($0)" }, "\(seen)")
        // Now: Return alone while output goes on makes no mark; typed ahead of a prompt not drawn
        // yet, a command does.
        let g = try Fixture(lines: [], scrollback: 500)
        g.view.marksWhileOffline = true
        g.view.sendsAreTyping = true
        func press(_ s: String) { g.view.send(source: g.view, data: Array(s.utf8)[...]) }
        g.view.feed(Array("$ ".utf8)[...])
        press("make")
        g.view.feed(Array("make".utf8)[...])
        press("\r")
        g.view.feed(Array("\r\nbuilding 1\r\n".utf8)[...])
        press("\r")                                              // during the output
        g.view.feed(Array("\r\nbuilding 2\r\n".utf8)[...])
        press("ls\r")                                            // typed ahead
        g.view.feed(Array("done\r\n$ ls\r\nfile\r\n$ ".utf8)[...])
        g.view.sendsAreTyping = nil
        g.view.jumpToMark(up: true)
        #expect(g.view.selection.active && g.view.selection.getSelectedText().isEmpty == false)
        g.view.jumpToMark(up: true)
        #expect(Self.selected(g.view) == "make", "the Return during the output is passed")
        g.view.jumpToMark(up: true)
        #expect(g.view.beeps == 1, "no other command")
    }

    /// ⌘C and the right-click menu copy what is selected in the recording shown.
    @Test func copyingFromTheRecording() async throws {
        let f = try Self.footerSession()
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        #expect(!f.view.validateUserInterfaceItem(copy), "nothing selected")
        f.view.jumpToMark(up: true)
        f.view.jumpToMark(up: true)
        try await CommandJumpTests.settle(f)
        #expect(f.view.isBrowsingHistory && Self.selected(f.shown) == "run 7")
        #expect(f.view.validateUserInterfaceItem(copy), "the recording's selection")
        let menu = try #require(f.view.history?.menu(for: NSEvent()))
        #expect(menu.items.map(\.title) == ["Copy", "Paste", "Select All"])
        #expect(menu.items.allSatisfy { ($0.target as? TetherTerminalView) === f.view })
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer { pasteboard.clearContents(); if let saved { pasteboard.setString(saved, forType: .string) } }
        f.view.copy(copy)
        #expect(pasteboard.string(forType: .string) == "run 7")
    }

    /// The next command typed while a program still prints (`git pull` while `docker compose`
    /// finishes): marked on the line where the shell shows it, below the output — not on the
    /// output line the cursor was on when Return was pressed.
    @Test func aCommandTypedAheadIsMarkedWhereTheShellShowsIt() throws {
        let f = try Fixture(lines: [], scrollback: 500)
        f.view.marksWhileOffline = true
        f.view.sendsAreTyping = true
        defer { f.view.sendsAreTyping = nil }
        func press(_ s: String) { f.view.send(source: f.view, data: Array(s.utf8)[...]) }
        func out(_ s: String) { f.view.feed(Array(s.utf8)[...]) }
        out("➜ proj ✗ ")
        press("docker compose down")
        out("docker compose down")
        press("\r")
        out("\r\n")
        for i in 0..<10 { out(" ✔ Container c\(i)  Removed\r\n") }
        out(" ✔ Container c10  Removed")
        press("git pull\r")                                     // typed ahead, echoed nowhere
        for i in 11..<20 { out("\r\n ✔ Container c\(i)  Removed") }
        out("\r\n➜ proj ✗ git pull\r\nAlready up to date.\r\n➜ proj ✗ ")
        f.view.jumpToMark(up: true)
        #expect(Self.selected(f.view) == "git pull")
        f.view.jumpToMark(up: true)
        #expect(Self.selected(f.view) == "docker compose down")
    }

    /// The recording notes a command typed ahead when the shell showed it: its line is found by
    /// the lines up from the cursor there.
    @Test func aCommandTypedAheadIsFoundInTheRecording() async throws {
        let f = try Fixture(lines: [], scrollback: 500, maxLines: 1500, chunk: 400)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func record(_ s: String) { let b = Array(s.utf8); f.recorder.append(b); f.view.showEarlierOutput(b[...]) }
        func mark(_ n: Int, up: Int) {
            let time = start.addingTimeInterval(Double(n))
            f.recorder.markCommand(at: time, column: 2, up: up)
            f.view.showEarlierOutput(RecordingIndex.markBytes(at: time, column: 2, up: up)[...])
        }
        for c in 1...6 {
            record("$ run \(c)")
            mark(c * 10, up: 0)
            record("\r\n")
            for i in 1...150 { record("out \(c)-\(i)\r\n") }
            // Typed ahead: the shell shows it, its output follows, then the mark (two lines up).
            record("$ next \(c)\r\nok \(c)\r\n")
            mark(c * 10 + 1, up: 2)
            for i in 1...150 { record("more \(c)-\(i)\r\n") }
        }
        record("$ ")
        var seen: [String] = []
        for _ in 0..<12 {
            f.view.jumpToMark(up: true)
            try await CommandJumpTests.settle(f)
            seen.append(Self.selected(f.shown))
        }
        #expect(seen == (1...6).reversed().flatMap { ["next \($0)", "run \($0)"] }, "\(seen)")
    }

    /// Markers with and without the column, and the column survives indexing a recording again.
    @Test func markersCarryTheColumn() {
        let time = Date(timeIntervalSince1970: 1_700_000_000.123)
        #expect(RecordingIndex.parseMark(Array("1700000000123".utf8))?.column == nil)
        #expect(RecordingIndex.parseMark(Array("1700000000123;col=14".utf8))?.column == 14)
        #expect(RecordingIndex.parseMark(Array("1700000000123;col=14".utf8))?.time == time)
        #expect(RecordingIndex.parseMark(Array("x;col=1".utf8)) == nil)
        #expect(RecordingIndex.parseMark(Array("1700000000123;col=2;up=3".utf8))?.up == 3)
        #expect(RecordingIndex.parseMark(Array(RecordingIndex.markBytes(at: time, column: 2, up: 3).dropFirst(12).dropLast()))?.up == 3)
        let bytes = RecordingIndex.markBytes(at: time, column: 3)
        #expect(ScrollbackRule.typingMarkers(in: bytes[...]) == 1, "still counts as typing")
        var index = RecordingIndex()
        index.add(Array("$ ls".utf8))
        index.addMark(at: time, column: 2)
        #expect(index.marks.last?.column == 2 && index.marks.last?.at == 4 && index.marks.last?.offset == 0)
    }
}
