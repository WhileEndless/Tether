import Foundation
import Testing
import CryptoKit
@testable import RecordingKit
@testable import SearchKit

/// The recording searched from its end back: the newest matches first, each line once (also where
/// a program redrew across the segments' seams), with where it was written, regex too.
@Suite struct BackwardSearchTests {
    /// Blocks of progress redrawn in place, each ending with the same line, then its number.
    static func redrawn(blocks: Int) -> Data {
        var out = ""
        for b in 1...blocks {
            for fr in 0..<25 {
                var s = fr == 0 ? "" : "\u{1b}[6A"
                for l in 0..<6 { s += " step \(l) of block \(b) at \(fr)\u{1b}[K\r\n" }
                out += s
            }
            out += "needle done\r\nblock \(b)\r\n"
        }
        for i in 0..<400 { out += "tail \(i)\r\n" }
        return Data(out.utf8)
    }

    static func search(_ data: Data, _ pattern: String, memoryLines: Int = 0, memoryHead: [String] = [], segment: Int = 64 << 10) throws -> [[FoundLine]] {
        let regex = try NSRegularExpression(pattern: pattern)
        var batches: [[FoundLine]] = []
        try SearchEngine.findBackward(read: { data.subdata(in: $0..<min($1, data.count)) }, length: data.count, regex: regex,
                                      memoryLines: memoryLines, memoryHead: memoryHead, segment: segment) { batches.append($0); return true }
        return batches
    }

    @Test func newestFirstEachLineOnceWhereItWasWritten() throws {
        let data = Self.redrawn(blocks: 30)
        let batches = try Self.search(data, "needle", segment: 32 << 10)
        #expect(batches.count > 2, "several segments")
        let all = batches.reversed().flatMap { $0 }
        #expect(all.count == 30, "each once across the seams (\(all.count))")
        // Batches come newest first; inside one, oldest first.
        #expect(zip(all, all.dropFirst()).allSatisfy { $0.start <= $1.start })
        // Where each was written: within a step of the real place.
        let text = String(decoding: data, as: UTF8.self)
        var real: [Int] = []
        var from = text.startIndex
        while let r = text.range(of: "needle done", range: from..<text.endIndex) {
            real.append(text.utf8.distance(from: text.startIndex, to: r.lowerBound))
            from = r.upperBound
        }
        for (f, r) in zip(all, real) {
            #expect(f.start <= r && r - f.start < 4096, "written at \(r), noted \(f.start)")
            #expect(f.end >= r, "finished after it was written")
        }
    }

    @Test func memorysLinesAreLeftOutAndRegexWorks() throws {
        var out = ""
        for i in 0..<3000 { out += (i % 100 == 7 ? "error \(i): failed" : "line \(i)") + "\r\n" }
        let data = Data(out.utf8)
        // Memory holds the last 500 lines.
        let head = (2500..<2520).map { $0 % 100 == 7 ? "error \($0): failed" : "line \($0)" }
        let found = try Self.search(data, #"error \d+: fail"#, memoryLines: 500, memoryHead: head, segment: 16 << 10)
            .reversed().flatMap { $0 }
        #expect(found.map(\.text) == (0..<25).map { "error \($0 * 100 + 7): failed" })
        #expect(found.allSatisfy { $0.ranges.count == 1 })
    }

    /// An encrypted recording (parts rotated, so some are compressed): searched with its key as a
    /// plain one; while Tether is locked (no key) it reads as nothing — the search stops at once
    /// and says not all was searched.
    @Test func encryptedRecordings() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-backward-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let recorder = try #require(SessionRecorder(targetKey: "host", sessionID: UUID(), directory: dir, key: key))
        recorder.partBytes = 40_000
        let data = Self.redrawn(blocks: 30)
        for k in stride(from: 0, to: data.count, by: 7_000) {
            recorder.append(data.subdata(in: k..<min(k + 7_000, data.count)))
            recorder.flushNow()
        }
        let snap: RecordingSnapshot = await withCheckedContinuation { done in recorder.snapshot { done.resume(returning: $0) } }
        #expect(snap.length == data.count)
        #expect(RecordingCrypto.isEncrypted(snap.url))
        #expect(RecordingParts.parts(of: snap.url).count >= 2, "in several parts")
        let regex = try NSRegularExpression(pattern: "needle")
        var found: [FoundLine] = []
        let complete = try SearchEngine.findBackward(read: { snap.bytes(from: $0, to: $1, key: key) }, length: snap.length, regex: regex,
                                                     memoryLines: 0, memoryHead: [], segment: 32 << 10) { found = $0 + found; return true }
        #expect(complete)
        #expect(found == (try Self.search(data, "needle", segment: 32 << 10).reversed().flatMap { $0 }), "as the plain output")
        var reads = 0
        var lockedFound: [FoundLine] = []
        let lockedComplete = try SearchEngine.findBackward(read: { reads += 1; return snap.bytes(from: $0, to: $1, key: nil) }, length: snap.length,
                                                           regex: regex, memoryLines: 0, memoryHead: [], segment: 32 << 10) { lockedFound += $0; return true }
        #expect(!lockedComplete && lockedFound.isEmpty)
        #expect(reads <= 2, "stopped at once (\(reads) reads)")
        recorder.close()
    }
}
