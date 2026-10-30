import AppKit
import Testing
import TetherCore
import SwiftTerm
import TerminalText
@testable import RecordingKit
@testable import SessionKit
@testable import TerminalUI

/// Scrolling through a recording longer than the terminal holds, with the output that trips it up:
/// full-screen programs, terminal queries, long wrapped lines, a recording shorter than memory.
@MainActor
@Suite(.serialized) struct HistoryBrowsingTests {
    @MainActor final class Fixture {
        let dir: URL
        let recorder: SessionRecorder
        let view: TetherTerminalView
        let session: TerminalSession
        init(lines: [String], scrollback: Int = 500, maxLines: Int = 1500, chunk: Int = 400, cols: Int = 80) throws {
            _ = NSApplication.shared
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-browse-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            recorder = try #require(SessionRecorder(targetKey: "b", sessionID: UUID(), directory: dir, key: nil, whileLocked: nil))
            var settings = AppSettings()
            settings.scrollbackLines = scrollback
            session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) { SessionConfiguration(settings: settings) }
            view = TetherTerminalView(session: session, settings: settings)
            view.getTerminal().resize(cols: cols, rows: 24)
            view.historyMaxLines = maxLines
            view.historyChunkLines = chunk
            for line in lines {
                let bytes = Array((line + "\r\n").utf8)
                view.feed(bytes[...])
                recorder.append(bytes)
            }
            let r = recorder
            view.historyReader = { reader in r.snapshot(then: reader); return true }
            view.historyIndex = { r.index }
        }
        deinit { recorder.close(); try? FileManager.default.removeItem(at: dir) }

