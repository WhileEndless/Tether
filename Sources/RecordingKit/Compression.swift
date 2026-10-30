import Foundation
import CryptoKit
import Compression

/// Compresses old recordings with LZFSE (fast, typically 5–10× smaller for terminal output) and
/// reads them back in chunks, so even very large transcripts never have to be held in memory.
public enum RecordingCompression {
    public static let compressedExtension = "lzfse"

    public static func isCompressed(_ url: URL) -> Bool { url.pathExtension == compressedExtension }

    /// Compresses `url` into `url.lzfse`, keeps its modification date, then removes the original.
    /// An encrypted recording (or any, while encryption is on) stays encrypted: compressed, then encrypted.
    @discardableResult
    public static func compress(_ url: URL, key loaded: SymmetricKey? = RecordingCrypto.key,
                                encryptPlain: Bool = RecordingCrypto.encryptNew) throws -> URL {
        // A file that just failed (the disk is full) is not tried again for a while: each try
        // writes a copy until the disk refuses, and maintenance runs every few megabytes of output.
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        if let failed = failures.withLock({ $0[url.path] }), Date().timeIntervalSince(failed.at) < 600 {
            throw failed.error
        }
        // The compressed copy is written next to the original first: it needs about a quarter of
        // the size (terminal output shrinks 5–10×), with a margin.
        if let free = try? url.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free > 0, free < size / 4 + 16 * 1024 * 1024 {
            let error = CocoaError(.fileWriteOutOfSpace) as NSError
            failures.withLock { $0[url.path] = (Date(), error) }
            throw error
        }
        do {
            let out = try compressNow(url, key: loaded, encryptPlain: encryptPlain)
            failures.withLock { _ = $0.removeValue(forKey: url.path) }
            return out
        } catch {
            // Tether locked while it ran: tried again as soon as it is unlocked, not 10 minutes later
            // (meanwhile the storage limit could only delete what it cannot compress).
            if (error as? RecordingCrypto.Failure) != .locked {
                failures.withLock { if $0.count > 1000 { $0.removeAll() }; $0[url.path] = (Date(), error as NSError) }
            }
            throw error
        }
    }

    private static let failures = Locked<[String: (at: Date, error: NSError)]>([:])

    private static func compressNow(_ url: URL, key loaded: SymmetricKey?, encryptPlain: Bool) throws -> URL {
        let out = url.appendingPathExtension(compressedExtension)
        let tmp = out.appendingPathExtension("tmp")
        let fm = FileManager.default
        // A crash between finishing the compressed copy and removing the original left both: the
        // compressed file is only ever moved into place complete, so the original can go — unless
        // it changed since (a session reopened it and wrote more): then both stay, nothing is lost.
        if fm.fileExists(atPath: out.path) {
            func modified(_ u: URL) -> Date? { (try? fm.attributesOfItem(atPath: u.path)[.modificationDate]) as? Date }
            guard let original = modified(url), let compressed = modified(out), original <= compressed else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: out.path])
            }
            try fm.removeItem(at: url)
            return out
        }
        let key = try RecordingCrypto.readingKey(for: url, loaded: loaded) ?? (encryptPlain ? loaded : nil)
        fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600])
        // Never leave a half-written file behind (it may hold the recording in plain text).
        var finished = false
        defer { if !finished { try? fm.removeItem(at: tmp) } }
        guard let output = try? FileHandle(forWritingTo: tmp) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? output.close() }
        var pending = Data()
        let file = key.map(RecordingCrypto.newFile)
        var index = 0
        func emit(_ data: Data, final: Bool) throws {
            guard let sealer = file?.sealer else { try output.write(contentsOf: data); return }
            pending += data
            while pending.count >= RecordingCrypto.fileFrameBytes || (final && !pending.isEmpty) {
                let chunk = pending.prefix(RecordingCrypto.fileFrameBytes)
                pending.removeFirst(chunk.count)
                guard let f = RecordingCrypto.frame(Data(chunk), sealer: sealer, index: index) else { throw RecordingCrypto.Failure.corrupt }
                try output.write(contentsOf: f)
                index += 1
            }
        }
        if let file { try output.write(contentsOf: file.header) }
        let filter = try OutputFilter(.compress, using: .lzfse) { data in
            if let data { try emit(data, final: false) }
        }
        try RecordingReader.forEachChunk(ofFile: url, key: loaded) { chunk in
            try filter.write(chunk)
            return true
        }
        try filter.finalize()
        try emit(Data(), final: true)
        try output.close()
        let date = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        try fm.moveItem(at: tmp, to: out)
        finished = true
        if let date { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: out.path) }
        if let mark = RecordingStore.redactionMark(of: url) { RecordingStore.setRedactionMark(mark, on: out) }
        try fm.removeItem(at: url)
        return out
    }

    /// Calls `body` with successive chunks of the (decrypted, decompressed) recording. Return false to stop.
    public static func forEachChunk(of url: URL, _ body: (Data) throws -> Bool) throws {
        try RecordingReader.forEachChunk(of: url, body)
    }

    /// The decompressed contents, keeping at most `maxBytes` around `fraction` (0…1) of the file.
    /// Returns the data and the position of `fraction` inside it.
    public static func slice(of url: URL, around fraction: Double, maxBytes: Int) -> (Data, Double) {
        RecordingReader.slice(of: url, around: fraction, maxBytes: maxBytes)
    }
}

/// A value guarded by a lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}
