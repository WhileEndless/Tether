import Foundation
import Testing
@testable import RecordingKit

/// The recorder knows where every line and command is; reading a recording finds the same.
struct RecordingIndexTests {
    @Test func theRecorderAndAReadingAgreeOnLinesAndCommands() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = try #require(SessionRecorder(targetKey: "i", sessionID: UUID(), directory: dir, key: nil, whileLocked: nil))
        recorder.partBytes = 300_000
        var all = Data()
        var commandStarts: [Int] = []
        for i in 1...5_000 {
            if i % 1_000 == 1 {
                let prompt = Data("$ make \(i)".utf8)
                commandStarts.append(all.count)
                recorder.append(prompt); all += prompt
                // Every other one with the column typing started at (older recordings have none).
                let column = i % 2_000 == 1 ? 2 : nil
                recorder.markCommand(at: Date(timeIntervalSince1970: Double(i)), column: column)
                all += Data(RecordingIndex.markBytes(at: Date(timeIntervalSince1970: Double(i)), column: column))
                recorder.append(Data("\r\n".utf8)); all += Data("\r\n".utf8)
            }
            let line = Data("output \(i) \(String(repeating: "x", count: 280))\r\n".utf8)
            recorder.append(line); all += line
            if i % 500 == 0 { recorder.flushNow() }
        }
        recorder.flushNow()
        let live = recorder.index
        #expect(live.length == all.count)
        #expect(live.lines == all.filter { $0 == 0x0a }.count)
        #expect(live.marks.map(\.offset) == commandStarts)
        #expect(live.partLengths.count >= 2)
        // Every checkpoint is a line start, `step` lines apart.
        for (k, offset) in live.checkpoints.enumerated() where k > 0 {
            #expect(all[offset - 1] == 0x0a)
            #expect(all[..<offset].filter { $0 == 0x0a }.count == live.checkpointLines[k])
        }
        let read = RecordingIndex.build(recorder.url, key: nil)
        #expect(read.lines == live.lines && read.checkpoints == live.checkpoints && read.length == live.length)
        #expect(read.checkpointLines == live.checkpointLines)
        #expect(read.partLengths == live.partLengths)
        #expect(read.marks.map(\.offset) == live.marks.map(\.offset))
        #expect(read.marks.map(\.time) == live.marks.map(\.time))
        #expect(read.marks.map(\.at) == live.marks.map(\.at))
        #expect(read.marks.map(\.column) == live.marks.map(\.column))
        #expect(live.marks.map(\.column).contains(2) && live.marks.map(\.column).contains(nil))
        #expect(live.checkpoint(before: live.checkpoints[3] + 5).offset == live.checkpoints[3])
        #expect(live.checkpoint(forLine: 3 * RecordingIndex.step + 7).line == 3 * RecordingIndex.step)
        recorder.close()
    }

    /// Every part removed by the storage limit: positions move back by all of them.
    @Test func allPartsGone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = try #require(SessionRecorder(targetKey: "i", sessionID: UUID(), directory: dir, key: nil, whileLocked: nil))
        recorder.partBytes = 20_000
        for i in 1...2_000 { recorder.append(Data("line \(i) xxxxxxxxxxxxxxxxxxxx\r\n".utf8)); if i % 200 == 0 { recorder.flushNow() } }
        recorder.flushNow()
        let index = recorder.index
        #expect(index.partLengths.count >= 2)
        #expect(index.removedLength(firstPart: nil) == index.partLengths.reduce(0, +))
        #expect(index.removedLength(firstPart: 1) == 0)
        // An index read that is stopped (the recording closes meanwhile) does not claim to be exact.
        #expect(RecordingIndex.build(recorder.url, key: nil).isExact)
        #expect(!RecordingIndex.build(recorder.url, key: nil, stop: { true }).isExact)
        recorder.close()
    }

    /// Very short lines: checkpoints stay far enough apart that the index cannot grow without limit.
    @Test func shortLinesDoNotFillTheIndex() {
        var index = RecordingIndex()
        let chunk = Data(String(repeating: "y\n", count: 50_000).utf8)
        for _ in 0..<20 { index.add(chunk) }          // a million lines, 2 MB
        #expect(index.lines == 1_000_000)
        #expect(index.checkpoints.count <= index.length / RecordingIndex.minSpacing + 1)
        let near = index.checkpoint(forLine: 600_000)
        #expect(near.line <= 600_000 && 600_000 - near.line < RecordingIndex.minSpacing)
        #expect(near.offset == near.line * 2)
    }

    /// Between checkpoints a position's line is estimated by its bytes, not rounded down to the
    /// checkpoint (64 KB apart can be thousands of short lines).
    @Test func linesBetweenCheckpointsAreInterpolated() {
        var index = RecordingIndex()
        let line = Array("0123456789\n".utf8)   // 11 bytes
        for _ in 0..<30_000 { index.add(line) }
        #expect(index.checkpoints.count > 2)
        for target in [100, 5_000, 12_345, 29_000] {
            let estimate = index.line(near: target * 11)
            #expect(abs(estimate - Double(target)) <= 1, "line \(target): \(estimate)")
        }
        #expect(index.line(near: 0) == 0)
        #expect(abs(index.line(near: index.length) - Double(index.lines)) < 1)
    }
}