        /// As the user does it: to the edge, which asks for the next part by itself.
        func slide(up: Bool) async -> Bool {
            final class Once { var done = false }
            let once = Once()
            return await withCheckedContinuation { done in
              MainActor.assumeIsolated {
                let view = self.view
                let finish: @MainActor (Bool) -> Void = { ok in
                    guard !once.done else { return }
                    once.done = true
                    view.onHistoryLoaded = nil
                    done.resume(returning: ok)
                }
                view.onHistoryLoaded = { ok in finish(ok) }
                // A load that never ends is a bug to see, not a run that waits for good.
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    MainActor.assumeIsolated {
                        guard !once.done else { return }
                        print("SLIDE STUCK up=\(up) browsing=\(view.isBrowsingHistory) loading=\(view.history?.loading == true) feeding=\(view.history?.feeding == true)")
                        self.stuck = true
                        finish(false)
                    }
                }
                if !view.isBrowsingHistory {
                    if !(up && view.loadOlderHistory()) { finish(false) }
                    // The part read a moment ago shown again at once (no load, nothing to wait for).
                    else if view.isBrowsingHistory, view.history?.loading != true { finish(true) }
                    return
                }
                let h = view.displayedTerminal
                if up { h.scrollTo(row: 0) } else { h.scrollTo(row: Int.max / 2) }
                if up { view.requestOlderHistory() } else { view.requestNewerHistory() }
                // Nothing to load there (the start or the live end): no load comes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { finish(false) } }
              }
            }
        }

        var shown: TerminalView { view.displayedTerminal }
        /// A slide's load never ended (see `slide`).
        var stuck = false

        /// The first number shown at the top of the view.
        func top() -> Int {
            let t = shown.getTerminal()
            for r in 0..<t.rows {
                let text = t.getLine(row: r)?.translateToString(trimRight: true) ?? ""
                if let n = Int(text.split(separator: " ").first ?? "") { return n }
            }
            return -1
        }
    }

    @Test func aWindowEndingInsideAFullScreenProgramStillScrollsAndReturnsToLive() async throws {
        var lines = (1...3000).map { "\($0)" }
        // A pager in the middle of the session: its screen starts, many lines, then it ends.
        lines.insert("\u{1b}[?1049h", at: 1000)
        lines.insert("\u{1b}[?1049l", at: 1300)
        let f = try Fixture(lines: lines)
        f.view.scrollTo(row: 0)
        for _ in 0..<12 where f.top() != 1 {
            _ = await f.slide(up: true)
            #expect(!f.shown.getTerminal().isCurrentBufferAlternate, "a window never stays on a program's screen")
        }
        #expect(f.view.isBrowsingHistory)
        #expect(f.top() == 1)
        f.view.returnToLive()
        #expect(!f.view.isBrowsingHistory, "back to live")
    }

    @Test func queriesInOldOutputAreNotAnsweredAndDoNotEndBrowsing() async throws {
        var lines = (1...3000).map { "\($0)" }
        lines[200] = "200 \u{1b}[c\u{1b}[6n"      // a program asked the terminal who it is, where the cursor is
        let f = try Fixture(lines: lines)
        let inputBefore = f.session.lastInputAt
        f.view.scrollTo(row: 0)
        for _ in 0..<12 where f.top() > 150 {
            _ = await f.slide(up: true)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.view.isBrowsingHistory, "still browsing")
        #expect(f.session.lastInputAt == inputBefore, "nothing was sent for the old queries")
    }

    @Test func longWrappedLinesScrollWithoutJumps() async throws {
        let lines = (1...3000).map { "\($0) " + String(repeating: "w", count: 150) }   // two rows each at 80 columns
        let f = try Fixture(lines: lines)
        f.view.scrollTo(row: 0)
        var previous = f.top()
        var largest = 0
        for _ in 0..<40 where previous > 1 {
            if f.view.isBrowsingHistory { f.shown.scrollTo(row: 0); previous = f.top() }
            _ = await f.slide(up: true)
            let now = f.top()
            largest = max(largest, abs(previous - now))
            f.shown.scrollTo(row: 0)
            previous = f.top()
        }
        #expect(previous == 1, "reached the first line (\(previous))")
        #expect(largest <= 2, "the line looked at stays put (moved \(largest))")
    }

    @Test func aRecordingShorterThanMemoryTakesNoLinesAway() async throws {
        // The terminal showed lines the recording does not have (it started later).
        let f = try Fixture(lines: [], scrollback: 3000)
        for i in 1...1200 { f.view.feed(Array("early \(i)\r\n".utf8)[...]) }
        for i in 1...300 {
            let bytes = Array("late \(i)\r\n".utf8)
            f.view.feed(bytes[...])
            f.recorder.append(bytes)
        }
        f.view.getTerminal().changeScrollback(1000)       // memory dropped the first lines
        let before = f.view.bufferLineCount
        f.view.scrollTo(row: 0)
        _ = await f.slide(up: true)
        #expect(f.view.bufferLineCount >= before, "no lines left the terminal")
    }

    /// Commands far apart (more output between them than the terminal holds): ⌘↑ / ⌘↓ go from one
    /// to the next through the recording, and ⇧⌘↑ selects whole commands, copied from the recording.
    @Test func commandsFarApartCanBeJumpedToAndSelected() async throws {
        let f = try Fixture(lines: [], scrollback: 500)
        func say(_ text: String) {
            let bytes = Array(text.utf8)
            f.view.feed(bytes[...])
            f.recorder.append(bytes)
        }
        for c in 1...4 {
            say("$ run \(c)")
            f.recorder.markCommand()
            say("\r\n")
            for i in 1...1500 { say("out \(c)-\(i)\r\n") }
        }
        say("$ ")
        func shownTop() -> String {
            let t = f.shown.getTerminal()
            return (0..<t.rows).compactMap { t.getLine(row: $0)?.translateToString(trimRight: true) }
                .first { $0.hasPrefix("$ run") } ?? ""
        }
        func waitShown() async throws {
            for _ in 0..<200 where f.view.history?.loading != false { try await Task.sleep(for: .milliseconds(10)) }
        }
        f.view.jumpToMark(up: true)
        try await waitShown()
        #expect(f.view.isBrowsingHistory)
        #expect(shownTop() == "$ run 4", "the last command (\(shownTop()))")
        f.view.jumpToMark(up: true)
        try await waitShown()
        #expect(shownTop() == "$ run 3", "the one before (\(shownTop()))")
        f.view.jumpToMark(up: true)
        try await waitShown()
        #expect(shownTop() == "$ run 2")
        f.view.jumpToMark(up: false)
        try await waitShown()
        #expect(shownTop() == "$ run 3", "and back down (\(shownTop()))")

        // Whole commands, back from the prompt: the last two, then copied in full.
        f.view.returnToLive()
        f.view.selectToMark(up: true)
        try await waitShown()
        f.view.selectToMark(up: true)
        try await waitShown()
        #expect(f.view.commandSelection == .init(first: 2, end: nil))
        var copied = ""
        f.view.copiedTextSink = { copied = $0 }
        f.view.copyCommandSelection()
        for _ in 0..<300 where copied.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let lines = copied.components(separatedBy: "\n")
        #expect(lines.first == "$ run 3")
        #expect(lines.contains("out 3-1") && lines.contains("out 4-1500"))
        #expect(!lines.contains("out 2-1500"))
        #expect(lines.filter { $0.hasPrefix("out ") }.count == 3000, "every line, none twice")
    }

    /// ⌘F finds what left memory too: the count covers the whole session, and going back past the
    /// first match in memory shows the earlier ones, selected, from the recording.
    @Test func findGoesOnInTheRecording() async throws {
        var lines = (1...3000).map { "line \($0)" }
        lines[100] = "here is the needle one"
        lines[2900] = "and the needle two"
        let f = try Fixture(lines: lines)
        var status = TerminalFindStatus()
        f.view.onFindStatus = { status = $0 }
        f.view.setFind(TerminalFindQuery(term: "needle"))
        for _ in 0..<300 where status.total < 2 || status.searchingRecording { try await Task.sleep(for: .milliseconds(10)) }
        #expect(status.total == 2, "one in memory, one in the recording (\(status.total))")
        #expect(status.current == 2, "the one in memory is current")
        f.view.findStep(forward: false)
        for _ in 0..<300 where f.view.history?.selection.active != true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(f.view.isBrowsingHistory)
        #expect(status.current == 1)
        #expect(f.view.history?.getSelection() == "needle", "the earlier match is selected (\(f.view.history?.getSelection() ?? "-"))")
        // And on, round to the one in memory again.
        f.view.findStep(forward: true)
        #expect(!f.view.isBrowsingHistory)
        #expect(status.current == 2)
    }

    /// Back and forth across the seam between the recording and memory, in random steps: what is
    /// on screen is always one run of consecutive lines — never an earlier part left showing, never
    /// a line twice or missing.
    @Test(arguments: ["short", "wrapped", "redrawn"])
    func goingBackAndForthNeverShowsOldText(_ kind: String) async throws {
        let lines: [String] = (1...6000).map { n in
            switch kind {
            case "wrapped": return "\(n) " + String(repeating: "w", count: n % 3 == 0 ? 130 : 20)
            // A status line redrawn in place after every tenth line, as a coding agent does.
            case "redrawn": return n % 10 == 0 ? "\(n)\r\n\u{1b}[2mworking \(n)\u{1b}[0m\r\u{1b}[2K\u{1b}[1A" : "\(n)"
            default: return "\(n)"
            }
        }
        let f = try Fixture(lines: lines, scrollback: 400, maxLines: 1200, chunk: 300)
        var rng = SystemRandomNumberGenerator()
        func visible() -> [Int] {
            let t = f.shown.getTerminal()
            // The number each line starts with (rows a long line continues on have none).
            return (0..<t.rows).compactMap { r -> Int? in
                guard let text = t.getLine(row: r)?.translateToString(trimRight: true), let first = text.split(separator: " ").first else { return nil }
                return Int(first)
            }
        }
        for step in 0..<40 {
            let up = step < 6 || Bool.random(using: &rng)
            _ = await f.slide(up: up)
            if Bool.random(using: &rng) {
                // A few rows further, as the wheel goes, without reaching an edge.
                let t = f.shown.getTerminal()
                f.shown.scrollTo(row: max(t.buffer.yDisp + (up ? -5 : 5), 0))
            }
            try await Task.sleep(for: .milliseconds(20))
            let rows = visible()
            #expect(rows.count >= f.shown.getTerminal().rows / 3, "step \(step): the screen is full (\(rows))")
            let runs = zip(rows, rows.dropFirst()).allSatisfy { $1 == $0 + 1 }
            #expect(runs, "step \(step) (\(up ? "up" : "down"), browsing \(f.view.isBrowsingHistory)): \(rows)")
            #expect(!f.stuck, "step \(step) (\(up ? "up" : "down")): a load never ended")
            if !runs || f.stuck { break }
        }
    }

    /// Far back in the recording, scrolling down goes down: each step shows later lines, also as
    /// later parts are read in on the way (the view is never sent back up).
    @Test(arguments: ["short", "wrapped", "agent"])
    func scrollingDownFarBackOnlyGoesDown(_ kind: String) async throws {
        // A coding agent's session: output with its status block redrawn in place (the cursor
        // moved up and back), as `HistoryCostProbe` makes it.
        let lines = kind == "agent"
            ? String(decoding: HistoryCostProbe.agentSession(blocks: 120), as: UTF8.self).components(separatedBy: "\r\n")
            : (1...8000).map { n in kind == "wrapped" && n % 4 == 0 ? "\(n) " + String(repeating: "w", count: 150) : "\(n)" }
        let f = try Fixture(lines: lines, scrollback: 400, maxLines: 1200, chunk: 300)
        // Where the top of the view is (it only grows going down): the first numbered line on
        // screen, or the agent's "block B line K".
        func place() -> Int {
            guard f.view.isBrowsingHistory else { return Int.max }
            if kind != "agent" { return f.top() }
            let t = f.shown.getTerminal()
            for r in 0..<t.rows {
                let text = t.getLine(row: r)?.translateToString(trimRight: true) ?? ""
                guard let at = text.range(of: "block ") else { continue }
                let parts = text[at.upperBound...].split(separator: " ")
                if parts.count >= 3, let b = Int(parts[0]), parts[1] == "line", let k = Int(parts[2]) { return b * 100 + k }
            }
            return -1
        }
        f.view.updateHistoryScroller()
        f.view.scrollHistory(toLine: 300)
        for _ in 0..<300 where !f.view.isBrowsingHistory || f.view.history?.loading == true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(f.view.isBrowsingHistory)
        var previous = place()
        var went = 0
        func screen() -> String {
            let t = f.shown.getTerminal()
            return (0..<t.rows).map { t.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }.map { String($0.prefix(40)) }.joined(separator: " | ")
        }
        for step in 0..<160 {
            let t = f.shown.getTerminal()
            // As the wheel does: a few rows down; at the bottom of the part shown, the next is asked for.
            f.shown.scrollTo(row: t.buffer.yDisp + 12)
            f.view.lastWheel = ProcessInfo.processInfo.systemUptime
            f.view.requestNewerHistory()
            for _ in 0..<200 where f.view.history?.loading == true || f.view.history?.feeding == true { try await Task.sleep(for: .milliseconds(5)) }
            try await Task.sleep(for: .milliseconds(15))
            guard f.view.isBrowsingHistory else { break }      // reached memory: the live terminal
            let now = place()
            #expect(now >= previous, "step \(step): went back up from \(previous) to \(now)")
            if now < previous { print("SCROLLDOWN at \(step): \(screen())"); break }
            if now > previous { went += 1 }
            previous = now
        }
        #expect(went > 20, "it moved on (\(went) steps, at \(previous))")
    }

    /// The Mac short of memory: a tab off screen keeps only its last lines at once (the rest is in
    /// its recording, and scrolling up still reaches it).
    @Test func aTabOffScreenGivesMemoryBackAtOnce() async throws {
        let f = try Fixture(lines: (1...6000).map { "\($0) line" }, scrollback: 10_000, maxLines: 20_000)
        #expect(f.view.linesDropped == 0)
        f.view.relieveMemory()
        #expect(f.view.linesDropped > 3000, "only the last lines stay (\(f.view.linesDropped) dropped)")
        #expect(f.view.hasOlderOutput, "the rest is reached in the recording")
    }

    /// Scrolled back into the recording, then ⌘F for a text on screen (copied from there, say):
    /// it is selected at once, before the recording's search is done, and stays the one chosen —
    /// not the same text further up in the part read, nor one in memory.
    @Test func findWhileBrowsingStartsWhereTheViewIs() async throws {
        var lines = (1...4000).map { "\($0) line" }
        for n in [120, 300, 3900] { lines[n] = "\(n + 1) the token here" }
        let f = try Fixture(lines: lines)
        f.view.updateHistoryScroller()
        f.view.scrollHistory(toLine: 296)
        for _ in 0..<300 where !f.view.isBrowsingHistory || f.view.history?.loading == true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(f.view.isBrowsingHistory)
        var status = TerminalFindStatus()
        f.view.onFindStatus = { status = $0 }
        f.view.setFind(TerminalFindQuery(term: "token"))
        let h = try #require(f.view.history)
        func selectedLine() -> String {
            guard h.selection.active else { return "" }
            let row = h.selection.start.row
            return h.getTerminal().getLine(row: row - h.getTerminal().buffer.yDisp)?.translateToString(trimRight: true) ?? ""
        }
        #expect(h.getSelection() == "token", "selected at once")
        #expect(selectedLine().hasPrefix("301 "), "the one on screen (\(selectedLine()))")
        for _ in 0..<500 where status.searchingRecording || status.total < 3 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(f.view.isBrowsingHistory, "still where the user was")
        #expect(selectedLine().hasPrefix("301 "), "still the one on screen once the recording is searched (\(selectedLine()))")
    }

    /// ⌘G goes through every match once, oldest first, then round: two matches on lines next to
    /// each other in memory are each visited once (not again as if they were also in the
    /// recording) — also in a tab restored after a relaunch, whose memory starts with output it
    /// showed again from its recording.
    @Test(arguments: [false, true])
    func eachMatchIsVisitedOnce(_ restored: Bool) async throws {
        var lines = (1...3000).map { "line \($0)" }
        lines[200] = "old src/parts/RowIcons.vue | 12 ++"
        lines[2985] = " src/parts/RowIcons.vue | 258 ++++++++++"
        lines[2986] = " create mode 100644 src/parts/RowIcons.vue"
        let f = try Fixture(lines: restored ? [] : lines)
        if restored {
            // The recording holds everything; the tab shows its end again, then a little more.
            for line in lines { f.recorder.append(Array((line + "\r\n").utf8)) }
            let tail = Array(lines.suffix(400).joined(separator: "\r\n").utf8) + [0x0d, 0x0a]
            f.view.showEarlierOutput(tail[...])
            f.view.earlierOutputIsPartial()
        }
        var status = TerminalFindStatus()
        f.view.onFindStatus = { status = $0 }
        f.view.setFind(TerminalFindQuery(term: "RowIcons.vue"))
        for _ in 0..<500 where status.searchingRecording || status.total < 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(status.total == 3, "one match per place (\(status.total))")
        var seen: [Int] = []
        for _ in 0..<3 {
            f.view.findStep(forward: true)
            for _ in 0..<300 where f.view.isBrowsingHistory && f.view.history?.loading == true { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(50))
            seen.append(status.current)
        }
        #expect(Set(seen).count == 3, "each of the three once: \(seen)")
    }

    /// Two matches on screen: the upper one is shown first, and ↩ / ⌘G goes to the lower one —
    /// not past it to the oldest match in the recording.
    @Test func theFirstMatchIsTheUpperOneOnScreen() async throws {
        var lines = (1...3000).map { "line \($0)" }
        lines[150] = "needle far back"
        lines[2985] = "needle upper"
        lines[2988] = "needle lower"
        let f = try Fixture(lines: lines)
        var status = TerminalFindStatus()
        f.view.onFindStatus = { status = $0 }
        f.view.setFind(TerminalFindQuery(term: "needle"))
        for _ in 0..<500 where status.searchingRecording || status.total < 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(status.total == 3)
        #expect(f.view.currentFindMatchText == "needle")
        #expect(status.current == 2, "the upper one on screen (\(status.current) of \(status.total))")
        f.view.findStep(forward: true)
        try await Task.sleep(for: .milliseconds(60))
        #expect(status.current == 3, "then the lower one")
        #expect(!f.view.isBrowsingHistory)
    }

    /// Every ⌘G moves to another match from the first one shown — at once after the term is set
    /// (while earlier output is still searched), after that search, and with a single match (it
    /// stays there). Backwards the same.
    @Test(arguments: ["settled", "searching", "single", "backwards"])
    func eachStepMovesOn(_ when: String) async throws {
        var lines = (1...3000).map { "line \($0)" }
        if when == "single" { lines[2990] = "the one needle" } else {
            for n in [150, 900, 2950, 2970, 2990] { lines[n] = "needle at \(n)" }
        }
        let f = try Fixture(lines: lines)
        var status = TerminalFindStatus()
        f.view.onFindStatus = { status = $0 }
        f.view.setFind(TerminalFindQuery(term: "needle"))
        if when != "searching" {
            for _ in 0..<500 where status.searchingRecording { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(100))
        }
        func step(_ forward: Bool) async throws -> Int {
            f.view.findStep(forward: forward)
            for _ in 0..<300 where f.view.history?.loading == true { try await Task.sleep(for: .milliseconds(10)) }
            try await Task.sleep(for: .milliseconds(60))
            return status.current
        }
        let first = status.current
        if when == "single" {
            for _ in 0..<500 where status.searchingRecording { try await Task.sleep(for: .milliseconds(10)) }
            #expect(status.total == 1)
            let a = try await step(true), b = try await step(true)
            #expect(a == 1 && b == 1, "one match: it stays")
            return
        }
        #expect(first > 0, "a match is shown at once (\(first) of \(status.total))")
        let forward = when != "backwards"
        var seen = [first]
        for _ in 0..<3 { seen.append(try await step(forward)) }
        for _ in 0..<500 where status.searchingRecording { try await Task.sleep(for: .milliseconds(10)) }
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 != $1 }, "every step moved on: \(seen) of \(status.total)")
    }

    /// Matches only in the recording, several on a line, steps in quick succession, and a term
    /// changed while browsing: counted as occurrences, each shown selected, no crash.
    @Test func findInTheRecordingCountsAndStepsThroughEveryOccurrence() async throws {
        var lines = (1...3000).map { "line \($0)" }
        lines[100] = "pin pin A"
        lines[200] = "pin B"
        lines[300] = "other words"
        let f = try Fixture(lines: lines)
        var status = TerminalFindStatus()
        f.view.onFindStatus = { status = $0 }
        func settle() async throws {
            for _ in 0..<300 where status.searchingRecording || f.view.history?.loading == true {
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        f.view.setFind(TerminalFindQuery(term: "pin"))
        for _ in 0..<300 where status.total == 0 || status.searchingRecording { try await Task.sleep(for: .milliseconds(10)) }
        #expect(status.total == 3, "every occurrence, two on one line (\(status.total))")
        // Nothing in memory: ⌘G goes to the recording's newest (nearest), then round to its first.
        f.view.findStep(forward: true)
        try await settle()
        #expect(status.current == 3 && f.view.isBrowsingHistory)
        #expect(f.view.history?.getSelection() == "pin")
        f.view.findStep(forward: true)
        try await settle()
        #expect(status.current == 1)
        // Two steps at once: the second still lands, on line B.
        f.view.findStep(forward: true)
        f.view.findStep(forward: true)
        try await settle()
        #expect(status.current == 3)
        let selectedRow = f.view.history?.selection.start.row ?? -1
        let rowText = f.view.history?.getTerminal().getLine(row: selectedRow - (f.view.history?.getTerminal().buffer.yDisp ?? 0))?
            .translateToString(trimRight: true) ?? ""
        #expect(rowText == "pin B", "the third is on its own line (\(rowText))")
        // Another term while browsing: the find stays in the recording, from where the view is.
        f.view.setFind(TerminalFindQuery(term: "other"))
        for _ in 0..<300 where status.total == 0 || status.searchingRecording { try await Task.sleep(for: .milliseconds(10)) }
        try await settle()
        #expect(status.total == 1 && status.current == 1)
        #expect(f.view.isBrowsingHistory)
        #expect(f.view.history?.getSelection() == "other")
    }

    /// A long recording: the matches found in it are counted (and can be gone to) while the rest is
    /// still being looked through, and the find bar says how far that is.
    @Test func matchesInTheRecordingShowWhileItIsSearched() async throws {
        var lines = (1...40_000).map { "line \($0) " + String(repeating: "filler ", count: 8) }
        for k in stride(from: 100, to: 38_000, by: 1_500) { lines[k] = "the needle \(k)" }
        let f = try Fixture(lines: lines, scrollback: 500)
        var sawPartial = false, sawPercent = false
        var status = TerminalFindStatus()
        f.view.onFindStatus = { s in
            status = s
            if s.searchingRecording, s.total > 1 { sawPartial = true }
            if s.searchingRecording, s.recordingProgress != nil { sawPercent = true }
        }
        f.view.setFind(TerminalFindQuery(term: "needle"))
        for _ in 0..<1000 where status.total == 0 || status.searchingRecording { try await Task.sleep(for: .milliseconds(10)) }
        #expect(status.total == 26, "every match (\(status.total))")
        #expect(sawPartial, "some were counted before the end")
        #expect(sawPercent, "and how far it was")
    }

    /// Output redrawn in place (a progress block moved up with cursor keys) has more line breaks
    /// than lines left on screen: the history view still opens exactly where the terminal is.
    @Test func theSeamIsRightAfterOutputRedrawnInPlace() async throws {
        var lines = (1...2500).map { "line \($0)" }
        for k in 0..<20 { lines.append("progress a \(k)\r\nprogress b \(k)\r\nprogress c \(k)\u{1b}[2A\r") }
        lines.append("\r\n\r\n\r\nafter")
        lines += (1...300).map { "tail \($0)" }
        let f = try Fixture(lines: lines)
        f.view.scrollTo(row: 0)
        let liveTop = f.view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true) ?? ""
        _ = await f.slide(up: true)
        #expect(f.view.isBrowsingHistory)
        let shownTop = f.shown.getTerminal().getLine(row: 0)?.translateToString(trimRight: true) ?? ""
        #expect(shownTop == liveTop, "the same line at the top (\(liveTop) / \(shownTop))")
    }

    /// Scrolling up across a full-screen program's output (a pager) moves evenly: its screens are
    /// not in the history, as in the live terminal.
    @Test func scrollingAcrossAFullScreenProgramDoesNotJump() async throws {
        var lines = (1...3000).map { "\($0)" }
        lines.insert("\u{1b}[?1049h", at: 1000)
        lines.insert("\u{1b}[?1049l", at: 1300)
        let f = try Fixture(lines: lines)
        f.view.scrollTo(row: 0)
        var previous = f.top(), largest = 0
        for _ in 0..<30 where previous != 1 {
            _ = await f.slide(up: true)
            let now = f.top()
            // The pager's own lines are skipped, as the live terminal skipped them.
            let skipped = (now < 1300 && previous > 1300) ? 300 : 0
            largest = max(largest, abs(previous - now) - skipped)
            f.shown.scrollTo(row: 0)
            previous = f.top()
        }
        #expect(previous == 1)
        #expect(largest <= 2, "no jump (\(largest))")
    }

    /// What the terminal answers by itself (a program asking where the cursor is) is not typing:
    /// browsing goes on.
    @Test func answersSentByTheTerminalItselfDoNotEndBrowsing() async throws {
        let f = try Fixture(lines: (1...3000).map { "line \($0)" })
        f.view.scrollTo(row: 0)
        _ = await f.slide(up: true)
        #expect(f.view.isBrowsingHistory)
        f.view.feed(Array("\u{1b}[6n\u{1b}[c".utf8)[...])
        try await Task.sleep(for: .milliseconds(200))
        #expect(f.view.isBrowsingHistory)
    }

    /// A selection of commands whose recording was replaced (a retry starts a new one) is let go
    /// of instead of reading past the new recording's commands.
    @Test func aCommandSelectionOfAReplacedRecordingIsDropped() async throws {
        let f = try Fixture(lines: [], scrollback: 500)
        for c in 1...3 {
            f.recorder.append(Array("$ run \(c)".utf8)); f.view.feed(Array("$ run \(c)".utf8)[...])
            f.recorder.markCommand()
            for i in 1...800 { let b = Array("out \(c)-\(i)\r\n".utf8); f.view.feed(b[...]); f.recorder.append(b) }
        }
        f.view.selectToMark(up: true)
        f.view.selectToMark(up: true)
        #expect(f.view.commandSelection != nil)
        f.view.historyIndex = { RecordingIndex() }        // a new, empty recording
        var copied: String?
        f.view.copiedTextSink = { copied = $0 }
        f.view.copyCommandSelection()
        f.view.selectToMark(up: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(copied == nil)
    }

    /// The scroller dragged into the recording, then (before that part is read) back into memory:
    /// the last place wins.
    @Test func theLastScrollerPositionWins() async throws {
        let f = try Fixture(lines: (1...4000).map { "line \($0)" })
        f.view.updateHistoryScroller()
        let total = f.view.historyScroller.total
        f.view.scrollHistory(toLine: 100)
        f.view.scrollHistory(toLine: 200)
        f.view.scrollHistory(toLine: total - 10)
        for _ in 0..<150 where f.view.history?.loading == true { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!f.view.isBrowsingHistory, "back in memory, where the scroller was released")
    }

    /// Tether placing the view at the top of memory (⌘↑, a find) is not the user going on into the
    /// recording: memory stays on screen. The scroller dragged there does go on into it.
    @Test func onlyTheUserGoesOnIntoTheRecording() async throws {
        let f = try Fixture(lines: (1...4000).map { "\($0) line" })
        f.view.lastWheel = 0
        f.view.scrollTo(row: 0)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!f.view.isBrowsingHistory, "placed by Tether: memory stays")
        f.view.updateHistoryScroller()
        f.view.scrollHistory(toLine: 50)
        for _ in 0..<300 where !f.view.isBrowsingHistory || f.view.history?.loading == true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.view.isBrowsingHistory)
        #expect(abs(f.top() - 51) <= 1, "the line the scroller was taken to is at the top (\(f.top()))")
    }

    /// The window gets narrower while a part of the recording is drawn: the part is drawn again for
    /// the new width, and the line asked for is still the one at the top.
    @Test func aNewWidthWhileAPartIsDrawnKeepsItsPlace() async throws {
        let pad = String(repeating: "x", count: 70)
        let f = try Fixture(lines: (1...4000).map { "\($0) \(pad)" })
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = f.view
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        // Drawn a little at a time, so the window is resized while the rows go in.
        HistoryTerminalView.sliceTime = 0.0001
        defer { HistoryTerminalView.sliceTime = 0.03 }
        f.view.updateHistoryScroller()
        f.view.scrollHistory(toLine: 1000)
        var resizedWhileDrawing = false
        for _ in 0..<2000 {
            if f.view.history?.feeding == true {
                window.setContentSize(NSSize(width: 450, height: 400))
                window.layoutIfNeeded()
                resizedWhileDrawing = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(resizedWhileDrawing)
        for _ in 0..<500 where !f.view.isBrowsingHistory || f.view.history?.loading == true || f.view.history?.feeding == true {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(200))
        let h = try #require(f.view.history)
        #expect(h.getTerminal().cols < 80, "drawn for the new width")
        #expect(h.getTerminal().cols == f.view.getTerminal().cols, "lines wrap as in the live terminal")
        #expect(f.top() == 1001, "line 1001 at the top (\(f.top()))")
    }

    /// Output a program redrew in place (a status block moved up with cursor keys, as chat programs
    /// do) has many more line breaks than lines: a match in the recording after it is still the
    /// one selected, found by its line.
    @Test func aMatchAfterOutputRedrawnInPlaceIsTheOneSelected() async throws {
        var lines = (1...3000).map { "line \($0)" }
        var block = ""
        for k in 0..<600 { block += "status \(k) a\r\nstatus \(k) b\r\nstatus \(k) c\r\n\u{1b}[3A" }
        lines[100] = block + "\u{1b}[3B" + "pin A"
        lines[101] = "between"
        lines[102] = "pin B"
        lines[103] = "pin C"
        let f = try Fixture(lines: lines)
        var status = TerminalFindStatus()
        f.view.onFindStatus = { status = $0 }
        func settle() async throws {
            for _ in 0..<300 where status.searchingRecording || f.view.history?.loading == true || f.view.history?.selection.active != true {
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        func selectedLine() -> String {
            guard let h = f.view.history else { return "-" }
            let t = h.getTerminal()
            return t.getLine(row: h.selection.start.row - t.buffer.yDisp)?.translateToString(trimRight: true) ?? "-"
        }
        f.view.setFind(TerminalFindQuery(term: "pin"))
        for _ in 0..<300 where status.total < 3 || status.searchingRecording { try await Task.sleep(for: .milliseconds(10)) }
        #expect(status.total == 3)
        // The newest first (the recording is searched from its end), then round from the oldest.
        for expected in ["pin C", "pin A", "pin B"] {
            f.view.findStep(forward: true)
            try await settle()
            #expect(selectedLine() == expected, "\(expected) (\(selectedLine()))")
        }
    }
}

/// Find while output streams: only what may have changed is looked through again, with the same
/// result as looking through everything; a cleared screen or another width looks through all.
@MainActor
@Suite(.serialized) struct FindWhileOutputStreamsTests {
    func onScreen() -> (TetherTerminalView, NSWindow) {
        _ = NSApplication.shared
        var settings = AppSettings()
        settings.scrollbackLines = 5_000
        let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) { SessionConfiguration(settings: settings) }
        let view = TetherTerminalView(session: session, settings: settings)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        window.contentView = view
        window.alphaValue = 0
        window.orderFrontRegardless()
        return (view, window)
    }

    func fullCount(_ view: TetherTerminalView, _ term: String) throws -> Int {
        BufferSearch.matches(in: view.getTerminal(), regex: try BufferSearch.regex(term, isRegex: false, caseSensitive: false, wholeWord: false)).count
    }

    /// Until the look that output asked for has been made (later under load: it waits five times
    /// as long as the last one took).
    func settle(_ view: TetherTerminalView) async throws {
        try await Task.sleep(for: .milliseconds(250))
        for _ in 0..<500 where view.findSession?.rescanScheduled == true { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Memory's first lines are given whole to the look into the recording (its lines are compared
    /// with them), also past the 400 characters a recording match is remembered by.
    @Test func memoryLinesAreWhole() {
        let (view, window) = onScreen()
        defer { window.orderOut(nil) }
        let long = String(repeating: "x", count: 900)
        view.feed(Array("\(long)\r\nshort   \r\n\r\n".utf8)[...])
        let m = view.memoryLinesForFind()
        #expect(m.head.first == long)
        #expect(m.head.dropFirst().first == "short")
        #expect(m.count == 2, "blank lines at the end are not counted")
    }

    @Test func newOutputIsFoundAndNothingIsCountedTwice() async throws {
        let (view, window) = onScreen()
        defer { window.orderOut(nil) }
        for i in 0..<2_000 { view.feed(Array("line \(i)\(i % 100 == 0 ? " needle" : "")\r\n".utf8)[...]) }
        view.setFind(TerminalFindQuery(term: "needle"))
        #expect(view.findSession?.matches.count == 20)
        for round in 0..<5 {
            for i in 0..<300 { view.feed(Array("more \(round)-\(i)\(i % 50 == 0 ? " needle" : "")\r\n".utf8)[...]) }
            // On screen when looked at, then redrawn: its match goes away.
            view.feed(Array("needle on screen\r\n".utf8)[...])
            try await settle(view)
            #expect(view.findSession?.matches.count == (try fullCount(view, "needle")))
            view.feed(Array("\u{1b}[1A\r\u{1b}[2Kredrawn\r\n".utf8)[...])
            try await settle(view)
            #expect(view.findSession?.lastScanWasPartial == true, "only what may have changed (round \(round))")
            #expect(view.findSession?.matches.count == (try fullCount(view, "needle")), "round \(round)")
        }
        #expect(view.findSession?.matches == BufferSearch.matches(in: view.getTerminal(),
                                                                  regex: try BufferSearch.regex("needle", isRegex: false, caseSensitive: false, wholeWord: false)))
        view.clearBuffer()
        try await settle(view)
        #expect(view.findSession?.matches.isEmpty == true, "cleared: none left")
    }
}

/// Marks beside the scroller sit inside its knob for what is on screen, whatever the knob's size.
@Suite struct ScrollerMarkTests {
    @Test func aMarkOnScreenIsInsideTheKnob() {
        let height: CGFloat = 600, total = 100_000, visible = 40
        // The knob is at its minimum (28 points): at the top and at the bottom of the track.
        #expect(HistoryScroller.markOffset(line: Double(visible) / 2, total: total, visible: visible, height: height) == 14)
        #expect(HistoryScroller.markOffset(line: Double(total - visible / 2), total: total, visible: visible, height: height) == height - 14)
        // Anywhere a line is on screen, its mark is within the knob's 28 points.
        let top = 50_000
        let knobTop = (height - 28) * CGFloat(top) / CGFloat(total - visible)
        for line in [top, top + visible / 2, top + visible - 1] {
            let y = HistoryScroller.markOffset(line: Double(line), total: total, visible: visible, height: height)
            #expect(y >= knobTop - 0.5 && y <= knobTop + 28.5, "line \(line): \(y) vs knob at \(knobTop)")
        }
    }
}

/// A match in the recording is shown by its selection and one brief tint, both on its row.
@MainActor
@Suite(.serialized) struct FindFlashTests {
    @Test func theTintIsOnTheSelectedMatchOnly() async throws {
        var lines = (1...3000).map { "line \($0)" }
        lines[100] = "needle back here"
        let f = try HistoryBrowsingTests.Fixture(lines: lines)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 413),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = f.view
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        var status = TerminalFindStatus()
        f.view.onFindStatus = { status = $0 }
        f.view.setFind(TerminalFindQuery(term: "needle"))
        for _ in 0..<500 where status.total == 0 || status.searchingRecording { try await Task.sleep(for: .milliseconds(10)) }
        var flashes: [CGRect] = []
        f.view.findStep(forward: true)
        for _ in 0..<300 where f.view.history?.selection.active != true || f.view.history?.loading == true {
            try await Task.sleep(for: .milliseconds(10))
        }
        let h = try #require(f.view.history)
        flashes = (h.layer?.sublayers ?? []).filter { $0.name == TerminalView.flashLayerName }.map(\.frame)
        let t = h.getTerminal()
        let row = h.selection.start.row - t.buffer.yDisp
        #expect(t.getLine(row: row)?.translateToString(trimRight: true) == "needle back here")
        let cell = h.getOptimalFrameSize().height / CGFloat(t.rows)
        let expected = h.bounds.maxY - CGFloat(row + 1) * cell
        print("FLASH caret=\(h.caretFrame) cell=\(cell) bounds=\(h.bounds) rows=\(t.rows) flashes=\(flashes) expectedY=\(expected)")
        #expect(flashes.count == 1, "one tint: \(flashes)")
        #expect(flashes.allSatisfy { abs($0.minY - expected) < 1 && abs($0.height - cell) < 1 }, "on the match's row: \(flashes) vs \(expected)")
    }
}

extension FindFlashTests {
    /// Matches in memory are not drawn over the recording while it is shown, at any moment of
    /// going into it and back (the overlay is above the history view).
    @Test func memorysMatchesAreNotDrawnOverTheRecording() async throws {
        var lines = (1...3000).map { "line \($0)" }
        lines[100] = "needle back here"
        for n in stride(from: 2980, to: 3000, by: 3) { lines[n] = "needle \(n)" }
        let f = try HistoryBrowsingTests.Fixture(lines: lines)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 413),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = f.view
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        window.layoutIfNeeded()
        var status = TerminalFindStatus()
        f.view.onFindStatus = { status = $0 }
        f.view.setFind(TerminalFindQuery(term: "needle"))
        for _ in 0..<500 where status.total < 8 || status.searchingRecording { try await Task.sleep(for: .milliseconds(10)) }
        var leaks: [String] = []
        func watch(_ what: String, _ ms: Int) async throws {
            for i in 0..<(ms / 5) {
                if f.view.isBrowsingHistory, f.view.findSession?.overlay.drawsOverText == true { leaks.append("\(what)@\(i * 5)ms") }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        // Back from the newest (in memory) round to the oldest (in the recording), and on again.
        for n in 0..<status.total + 2 {
            f.view.findStep(forward: true)
            try await watch("step \(n) -> \(status.current)", 400)
        }
        #expect(leaks.isEmpty, "\(leaks)")
    }
}
