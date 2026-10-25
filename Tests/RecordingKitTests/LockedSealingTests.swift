import Foundation
import CryptoKit
import Testing
@testable import RecordingKit

/// While Tether is locked, output and history are sealed to the public half of the recording key:
/// written now, readable only with the key. Keys are passed explicitly (never the app-wide key).
@Suite struct LockedSealingTests {
    let key = SymmetricKey(size: .bits256)

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("tether-locked-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func read(_ url: URL, key: SymmetricKey?) throws -> Data {
        var data = Data()
        try RecordingReader.forEachChunk(of: url, key: key) { data += $0; return true }
        return data
    }

    @Test func recordingWrittenWhileLockedOpensWithTheKey() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let sealing = RecordingCrypto.LockedSealing(key: key)
        let recorder = try #require(SessionRecorder(targetKey: "host", sessionID: UUID(), directory: dir, key: nil, whileLocked: sealing))
        recorder.partBytes = 4096
        var all = Data()
        for i in 0..<400 {
            let line = Data("secret line \(i)\r\n".utf8)
            all += line
            recorder.append(line)
            if i % 20 == 0 { recorder.flushNow() }
        }
        recorder.close()
        let raw = try Data(contentsOf: recorder.url)
        #expect(raw.prefix(8) == Data("TETHENC2".utf8))
        #expect(!String(decoding: raw, as: UTF8.self).contains("secret line"))
        #expect(!RecordingParts.parts(of: recorder.url).isEmpty)
        #expect(try read(recorder.url, key: key) == all)                  // the file and its parts
        #expect(throws: RecordingCrypto.Failure.locked) { _ = try read(recorder.url, key: nil) }
        #expect(throws: RecordingCrypto.Failure.wrongKey) { _ = try read(recorder.url, key: SymmetricKey(size: .bits256)) }
        #expect(RecordingCrypto.isEncrypted(recorder.url, with: key))
        #expect(!RecordingCrypto.isEncrypted(recorder.url, with: SymmetricKey(size: .bits256)))
        // Unlocked, it can be decrypted and compressed like any recording.
        #expect(RecordingCrypto.decryptFile(recorder.url, key: key))
    }

    @Test func aChangedHeaderIsRejected() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = try #require(SessionRecorder(targetKey: "host", sessionID: UUID(), directory: dir, key: nil,
                                                    whileLocked: RecordingCrypto.LockedSealing(key: key)))
        recorder.append(Array("text\r\n".utf8))
        recorder.close()
        var data = try Data(contentsOf: recorder.url)
        data[20] ^= 0xff                                                  // the file id
        try data.write(to: recorder.url)
        #expect(throws: RecordingCrypto.Failure.corrupt) { _ = try read(recorder.url, key: key) }
    }

    @Test func historySealedWhileLocked() throws {
        let sealing = RecordingCrypto.LockedSealing(key: key)
        let plain = Data("{\"records\":[]}".utf8)
        let sealed = try #require(SealedData.seal(plain, to: sealing))
        #expect(SealedData.isSealed(sealed))
        #expect(try SealedData.open(sealed, key: key) == plain)
        #expect(throws: RecordingCrypto.Failure.locked) { _ = try SealedData.open(sealed, key: nil) }
        #expect(throws: RecordingCrypto.Failure.wrongKey) { _ = try SealedData.open(sealed, key: SymmetricKey(size: .bits256)) }
        var tampered = sealed
        tampered[tampered.count - 1] ^= 1
        #expect(throws: RecordingCrypto.Failure.corrupt) { _ = try SealedData.open(tampered, key: key) }
    }

    @Test func sealingIsSavedAndLoaded() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let s = RecordingCrypto.LockedSealing(key: key)
        #expect(s == RecordingCrypto.LockedSealing(key: key))             // derived, never stored privately
        let data = try JSONEncoder().encode(s)
        #expect(!String(decoding: data, as: UTF8.self).isEmpty)
        #expect(try JSONDecoder().decode(RecordingCrypto.LockedSealing.self, from: data) == s)
    }
}

@Suite struct RevokedKeyTests {
    /// After the Tether password is reset, a recording still being written with the old key stops
    /// and removes itself (nothing could ever read it).
    @Test func recordingWithARevokedKeyRemovesItself() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-revoke-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let recorder = try #require(SessionRecorder(targetKey: "host", sessionID: UUID(), directory: dir, key: key))
        recorder.append(Array("before\r\n".utf8))
        recorder.flushNow()
        #expect(FileManager.default.fileExists(atPath: recorder.url.path))
        RecordingCrypto.revoke(keyID: RecordingCrypto.keyID(key))
        recorder.append(Array("after\r\n".utf8))
        recorder.flushNow()
        RecordingStore.waitForMaintenance()                          // removed on the maintenance queue
        #expect(!FileManager.default.fileExists(atPath: recorder.url.path))
        recorder.close()
    }
}
