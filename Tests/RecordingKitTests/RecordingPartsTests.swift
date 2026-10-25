import Foundation
import CryptoKit
import Testing
@testable import RecordingKit

/// Long sessions are recorded in parts that are compressed while the session runs; every reader
/// still sees one recording. Everything happens in a temporary folder.
@Suite struct RecordingPartsTests {
    func tempDir() throws -> URL {
        // Resolved (/private/var…), so paths match the folder listing's.
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("tether-parts-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Records `count` numbered lines of about 100 bytes, in parts of `partBytes`.
    func record(_ count: Int, in dir: URL, partBytes: Int, key: SymmetricKey? = nil) -> (SessionRecorder, Data) {
        let recorder = SessionRecorder(targetKey: "host", sessionID: UUID(), directory: dir, key: key)!
        recorder.partBytes = partBytes
        var all = Data()
        for i in 0..<count {
            let line = Data("line \(i) \(String(repeating: "x", count: 90))\r\n".utf8)
            all += line
            recorder.append(line)
            if i % 100 == 0 { recorder.flushNow() }
        }
        recorder.flushNow()
        return (recorder, all)
    }

    func read(_ url: URL, key: SymmetricKey? = nil) throws -> Data {
        var data = Data()
        try RecordingReader.forEachChunk(of: url, key: key) { data += $0; return true }
        return data
    }

    @Test func longSessionIsKeptInCompressedPartsAndReadsAsOne() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (recorder, all) = record(5_000, in: dir, partBytes: 64 * 1024)
        #expect(recorder.flushedLength() == all.count)
        RecordingStore.waitForMaintenance()
        RecordingParts.compressAll(in: dir)

        let parts = RecordingParts.parts(of: recorder.url)
        #expect(parts.count >= 5)
        #expect(parts.allSatisfy { RecordingCompression.isCompressed($0.url) })
        #expect(parts.map(\.number) == Array(1...parts.count))
        #expect(try read(recorder.url) == all)                       // parts, then the file, in order

        // Scrolling back: the last lines, across parts.
        let tail = try #require(RecordingReader.tail(of: recorder.url, lines: 2_000))
        let lines = tail.split(separator: 0x0a).map { String(decoding: $0, as: UTF8.self) }
        #expect(lines.count == 2_000)
        #expect(lines.first?.hasPrefix("line 3000 ") == true)
        #expect(lines.last?.hasPrefix("line 4999 ") == true)

        // Playback finds a position without reading the whole recording.
        let (start, _) = RecordingReader.slice(of: recorder.url, around: 0, maxBytes: 4096)
        #expect(String(decoding: start, as: UTF8.self).hasPrefix("line 0 "))
        let (middle, _) = RecordingReader.slice(of: recorder.url, around: 0.5, maxBytes: 4096)
        let n = String(decoding: middle, as: UTF8.self).split(separator: " ").dropFirst().first.flatMap { Int($0) }
        #expect((2_300...2_700).contains(n ?? -1))

        // Listed, sized and removed as one recording.
        let items = RecordingStore.all(in: dir)
        #expect(items.count == 1)
        #expect(items.first?.parts.count == parts.count)
        recorder.close()
        RecordingStore.deleteAll(in: dir)
        #expect(RecordingStore.all(in: dir).isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("host").path)
        #expect(left.isEmpty)
    }

    @Test func encryptedPartsStayEncryptedAndReadable() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let (recorder, all) = record(3_000, in: dir, partBytes: 64 * 1024, key: key)
        recorder.close()
        let parts = RecordingParts.parts(of: recorder.url)
        #expect(!parts.isEmpty)
        #expect(parts.allSatisfy { RecordingCrypto.isEncrypted($0.url, with: key) })
        #expect(RecordingCrypto.isEncrypted(recorder.url, with: key))
        #expect(try read(recorder.url, key: key) == all)
        #expect(throws: RecordingCrypto.Failure.locked) { _ = try read(recorder.url) }
        let tail = try #require(RecordingReader.tail(of: recorder.url, lines: 10, key: key))
        #expect(String(decoding: tail, as: UTF8.self).hasPrefix("line 2990 "))
    }

