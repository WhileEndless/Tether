import AppKit
import Testing
import TetherCore
import SwiftTerm
@testable import RecordingKit
@testable import SessionKit
@testable import TerminalUI

/// ⌘G / ⇧⌘G through matches in the recording where output was redrawn in place (progress, a
/// coding agent): the search knows a line only by where it left the screen, long after it was
/// written, so every step goes to the next match in the text — never skipping, never back.
@MainActor
@Suite(.serialized) struct FindInRecordingTests {
    typealias Fixture = HistoryBrowsingTests.Fixture

    /// Output, also recorded.
    static func out(_ f: Fixture, _ s: String) {
        let b = Array(s.utf8)
        f.view.feed(b[...]); f.recorder.append(b)
    }

    /// Blocks of progress redrawn in place (many line breaks, few rows left), each ending with the
    /// same line, then its number.
    @Test func findStepsInOrderThroughRedrawnOutput() async throws {
        let f = try Fixture(lines: [], scrollback: 300, maxLines: 1500, chunk: 400, cols: 100)
        for b in 1...40 {
            for fr in 0..<25 {
                var s = fr == 0 ? "" : "\u{1b}[6A"
                for l in 0..<6 { s += " step \(l) of block \(b) at \(fr)\u{1b}[K\r\n" }
                Self.out(f, s)
            }
            Self.out(f, "needle done\r\nblock \(b)\r\n")
        }
        for i in 0..<400 { Self.out(f, "tail \(i)\r\n") }
        var status = TerminalFindStatus()
        f.view.onFindStatus = { status = $0 }
        f.view.setFind(TerminalFindQuery(term: "needle"))
        for _ in 0..<500 where status.total < 40 || status.searchingRecording { try await Task.sleep(for: .milliseconds(10)) }
        #expect(status.total == 40)
        var seen: [String] = []
        for _ in 0..<40 {
            f.view.findStep(forward: true)
            for _ in 0..<300 where f.view.history?.loading == true || f.view.history?.selection.active != true {
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(30))
            guard let h = f.view.history, h.selection.active else { seen.append("-"); continue }
            let t = h.getTerminal()
            let row = h.selection.start.row - t.buffer.yDisp
            let next = t.getLine(row: row + 1)?.translateToString(trimRight: true) ?? "?"
            seen.append("\(status.current):" + next.replacingOccurrences(of: "block ", with: ""))
        }
        // The first ⌘G: the newest (nearest; the recording is searched from its end), then round
        // from the oldest.
        #expect(seen == ["40:40"] + (1...39).map { "\($0):\($0)" }, "\(seen)")
    }

    /// From the match in memory back through all of the recording's, round to memory, and back
    /// and forth: every step one block on.
    @Test func findStepsBackFromMemoryAndBothWays() async throws {
        let f = try Fixture(lines: [], scrollback: 300, maxLines: 1500, chunk: 400, cols: 100)
        for b in 1...30 {
            for fr in 0..<25 {
                var s = fr == 0 ? "" : "\u{1b}[6A"
                for l in 0..<6 { s += " step \(l) of block \(b) at \(fr)\u{1b}[K\r\n" }
                Self.out(f, s)
            }
            Self.out(f, "needle done\r\nblock \(b)\r\n")
        }
        for i in 0..<400 { Self.out(f, "tail \(i)\r\n") }
        Self.out(f, "needle done\r\nblock 31\r\n")
        var status = TerminalFindStatus()
        f.view.onFindStatus = { status = $0 }
        f.view.setFind(TerminalFindQuery(term: "needle"))
        for _ in 0..<500 where status.total < 31 || status.searchingRecording { try await Task.sleep(for: .milliseconds(10)) }
        #expect(status.total == 31 && status.current == 31)
        func step(_ forward: Bool) async throws -> String {
            f.view.findStep(forward: forward)
            for _ in 0..<300 where f.view.history?.loading == true || (f.view.isBrowsingHistory && f.view.history?.selection.active != true) {
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(30))
            if !f.view.isBrowsingHistory { return "\(status.current):mem" }
            guard let h = f.view.history, h.selection.active else { return "\(status.current):-" }
            let t = h.getTerminal()
            let row = h.selection.start.row - t.buffer.yDisp
            return "\(status.current):" + (t.getLine(row: row + 1)?.translateToString(trimRight: true) ?? "?").replacingOccurrences(of: "block ", with: "")
        }
        var seen: [String] = []
        for _ in 0..<30 { seen.append(try await step(false)) }
        #expect(seen == (1...30).reversed().map { "\($0):\($0)" }, "back: \(seen)")
        seen = []
        for _ in 0..<3 { seen.append(try await step(false)) }       // round to memory's, then the last two
        #expect(seen == ["31:mem", "30:30", "29:29"], "round: \(seen)")
        seen = []
        for d in [true, true, false, true, true] { seen.append(try await step(d)) }
        #expect(seen == ["30:30", "31:mem", "30:30", "31:mem", "1:1"], "both ways: \(seen)")
    }

