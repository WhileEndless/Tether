import Foundation
import CryptoKit
import Testing
@testable import RecordingKit
@testable import SearchKit

/// Encrypted recordings must read back exactly like plain ones — in every reader, compressed or
/// not — and must stay unreadable without their key. Keys are passed explicitly, so these tests
/// never touch the app-wide key other tests may be using.
@Suite struct RecordingCryptoTests {
    let key = SymmetricKey(size: .bits256)

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-enc-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes `lines` through a recorder in several flushes (several frames).
    func record(_ lines: [String], in dir: URL, key: SymmetricKey?) -> URL {
        let recorder = SessionRecorder(targetKey: "host", sessionID: UUID(), directory: dir, key: key)!
        for (i, line) in lines.enumerated() {
            recorder.append(Array((line + "\r\n").utf8))
            if i % 97 == 0 { recorder.flushNow() }
        }
        recorder.close()
        return recorder.url
    }

    func text(_ url: URL, key: SymmetricKey?) throws -> String {
        var data = Data()
        try RecordingReader.forEachChunk(of: url, key: key) { data += $0; return true }
        return String(decoding: data, as: UTF8.self)
    }

    let lines = (1...5000).map { "line \($0) — \(String(repeating: "x", count: $0 % 40))" }

    @Test func encryptedRecordingReadsBackAndHidesItsText() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = record(lines, in: dir, key: key)
        #expect(RecordingCrypto.isEncrypted(url))
        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: Data("line 4999".utf8)) == nil)          // nothing readable on disk
        #expect(try text(url, key: key) == lines.map { $0 + "\r\n" }.joined())
        // Scrolling back reads the end; transcripts read a slice.
        let tail = String(decoding: RecordingReader.tail(of: url, lines: 3, key: key) ?? [], as: UTF8.self)
        #expect(tail == lines.suffix(3).map { $0 + "\r\n" }.joined())
        let (slice, _) = RecordingReader.slice(of: url, around: 0.5, maxBytes: 10_000, key: key)
        #expect(String(decoding: slice, as: UTF8.self).contains("line 2500"))
        // Search reads it like a plain one.
        #expect(try SearchEngine.readLines(url, key: key).contains("line 1234 — \(String(repeating: "x", count: 1234 % 40))"))
    }

    @Test func withoutTheKeyNothingIsReadable() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = record(lines, in: dir, key: key)
        #expect(throws: RecordingCrypto.Failure.locked) { try text(url, key: nil) }
        #expect(throws: RecordingCrypto.Failure.wrongKey) { try text(url, key: SymmetricKey(size: .bits256)) }
        #expect(RecordingReader.tail(of: url, lines: 3, key: nil) == nil)
        #expect(RecordingReader.slice(of: url, around: 1, key: nil).0.isEmpty)
    }

    @Test func compressedEncryptedRecordingStaysEncrypted() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = record(lines, in: dir, key: key)
        let packed = try RecordingCompression.compress(url, key: key)
        #expect(RecordingCrypto.isEncrypted(packed))
        #expect(try text(packed, key: key) == lines.map { $0 + "\r\n" }.joined())
        #expect(String(decoding: RecordingReader.tail(of: packed, lines: 2, key: key) ?? [], as: UTF8.self)
                == lines.suffix(2).map { $0 + "\r\n" }.joined())
        #expect(throws: RecordingCrypto.Failure.locked) { try text(packed, key: nil) }
    }

    @Test func plainRecordingsAreEncryptedAndDecryptedInPlace() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = record(lines, in: dir, key: nil)
        let plainCompressed = try RecordingCompression.compress(record(lines, in: dir, key: nil), key: nil, encryptPlain: false)
        #expect(!RecordingCrypto.isEncrypted(url) && !RecordingCrypto.isEncrypted(plainCompressed))
        #expect(RecordingStore.encryptAll(with: key, in: dir) == 2)
        #expect(RecordingCrypto.isEncrypted(url) && RecordingCrypto.isEncrypted(plainCompressed))
        #expect(try text(url, key: key) == lines.map { $0 + "\r\n" }.joined())
        #expect(try text(plainCompressed, key: key) == lines.map { $0 + "\r\n" }.joined())
        #expect(RecordingCrypto.decryptFile(url, key: key))
        #expect(!RecordingCrypto.isEncrypted(url))
        #expect(try text(url, key: nil) == lines.map { $0 + "\r\n" }.joined())
    }

    @Test func aFrameCutShortByACrashIsIgnored() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = record(lines, in: dir, key: key)
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data([0, 0, 0x10, 0, 1, 2, 3]))      // half a frame
        try h.close()
        #expect(try text(url, key: key) == lines.map { $0 + "\r\n" }.joined())
        #expect(RecordingReader.tail(of: url, lines: 1, key: key) != nil)
    }

    @Test func aTamperedFrameIsRejected() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = record(["secret"], in: dir, key: key)
        var data = try Data(contentsOf: url)
        data[RecordingCrypto.headerSize + 10] ^= 0xff
        try data.write(to: url)
        #expect(throws: RecordingCrypto.Failure.corrupt) { try text(url, key: key) }
    }

    @Test func framesCannotBeReorderedOrSpliced() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = record(lines, in: dir, key: key), b = record(lines, in: dir, key: key)
        func frames(_ url: URL) throws -> (header: Data, frames: [Data]) {
            let data = try Data(contentsOf: url)
            let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
            let boxes = try FrameIndex(handle: h).boxes
            return (data.prefix(RecordingCrypto.headerSize), boxes.map { data.subdata(in: Int($0.offset) - 4..<Int($0.offset) + $0.length + 4) })
        }
        let fa = try frames(a), fb = try frames(b)
        #expect(fa.frames.count > 2)
        // Swap two frames of the same file.
        var swapped = fa.frames; swapped.swapAt(0, 1)
        try (fa.header + swapped.reduce(Data(), +)).write(to: a)
        #expect(throws: RecordingCrypto.Failure.corrupt) { try text(a, key: key) }
        // A frame from another recording (same key).
        var spliced = fb.frames; spliced[1] = fa.frames[1]
        try (fb.header + spliced.reduce(Data(), +)).write(to: b)
        #expect(throws: RecordingCrypto.Failure.corrupt) { try text(b, key: key) }
    }

    @Test func plainTextLookingLikeAHeaderIsStillEncrypted() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        // A server prints something that starts like an encrypted file (its own key id guess included).
        let forged = record(["TETHENC1" + String(repeating: "A", count: 40) + "rest of the output"], in: dir, key: nil)
        #expect(RecordingCrypto.isEncrypted(forged))                 // looks encrypted…
        #expect(!RecordingCrypto.isEncrypted(forged, with: key))     // …but is not, with the real key
        #expect(RecordingStore.encryptAll(with: key, in: dir) == 1)
        #expect(RecordingCrypto.isEncrypted(forged, with: key))
        #expect(try text(forged, key: key).contains("rest of the output"))
        #expect(RecordingStore.encryptionStatus(in: dir).encrypted == 1)
    }
}
