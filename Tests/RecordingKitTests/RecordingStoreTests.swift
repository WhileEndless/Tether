import Foundation
import Testing
@testable import RecordingKit

@Suite struct RecordingStoreTests {
    @Test func quotaDeletesOldestFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-test-\(UUID())")
        let host = dir.appendingPathComponent("host")
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<4 {
            let url = host.appendingPathComponent("r\(i).\(RecordingStore.fileExtension)")
            try Data(repeating: 0x41, count: 1000).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1000 + i))],
                                                  ofItemAtPath: url.path)
        }
        let removed = RecordingStore.enforceQuota(in: dir, quota: 2500)
        #expect(removed.map(\.lastPathComponent).sorted() == ["r0.ttylog", "r1.ttylog"])
        #expect(RecordingStore.totalSize(in: dir) == 2000)
    }

    @Test func sanitizesKeys() {
        #expect(RecordingStore.sanitize("user@host:22") == "user@host_22")
        #expect(RecordingStore.sanitize("../../etc") == ".._.._etc")
    }
}

@Suite struct RecordingCompressionTests {
    @Test func compressesOldRecordingsAndReadsThemBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-z-\(UUID())")
        let host = dir.appendingPathComponent("host")
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = (0..<20_000).map { "line \($0) \u{1b}[32mok\u{1b}[0m\r\n" }.joined()
        let old = host.appendingPathComponent("old.\(RecordingStore.fileExtension)")
        let recent = host.appendingPathComponent("new.\(RecordingStore.fileExtension)")
        try Data(text.utf8).write(to: old)
        try Data(text.utf8).write(to: recent)
        let tenDaysAgo = Date().addingTimeInterval(-10 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: tenDaysAgo], ofItemAtPath: old.path)

        #expect(RecordingStore.compressOld(in: dir, olderThanDays: 7) == 1)
        let items = RecordingStore.all(in: dir)
        let z = try #require(items.first { $0.isCompressed })
        #expect(z.size < Int64(text.utf8.count) / 4, "should compress well")
        #expect(abs(z.modified.timeIntervalSince(tenDaysAgo)) < 1, "keeps the original date")
        #expect(items.contains { !$0.isCompressed })
        #expect(RecordingStore.resolve(old.path)?.resolvingSymlinksInPath().path == z.url.resolvingSymlinksInPath().path)

        var restored = Data()
        try RecordingCompression.forEachChunk(of: z.url) { restored.append($0); return true }
        #expect(restored == Data(text.utf8))

        let (slice, _) = RecordingStore.slice(of: z.url, around: 1, maxBytes: 10_000)
        #expect(slice.count <= 10_000 && String(decoding: slice, as: UTF8.self).contains("line 19999"))
    }
}

/// Recordings no archived session refers to remember which secret rules they were looked through
/// with, also once compressed.
@Suite struct RedactionMarkTests {
    @Test func markSurvivesCompression() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tether-mark-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.log")
        try Data("hello\n".utf8).write(to: url)
        #expect(RecordingStore.redactionMark(of: url) == nil)
        RecordingStore.setRedactionMark("abc123", on: url)
        #expect(RecordingStore.redactionMark(of: url) == "abc123")
        let compressed = try RecordingCompression.compress(url, key: nil, encryptPlain: false)
        #expect(RecordingStore.redactionMark(of: compressed) == "abc123")
    }
}

/// Compressing waits for an idle Mac; a pass compresses what waits, one file at a time, and stops
/// between files when asked to.
@Suite struct IdleCompressionTests {
    func setUp() throws -> (dir: URL, old: URL, recent: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-idle-\(UUID())")
        let host = dir.appendingPathComponent("host")
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        let text = Data((0..<5_000).map { "line \($0)\r\n" }.joined().utf8)
        let old = host.appendingPathComponent("old.\(RecordingStore.fileExtension)")
        let recent = host.appendingPathComponent("new.\(RecordingStore.fileExtension)")
        try text.write(to: old)
        try text.write(to: recent)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: old.path)
        return (dir, old, recent)
    }

    @Test func aPassCompressesOldRecordingsOnly() async throws {
        let (dir, old, recent) = try setUp()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(IdleCompression.candidates(in: dir, now: Date(), olderThanDays: 30).map(\.lastPathComponent) == [old.lastPathComponent])
        #expect(await IdleCompression.run(in: dir) { true })
        #expect(RecordingStore.resolve(old.path).map(RecordingCompression.isCompressed) == true)
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(IdleCompression.candidates(in: dir, now: Date(), olderThanDays: 30).isEmpty)
    }

    @Test func aPassStopsWhenTheMacIsUsed() async throws {
        let (dir, old, _) = try setUp()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(await IdleCompression.run(in: dir) { false } == false)
        #expect(FileManager.default.fileExists(atPath: old.path), "nothing compressed")
    }

    /// The storage limit alone no longer compresses: that waits for an idle Mac.
    @Test func aQuotaPassWithRoomLeftDoesNotCompress() throws {
        let (dir, old, _) = try setUp()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = RecordingStore.enforceQuota(in: dir)
        #expect(FileManager.default.fileExists(atPath: old.path))
    }
}
