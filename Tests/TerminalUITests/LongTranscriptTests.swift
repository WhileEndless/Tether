import AppKit
import Testing
import TetherCore
@testable import RecordingKit
@testable import TerminalUI

/// A session of any length can be read back whole: its recording, kept in compressed parts,
/// opens in the transcript window with every line from the first to the last.
@MainActor
struct LongTranscriptTests {
    @Test func aLongSessionInPartsShowsEveryLine() throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = try #require(SessionRecorder(targetKey: "long", sessionID: UUID(), directory: dir, key: nil, whileLocked: nil))
        recorder.partBytes = 100_000
        let total = 120_000
        for i in 1...total {
            recorder.append(Array("line \(i)\r\n".utf8))
            if i % 10_000 == 0 { recorder.flushNow() }      // parts start as the file grows
        }
        recorder.flushNow()
        let url = recorder.url
        #expect(RecordingParts.parts(of: url).count > 5)
        RecordingParts.compressAll(in: dir)

        let (data, _) = RecordingReader.slice(of: url, around: 1, maxBytes: 16 * 1024 * 1024)
        let view = ReadOnlyTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.getTerminal().resize(cols: 80, rows: 24)
        view.replay(Array(data)[...])
        let t = view.getTerminal()
        let first = t.getScrollInvariantLine(row: t.buffer.totalLinesTrimmed)?.translateToString(trimRight: true) ?? ""
        #expect(first == "line 1", "the first line is there (\(first))")
        #expect(t.buffer.totalLinesTrimmed == 0, "no line was dropped")
        recorder.close()
    }
}