    @Test func reopenedRecordingContinuesItsParts() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let (first, before) = record(1_500, in: dir, partBytes: 64 * 1024)
        first.close()
        let count = RecordingParts.parts(of: first.url).count
        let again = try #require(SessionRecorder(existing: first.url))
        again.partBytes = 64 * 1024
        #expect(again.flushedLength() == before.count)
        var after = Data()
        for i in 0..<1_500 {
            let line = Data("more \(i) \(String(repeating: "y", count: 90))\r\n".utf8)
            after += line
            again.append(line)
            if i % 100 == 0 { again.flushNow() }
        }
        again.close()
        let parts = RecordingParts.parts(of: first.url)
        #expect(parts.count > count)
        #expect(parts.map(\.number) == Array(1...parts.count))
        #expect(try read(first.url) == before + after)
    }

    @Test func fullStorageShortensTheLargestSessionBeforeRemovingOthers() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let host = dir.appendingPathComponent("host")
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        // An older, small recording of another session.
        let small = host.appendingPathComponent("old.\(RecordingStore.fileExtension)")
        try Data(repeating: 0x41, count: 10_000).write(to: small)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: small.path)
        // A huge running session, in parts.
        let (recorder, _) = record(6_000, in: dir, partBytes: 64 * 1024)
        defer { recorder.close() }
        RecordingStore.waitForMaintenance()
        let before = RecordingParts.parts(of: recorder.url)
        let total = RecordingStore.totalSize(in: dir)

        let removed = RecordingStore.enforceQuota(in: dir, quota: total - 1)
        #expect(FileManager.default.fileExists(atPath: small.path))    // the other session is kept
        #expect(removed.count == 1)
        #expect(removed.first?.lastPathComponent == before.first.map { RecordingParts.current($0.url).lastPathComponent })
        #expect(FileManager.default.fileExists(atPath: recorder.url.path))   // the file being written is never touched
    }
}

@Suite struct RecordingTailBoundsTests {
    /// Output with almost no line breaks (a full-screen program redrawing) never brings more than
    /// `tailMaxBytes` into memory, whatever number of lines is asked for.
    @Test func tailReadsAtMostItsLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tether-tail-\(UUID()).ttylog")
        defer { try? FileManager.default.removeItem(at: url) }
        let redraw = Data(("\u{1b}[H" + String(repeating: "#", count: 4000)).utf8)
        var data = Data("first\n".utf8)
        while data.count < RecordingReader.tailMaxBytes + 4 * 1024 * 1024 { data += redraw }
        data += Data("\nlast line\n".utf8)
        try data.write(to: url)
        let tail = try #require(RecordingReader.tail(of: url, lines: 10_000))
        #expect(tail.count <= RecordingReader.tailMaxBytes)
        #expect(String(decoding: tail.suffix(10), as: UTF8.self) == "last line\n")
    }

    @Test func compressedSliceFindsTheStart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tether-zslice-\(UUID()).ttylog")
        let text = (0..<50_000).map { "row \($0)\n" }.joined()
        try Data(text.utf8).write(to: url)
        let z = try RecordingCompression.compress(url)
        defer { try? FileManager.default.removeItem(at: z) }
        let (start, _) = RecordingReader.slice(of: z, around: 0, maxBytes: 1000)
        #expect(String(decoding: start, as: UTF8.self).hasPrefix("row 0\n"))
        #expect(start.count <= 1000)
        let (end, _) = RecordingReader.slice(of: z, around: 1, maxBytes: 1000)
        #expect(String(decoding: end, as: UTF8.self).hasSuffix("row 49999\n"))
    }
}

