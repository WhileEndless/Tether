import Foundation
import CryptoKit
import Testing
@testable import RecordingKit

/// Any part of a recording can be read by position, and by lines before or after a position,
/// whatever form it is kept in (plain, encrypted, in compressed parts).
@Suite(.serialized) struct RecordingRangeTests {
    func make(_ name: String, key: SymmetricKey?, parts: Bool) throws -> (URL, URL, Data) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-range-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let recorder = try #require(SessionRecorder(targetKey: "r", sessionID: UUID(), directory: dir, key: key, whileLocked: nil))
        if parts { recorder.partBytes = 50_000 }
        var all = Data()
        for i in 1...30_000 {
            let line = Data("line \(i) \(String(repeating: "x", count: i % 37))\r\n".utf8)
            recorder.append(line)
            all += line
            if i % 3_000 == 0 { recorder.flushNow() }
        }
        recorder.flushNow()
        if parts { RecordingParts.compressAll(in: dir) }
        let url = recorder.url
        recorder.close()
        return (dir, url, all)
    }

    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func readsByPositionAndByLines(encrypted: Bool, parts: Bool) throws {
        let key = encrypted ? SymmetricKey(size: .bits256) : nil
        let (dir, url, all) = try make("\(encrypted)\(parts)", key: key, parts: parts)
        defer { try? FileManager.default.removeItem(at: dir) }
        if parts { #expect(RecordingParts.parts(of: url).count > 3) }
        #expect(RecordingReader.length(of: url, key: key) == all.count)
        for (a, b) in [(0, 10), (12_345, 98_765), (all.count - 500, all.count), (49_990, 50_010)] {
            #expect(RecordingReader.bytes(of: url, from: a, to: b, key: key) == all.subdata(in: a..<b))
        }
        // Lines ending at a position: from a line start, exactly that many.
        let end = all.count / 2
        let alignedEnd = (all[..<end].lastIndex(of: 0x0a) ?? 0) + 1
        let before = RecordingReader.lines(of: url, endingAt: alignedEnd, count: 1_000, key: key)
        #expect(before.data == all.subdata(in: before.start..<alignedEnd))
        #expect(before.data.filter { $0 == 0x0a }.count == 1_000)
        #expect(before.start == 0 || all[before.start - 1] == 0x0a)
        // Lines starting there: up to and including the 1000th line break.
        let after = RecordingReader.lines(of: url, startingAt: alignedEnd, count: 1_000, total: all.count, key: key)
        #expect(after.data == all.subdata(in: alignedEnd..<after.end))
        #expect(after.data.filter { $0 == 0x0a }.count == 1_000 && after.data.last == 0x0a)
        // At the ends: what there is.
        #expect(RecordingReader.lines(of: url, endingAt: 100, count: 50, key: key).start == 0)
        #expect(RecordingReader.lines(of: url, startingAt: all.count - 30, count: 50, total: all.count, key: key).end == all.count)
    }
}