    /// Matches only in a long recording: what is found shows (counted) while the rest is still
    /// searched, and ⌘G pressed before anything is found goes to the first match once there is one.
    @Test func matchesShowWhileTheRecordingIsSearchedAndAnEarlyStepWaits() async throws {
        let f = try Fixture(lines: [], scrollback: 300, maxLines: 1500, chunk: 400, cols: 100)
        let pad = String(repeating: "x", count: 90)
        for i in 0..<40_000 { Self.out(f, (i % 2_000 == 1_000 ? "needle \(i)" : "line \(i) \(pad)") + "\r\n") }
        for i in 0..<400 { Self.out(f, "tail \(i)\r\n") }
        var statuses: [TerminalFindStatus] = []
        f.view.onFindStatus = { statuses.append($0) }
        f.view.setFind(TerminalFindQuery(term: "needle"))
        #expect(statuses.last?.total == 0 && statuses.last?.searchingRecording == true)
        f.view.findStep(forward: true)          // nothing found yet: waits
        for _ in 0..<1000 where statuses.last?.searchingRecording == true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(statuses.contains { $0.searchingRecording && $0.total > 0 }, "found ones counted before the end")
        #expect(statuses.contains { $0.searchingRecording && ($0.recordingProgress ?? 0) > 0 }, "how far it is")
        for _ in 0..<300 where f.view.history?.loading == true || f.view.history?.selection.active != true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(statuses.last?.total == 20)
        #expect(statuses.last?.current == 20, "the early step went to the newest match (found first)")
        #expect(f.view.history?.getSelection() == "needle")
    }

    /// The scroller's marks for the recording's matches are where the knob is when the match is
    /// shown — also where a program redrew in place (many line breaks, few rows).
    @Test func marksAreWhereTheKnobIsWhenTheMatchIsShown() async throws {
        let f = try Fixture(lines: [], scrollback: 300, maxLines: 1500, chunk: 400, cols: 100)
        for b in 1...30 {
            for fr in 0..<25 {
                var s = fr == 0 ? "" : "\u{1b}[6A"
                for l in 0..<6 { s += " step \(l) of block \(b) at \(fr)\u{1b}[K\r\n" }
                Self.out(f, s)
            }
            Self.out(f, "needle done\r\nblock \(b)\r\n")
            for i in 0..<40 { Self.out(f, "plain \(b)-\(i)\r\n") }
        }
        for i in 0..<400 { Self.out(f, "tail \(i)\r\n") }
        var status = TerminalFindStatus()
        f.view.onFindStatus = { status = $0 }
        f.view.setFind(TerminalFindQuery(term: "needle"))
        for _ in 0..<500 where status.total < 30 || status.searchingRecording { try await Task.sleep(for: .milliseconds(10)) }
        let shares = try #require(f.view.findSession?.earlier.map(\.share))
        var off: [String] = []
        for _ in 0..<30 {
            f.view.findStep(forward: true)
            for _ in 0..<300 where f.view.history?.loading == true || f.view.history?.selection.active != true { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(30))
            f.view.updateHistoryScroller()
            let sc = f.view.historyScroller
            guard let i = f.view.findSession?.currentEarlier else { off.append("none"); continue }
            let line = Double(shares[i]) * Double(sc.total)
            if line < Double(sc.top) - 2 || line > Double(sc.top + sc.visible) + 2 { off.append("\(i + 1): \(Int(line)) vs \(sc.top)…\(sc.top + sc.visible)") }
        }
        #expect(off.isEmpty, "\(off)")
    }

    /// More output between two matches than a part of the recording holds (a command printing
    /// thousands of lines): every step, either way, selects its match — not a place in the output
    /// between with nothing selected.
    @Test func findStepsAcrossMoreOutputThanAPartHolds() async throws {
        let f = try Fixture(lines: [], scrollback: 300, maxLines: 1500, chunk: 400, cols: 100)
        for b in 1...6 {
            Self.out(f, "$ needle run \(b)\r\n")
            for i in 0..<4_000 { Self.out(f, "\(b)-\(i)\r\n") }
        }
        for i in 0..<400 { Self.out(f, "tail \(i)\r\n") }
        var status = TerminalFindStatus()
        f.view.onFindStatus = { status = $0 }
        f.view.setFind(TerminalFindQuery(term: "needle"))
        for _ in 0..<1000 where status.total < 6 || status.searchingRecording { try await Task.sleep(for: .milliseconds(10)) }
        #expect(status.total == 6)
        func step(_ forward: Bool) async throws -> String {
            f.view.findStep(forward: forward)
            for _ in 0..<500 where f.view.history?.loading == true || f.view.history?.selection.active != true {
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(30))
            for _ in 0..<500 where f.view.history?.loading == true { try await Task.sleep(for: .milliseconds(10)) }
            guard let h = f.view.history, h.selection.active else { return "\(status.current):-" }
            let t = h.getTerminal()
            let row = h.selection.start.row
            let inSight = row >= t.buffer.yDisp && row < t.buffer.yDisp + t.rows
            let text = t.getLine(row: row - t.buffer.yDisp)?.translateToString(trimRight: true) ?? "?"
            return "\(status.current):" + (inSight ? text.replacingOccurrences(of: "$ needle run ", with: "") : "out of sight")
        }
        var seen: [String] = []
        for _ in 0..<6 { seen.append(try await step(true)) }
        #expect(seen == (1...6).map { "\($0):\($0)" }.rotated(), "forward: \(seen)")
        seen = []
        for _ in 0..<5 { seen.append(try await step(false)) }
        #expect(seen == ["4:4", "3:3", "2:2", "1:1", "6:6"], "back: \(seen)")
    }
}

private extension Array {
    /// The last element first (the first ⌘G goes to the newest match, then round from the oldest).
    func rotated() -> [Element] { isEmpty ? self : [self[count - 1]] + self[..<(count - 1)] }
}