@Suite struct RecordingRecoveryTests {
    /// A frame cut short (a crash or a full disk while writing) is cut off when the recording is
    /// opened again, so what is written after it stays readable.
    @Test func appendingAfterATornFrameKeepsLaterOutput() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-torn-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let first = try #require(SessionRecorder(targetKey: "host", sessionID: UUID(), directory: dir, key: key))
        first.append(Array("before\r\n".utf8))
        first.close()
        let h = try FileHandle(forWritingTo: first.url)
        h.seekToEndOfFile()
        h.write(Data([0, 0, 1, 0, 9, 9, 9]))           // the start of a frame that never finished
        try h.close()
        let again = try #require(SessionRecorder(existing: first.url, key: key))
        again.append(Array("after\r\n".utf8))
        again.close()
        var text = Data()
        try RecordingReader.forEachChunk(of: first.url, key: key) { text += $0; return true }
        #expect(String(decoding: text, as: UTF8.self) == "before\r\nafter\r\n")
    }

    @Test func compressionFinishedBeforeACrashIsNotDoneTwice() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tether-dup-\(UUID()).ttylog")
        try Data("text\n".utf8).write(to: url)
        let z = try RecordingCompression.compress(url)
        defer { try? FileManager.default.removeItem(at: z) }
        try Data("text\n".utf8).write(to: url)          // as if the original had not been removed
        let date = try #require(try FileManager.default.attributesOfItem(atPath: z.path)[.modificationDate] as? Date)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        #expect(try RecordingCompression.compress(url) == z)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // Written to after the crash (a session reopened it): both are kept.
        try Data("text\nmore\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(60)], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try RecordingCompression.compress(url) }
        #expect(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite struct RecordingPartsConcurrencyTests {
    /// While the recorder writes and starts new parts, every read gives a whole prefix of the output,
    /// in order, at least as long as the length taken just before it.
    @Test func readsDuringRotationSkipNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("tether-rot-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = try #require(SessionRecorder(targetKey: "host", sessionID: UUID(), directory: dir, key: nil))
        recorder.partBytes = 4096
        let lines = (0..<6_000).map { Data("line \($0) \(String(repeating: "x", count: 40))\r\n".utf8) }
        var all = Data()
        lines.forEach { all += $0 }
        let writer = Task.detached {
            for (i, line) in lines.enumerated() {
                recorder.append(line)
                if i % 25 == 0 { recorder.flushNow() }
            }
            recorder.flushNow()
        }
        for _ in 0..<40 {
            let length = recorder.flushedLength()
            var read = Data()
            try RecordingReader.forEachChunk(of: recorder.url, key: nil) { read += $0; return true }
            #expect(read.count >= length, "read \(read.count) of \(length)")
            #expect(read == all.prefix(read.count))
        }
        await writer.value
        recorder.close()
    }

    /// After the storage limit removed the oldest parts, the length counts only what is there.
    @Test func lengthCountsOnlyPartsThatAreThere() throws {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("tether-len-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = try #require(SessionRecorder(targetKey: "host", sessionID: UUID(), directory: dir, key: nil))
        recorder.partBytes = 4096
        for i in 0..<1_000 { recorder.append(Array("line \(i) \(String(repeating: "y", count: 40))\r\n".utf8)); if i % 20 == 0 { recorder.flushNow() } }
        recorder.flushNow()
        let first = try #require(RecordingParts.parts(of: recorder.url).first)
        try FileManager.default.removeItem(at: RecordingParts.current(first.url))
        var read = 0
        try RecordingReader.forEachChunk(of: recorder.url, key: nil) { read += $0.count; return true }
        #expect(recorder.flushedLength() == read)
        recorder.close()
    }

    /// A password reset removes encrypted recordings, never plain output that only starts like one.
    @Test func plainOutputLookingEncryptedIsNotWiped() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-wipe-\(UUID())")
        let host = dir.appendingPathComponent("host")
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = host.appendingPathComponent("a.\(RecordingStore.fileExtension)")
        try Data(("TETHENC1" + String(repeating: "A", count: 40) + "the user's output\n").utf8).write(to: plain)
        let real = try #require(SessionRecorder(targetKey: "host", sessionID: UUID(), directory: dir, key: SymmetricKey(size: .bits256)))
        real.append(Array("secret\r\n".utf8))
        real.close()
        RecordingStore.deleteEncrypted(in: dir)
        #expect(FileManager.default.fileExists(atPath: plain.path))
        #expect(!FileManager.default.fileExists(atPath: real.url.path))
    }
}
