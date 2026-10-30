import AppKit
import Testing
import SwiftTerm
import TetherCore
import RecordingKit
@testable import SessionKit
@testable import TerminalUI

/// Very long sessions: the screen keeps a bounded number of lines in memory (so it stays fast),
/// while the recording on disk keeps every line.
@MainActor
@Suite(.serialized) struct LongSessionTests {
    @Test func hundredThousandLinesStayFastAndNothingIsLostOnDisk() throws {
        _ = NSApplication.shared
        var settings = AppSettings()
        settings.scrollbackLines = 10_000
        let descriptor = SessionDescriptor(target: .local, persistence: .off)
        let session = TerminalSession(descriptor: descriptor) { SessionConfiguration(settings: settings) }
        let view = TetherTerminalView(session: session, settings: settings)
        view.getTerminal().resize(cols: 120, rows: 40)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-long-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = try #require(SessionRecorder(targetKey: "long", sessionID: UUID(), directory: dir))
        let recording = recorder.url

        let total = 100_000
        var chunk = ""
        let start = Date()
        for i in 1...total {
            chunk += "line \(i) \(String(repeating: "x", count: 60))\r\n"
            if i % 500 == 0 {
                let bytes = Array(chunk.utf8)
                view.feed(bytes[...])
                recorder.append(bytes)
                chunk = ""
            }
        }
        recorder.close()
        let feedTime = Date().timeIntervalSince(start)

        // Memory stays bounded: only the configured lines (plus the screen) are kept.
        let kept = view.scrollbackText().lines.count
        #expect(kept <= 10_000 + 40)
        #expect(view.scrollbackText().lines.last?.hasPrefix("line \(total) ") == true)

        // Scrolling through the whole buffer is instant.
        let scrollStart = Date()
        for _ in 0..<200 { view.scrollUp(lines: 50); view.scrollDown(lines: 50) }
        let scrollTime = Date().timeIntervalSince(scrollStart)

        // Every line is on disk.
        let text = try String(contentsOf: recording, encoding: .utf8)
        #expect(text.contains("line 1 xxx") && text.contains("line \(total) xxx"))
        #expect(text.components(separatedBy: "\r\nline ").count == total)

        print("feed \(total) lines: \(String(format: "%.2f", feedTime)) s, 400 scrolls: \(String(format: "%.3f", scrollTime)) s, kept \(kept) lines")
        #expect(feedTime < 20)
        #expect(scrollTime < 2)
    }

    @Test func scrollingPastMemoryLoadsEarlierOutputInPlace() async throws {
        _ = NSApplication.shared
        var settings = AppSettings()
        settings.scrollbackLines = 2_000
        let descriptor = SessionDescriptor(target: .local, persistence: .off)
        let session = TerminalSession(descriptor: descriptor) { SessionConfiguration(settings: settings) }
        let view = TetherTerminalView(session: session, settings: settings)
        view.getTerminal().resize(cols: 80, rows: 24)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-hist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = try #require(SessionRecorder(targetKey: "hist", sessionID: UUID(), directory: dir))
        for i in 1...10_000 {
            let bytes = Array("line \(i)\r\n".utf8)
            view.feed(bytes[...])
            recorder.append(bytes)
        }
        view.historyReader = { reader in recorder.snapshot(then: reader); return true }
        view.historyChunkLines = 3_000

        func topLine() -> String {
            let t = view.displayedTerminal.getTerminal()
            return t.getLine(row: 0)?.translateToString(trimRight: true).trimmingCharacters(in: .whitespaces) ?? ""
        }
        view.scrollTo(row: 0)
        let before = topLine()
        #expect(before.hasPrefix("line "))
        // Select a line that is on screen, then load earlier output.
        view.selection.setSelection(start: Position(col: 0, row: 5), end: Position(col: 9, row: 5))
        let selected = view.getSelection()
        let loaded = await withCheckedContinuation { done in
            view.onHistoryLoaded = { view.onHistoryLoaded = nil; done.resume(returning: $0) }
            if !view.loadOlderHistory() { done.resume(returning: false) }
        }
        #expect(loaded)
        #expect(view.isBrowsingHistory)
        #expect(topLine() == before, "the line at the top of the view does not move")
        #expect(view.getSelection() == selected, "the live terminal underneath is untouched")
        // Earlier lines are shown now, and scrolling up continues into them.
        view.displayedTerminal.scrollTo(row: 0)
        let earlier = Int(topLine().split(separator: " ").last ?? "") ?? 0
        let previous = Int(before.split(separator: " ").last ?? "") ?? 0
        #expect(earlier > 0 && earlier <= previous - 2_500)
        // Typing: the live terminal again, as it was.
        view.returnToLive()
        #expect(!view.isBrowsingHistory)
        #expect(view.getSelection() == selected)
        recorder.close()
    }
}
