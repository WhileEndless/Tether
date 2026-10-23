import Foundation
import CryptoKit
import Compression

/// Optional encryption of recordings at rest (AES-256-GCM).
///
/// File layout: a 48-byte header, then frames, one per write batch:
///
///     header  "TETHENC1" · key id (8: SHA-256 of the key) · file id (16, random) · tag (16)
///     frame   [UInt32 length][nonce + ciphertext + GCM tag][UInt32 length]
///
/// - The header tag is an HMAC of the header made with the key, so text a server prints at the start
///   of a plain recording can never pass for an encrypted file (which would keep it from being encrypted).
/// - Each frame is authenticated together with the file id and its position, so frames cannot be
///   reordered, repeated or moved from another recording unnoticed.
/// - A file cut off exactly at a frame boundary is not detected (recordings are appended to while
///   they run, so there is no final frame); everything that is there is authentic.
/// - The length on both sides lets readers walk the file from the end (scrolling back into history
///   reads only the last frames). A frame cut short by a crash is ignored. File names do not change:
/// whether a recording is encrypted is read from its first bytes, so quota, listing and compression
/// work the same for both kinds. A compressed recording is compressed first, then encrypted.
public enum RecordingCrypto {
    public static let headerSize = 48
    static let magic = Data("TETHENC1".utf8)
    /// Nonce (12) + tag (16).
    static let overhead = 28
    /// Plain bytes per frame when a whole file is encrypted at once (migration, compression).
    static let fileFrameBytes = 1 << 20

    public enum Failure: Error, Equatable {
        /// The recording is encrypted and no key is loaded (Tether is locked).
        case locked
        /// Encrypted with another key (e.g. after the password was reset).
        case wrongKey
        case corrupt
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _key: SymmetricKey?
    nonisolated(unsafe) private static var _encryptNew = false

    /// The key for reading (and writing) encrypted recordings; nil while Tether is locked.
    public static var key: SymmetricKey? {
        get { lock.lock(); defer { lock.unlock() }; return _key }
        set { lock.lock(); _key = newValue; lock.unlock() }
    }

    /// New recordings are written encrypted (when a key is loaded).
    public static var encryptNew: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _encryptNew }
        set { lock.lock(); _encryptNew = newValue; lock.unlock() }
    }

    /// The key new recordings are encrypted with, or nil to write them in plain text.
    public static var writerKey: SymmetricKey? {
        lock.lock(); defer { lock.unlock() }
        return _encryptNew ? _key : nil
    }

    public static func keyID(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data(SHA256.hash(data: Data($0)).prefix(8)) }
    }

    /// What seals and opens the frames of one file. Frames and the header signature use separate
    /// keys derived from the recording key (HKDF), never the recording key itself.
    struct Sealer {
        let key: SymmetricKey
        let fileID: Data
        init(key: SymmetricKey, fileID: Data) {
            self.key = RecordingCrypto.subkey(key, "frames")
            self.fileID = fileID
        }
    }

    static func subkey(_ key: SymmetricKey, _ purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data("tether-recording-v1-\(purpose)".utf8), outputByteCount: 32)
    }

    /// A header for a new encrypted file, and the sealer for its frames.
    static func newFile(_ key: SymmetricKey) -> (header: Data, sealer: Sealer) {
        let fileID = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let body = magic + keyID(key) + fileID
        let tag = Data(HMAC<SHA256>.authenticationCode(for: body, using: subkey(key, "header")).prefix(16))
        return (body + tag, Sealer(key: key, fileID: fileID))
    }

    private struct Header {
        var keyID: Data
        var fileID: Data
        var tag: Data
        var body: Data
    }

    private static func header(of url: URL) -> Header? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: headerSize), head.count == headerSize, head.prefix(8) == magic else { return nil }
        let d = Data(head)
        return Header(keyID: d.subdata(in: 8..<16), fileID: d.subdata(in: 16..<32), tag: d.subdata(in: 32..<48), body: d.prefix(32))
    }

    /// The key id in an encrypted recording's header, or nil for a plain one.
    public static func keyID(of url: URL) -> Data? { header(of: url)?.keyID }

    /// Looks encrypted (without a key this cannot be confirmed).
    public static func isEncrypted(_ url: URL) -> Bool { header(of: url) != nil }

    /// Really encrypted with `key`: its header is signed with it.
    public static func isEncrypted(_ url: URL, with key: SymmetricKey) -> Bool {
        guard let h = header(of: url), h.keyID == keyID(key) else { return false }
        var signed = HMAC<SHA256>.authenticationCode(for: h.body, using: subkey(key, "header")).makeIterator()
        var tag = h.tag.makeIterator()
        var diff: UInt8 = 0
        while let a = tag.next(), let b = signed.next() { diff |= a ^ b }   // constant time
        return diff == 0
    }

    /// Authenticated data of a frame: the file it belongs to and its position.
    private static func aad(_ fileID: Data, _ index: Int) -> Data {
        var i = UInt64(index).bigEndian
        return fileID + Data(bytes: &i, count: 8)
    }

    /// One frame holding `plain`, frame number `index` of the file.
    static func frame(_ plain: Data, sealer: Sealer, index: Int) -> Data? {
        guard let box = try? AES.GCM.seal(plain, using: sealer.key, authenticating: aad(sealer.fileID, index)).combined else { return nil }
        var len = UInt32(box.count).bigEndian
        let lenData = Data(bytes: &len, count: 4)
        return lenData + box + lenData
    }

    static func open(_ box: Data, sealer: Sealer, index: Int) throws -> Data {
        do { return try AES.GCM.open(AES.GCM.SealedBox(combined: box), using: sealer.key, authenticating: aad(sealer.fileID, index)) }
        catch { throw Failure.corrupt }
    }

    /// What opens `url` (with `loaded`, if it is the file's key); nil for a plain recording.
    static func sealer(for url: URL, loaded: SymmetricKey? = RecordingCrypto.key) throws -> Sealer? {
        guard let h = header(of: url) else { return nil }
        guard let key = loaded else { throw Failure.locked }
        guard h.keyID == keyID(key) else { throw Failure.wrongKey }
        guard isEncrypted(url, with: key) else { throw Failure.corrupt }
        return Sealer(key: key, fileID: h.fileID)
    }

    /// The key that opens `url`; nil for a plain recording.
    static func readingKey(for url: URL, loaded: SymmetricKey? = RecordingCrypto.key) throws -> SymmetricKey? {
        try sealer(for: url, loaded: loaded) == nil ? nil : loaded   // the recording key, not the frame subkey
    }

    // MARK: Converting whole files

    /// Encrypts a plain recording in place (compressed or not, the bytes are kept as they are),
    /// keeping its modification date. Returns false if it was not plain or could not be written.
    @discardableResult
    public static func encryptFile(_ url: URL, key: SymmetricKey) -> Bool {
        // Not really encrypted with this key (plain, or merely starting like an encrypted file): encrypt.
        guard !isEncrypted(url, with: key) else { return false }
        return rewrite(url) { input, output in
            let (head, sealer) = newFile(key)
            try output.write(contentsOf: head)
            var index = 0
            while let chunk = try input.read(upToCount: fileFrameBytes), !chunk.isEmpty {
                guard let f = frame(chunk, sealer: sealer, index: index) else { throw Failure.corrupt }
                try output.write(contentsOf: f)
                index += 1
            }
        }
    }

    /// Turns an encrypted recording back into plain bytes (when encryption is switched off).
    @discardableResult
    public static func decryptFile(_ url: URL, key: SymmetricKey? = RecordingCrypto.key) -> Bool {
        guard (try? readingKey(for: url, loaded: key)) != nil else { return false }
        return rewrite(url) { _, output in
            let cursor = try RawCursor(url: url, key: key)
            while let chunk = try cursor.read(upTo: fileFrameBytes), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
        }
    }

    /// Writes a replacement next to `url`, then swaps it in (never leaving a half-written recording).
    private static func rewrite(_ url: URL, _ body: (FileHandle, FileHandle) throws -> Void) -> Bool {
        let fm = FileManager.default
        let tmp = url.appendingPathExtension("tmp")
        guard fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let input = try? FileHandle(forReadingFrom: url), let output = try? FileHandle(forWritingTo: tmp) else { return false }
        let date = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        do {
            try body(input, output)
            try input.close()
            try output.close()
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
            if let date { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
            return true
        } catch {
            try? input.close(); try? output.close()
            try? fm.removeItem(at: tmp)
            return false
        }
    }
}

/// Frames of an encrypted recording: where each box is and how much plain text it holds.
struct FrameIndex {
    var boxes: [(offset: UInt64, length: Int)] = []

    var plainLengths: [Int] { boxes.map { $0.length - RecordingCrypto.overhead } }

    /// Walks the frames from the header on, stopping at a frame cut short.
    init(handle: FileHandle) throws {
        let size = try handle.seekToEnd()
        var pos = UInt64(RecordingCrypto.headerSize)
        while pos + 8 <= size {
            try handle.seek(toOffset: pos)
            guard let lenData = try handle.read(upToCount: 4), lenData.count == 4 else { break }
            let len = Int(lenData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
            guard len >= RecordingCrypto.overhead, pos + 8 + UInt64(len) <= size else { break }
            boxes.append((pos + 4, len))
            pos += 8 + UInt64(len)
        }
    }

    static func decrypt(_ box: (offset: UInt64, length: Int), index: Int, handle: FileHandle, sealer: RecordingCrypto.Sealer) throws -> Data {
        try handle.seek(toOffset: box.offset)
        guard let data = try handle.read(upToCount: box.length), data.count == box.length else { throw RecordingCrypto.Failure.corrupt }
        return try RecordingCrypto.open(data, sealer: sealer, index: index)
    }
}

/// Reads a recording's stored bytes in order — decrypted if it is encrypted, still compressed if
/// it is compressed.
final class RawCursor {
    private let handle: FileHandle
    private let sealer: RecordingCrypto.Sealer?
    private var frames: [(offset: UInt64, length: Int)] = []
    private var next = 0
    private var buffer = Data()

    init(url: URL, key loaded: SymmetricKey? = RecordingCrypto.key) throws {
        guard let h = try? FileHandle(forReadingFrom: url) else { throw CocoaError(.fileReadNoSuchFile) }
        handle = h
        sealer = try RecordingCrypto.sealer(for: url, loaded: loaded)
        if sealer != nil { frames = try FrameIndex(handle: h).boxes }
    }

    deinit { try? handle.close() }

    /// Up to `n` bytes; empty at the end.
    func read(upTo n: Int) throws -> Data? {
        guard let sealer else { return try handle.read(upToCount: n) }
        while buffer.count < n, next < frames.count {
            buffer += try FrameIndex.decrypt(frames[next], index: next, handle: handle, sealer: sealer)
            next += 1
        }
        let out = buffer.prefix(n)
        buffer.removeFirst(out.count)
        return Data(out)
    }
}

/// Every way of reading a recording, for plain, encrypted and compressed files alike.
public enum RecordingReader {
    /// Successive chunks of the recording's text (decrypted and decompressed). Return false to stop.
    public static func forEachChunk(of url: URL, key: SymmetricKey? = RecordingCrypto.key,
                                    _ body: (Data) throws -> Bool) throws {
        let cursor = try RawCursor(url: url, key: key)
        if RecordingCompression.isCompressed(url) {
            let filter = try InputFilter(.decompress, using: .lzfse) { length in try cursor.read(upTo: length) }
            while let chunk = try filter.readData(ofLength: 4 << 20), !chunk.isEmpty {
                if try !body(chunk) { return }
            }
        } else {
            while let chunk = try cursor.read(upTo: 4 << 20), !chunk.isEmpty {
                if try !body(chunk) { return }
            }
        }
    }

    /// The last `lines` lines of a recording, starting at a line boundary. Reads only the end of
    /// the file (backwards) unless it is compressed.
    public static func tail(of url: URL, lines: Int, key loaded: SymmetricKey? = RecordingCrypto.key) -> [UInt8]? {
        if RecordingCompression.isCompressed(url) {
            let data = slice(of: url, around: 1, maxBytes: 16 * 1024 * 1024, key: loaded).0
            return Array(cutToLastLines(data, lines))
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let sealer = try? RecordingCrypto.sealer(for: url, loaded: loaded) else {
            if RecordingCrypto.isEncrypted(url) { return nil }   // locked or another key
            return plainTail(handle: handle, lines: lines)
        }
        guard let frames = try? FrameIndex(handle: handle).boxes else { return nil }
        var collected = Data()
        var newlines = 0
        for (index, box) in frames.enumerated().reversed() {
            guard let plain = try? FrameIndex.decrypt(box, index: index, handle: handle, sealer: sealer) else { break }
            collected = plain + collected
            newlines += plain.reduce(0) { $0 + ($1 == 0x0a ? 1 : 0) }
            if newlines > lines { break }
        }
        return Array(cutToLastLines(collected, lines))
    }

    private static func plainTail(handle: FileHandle, lines: Int) -> [UInt8]? {
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let block: UInt64 = 1 << 20
        var offset = size
        var newlines = 0
        var start: UInt64 = 0
        outer: while offset > 0 {
            let read = min(block, offset)
            offset -= read
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.read(upToCount: Int(read)) else { return nil }
            var i = data.count - 1
            while i >= 0 {
                if data[data.startIndex + i] == 0x0a {
                    newlines += 1
                    if newlines > lines { start = offset + UInt64(i) + 1; break outer }
                }
                i -= 1
            }
        }
        try? handle.seek(toOffset: start)
        return (try? handle.readToEnd()).map { Array($0) }
    }

    /// Drops everything before the last `lines` lines.
    private static func cutToLastLines(_ data: Data, _ lines: Int) -> Data {
        var count = 0
        var i = data.endIndex
        while i > data.startIndex {
            i -= 1
            if data[i] == 0x0a {
                count += 1
                if count > lines { return data.subdata(in: (i + 1)..<data.endIndex) }
            }
        }
        return data
    }

    /// Up to `maxBytes` of a recording centred on `fraction` (0…1), starting at a line boundary, and
    /// where `fraction` lies within the returned data.
    public static func slice(of url: URL, around fraction: Double, maxBytes: Int = 16 * 1024 * 1024,
                             key loaded: SymmetricKey? = RecordingCrypto.key) -> (Data, Double) {
        if RecordingCompression.isCompressed(url) { return slidingSlice(of: url, around: fraction, maxBytes: maxBytes, key: loaded) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (Data(), 0) }
        defer { try? handle.close() }
        if let sealer = try? RecordingCrypto.sealer(for: url, loaded: loaded) {
            guard let frames = try? FrameIndex(handle: handle).boxes else { return (Data(), 0) }
            let lengths = frames.map { $0.length - RecordingCrypto.overhead }
            let total = lengths.reduce(0, +)
            let center = Double(total) * min(max(fraction, 0), 1)
            let start = max(0, min(Int(center) - maxBytes / 2, total - maxBytes))
            let end = min(total, start + maxBytes)
            var data = Data()
            var pos = 0
            for (i, len) in lengths.enumerated() {
                defer { pos += len }
                guard pos + len > start, pos < end else { continue }
                guard let plain = try? FrameIndex.decrypt(frames[i], index: i, handle: handle, sealer: sealer) else { break }
                let lo = max(start - pos, 0), hi = min(end - pos, len)
                data += plain.subdata(in: lo..<hi)
            }
            return lineAligned(data, start: start, center: center)
        }
        if RecordingCrypto.isEncrypted(url) { return (Data(), 0) }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > UInt64(maxBytes) else {
            try? handle.seek(toOffset: 0)
            return ((try? handle.readToEnd()) ?? Data(), fraction)
        }
        let center = Double(size) * min(max(fraction, 0), 1)
        let start = UInt64(max(0, min(center - Double(maxBytes) / 2, Double(size) - Double(maxBytes))))
        try? handle.seek(toOffset: start)
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        return lineAligned(data, start: Int(start), center: center)
    }

    /// Starts at a line boundary so a replay does not begin inside an escape sequence.
    private static func lineAligned(_ raw: Data, start: Int, center: Double) -> (Data, Double) {
        var data = raw
        var skipped = 0
        if start > 0, let nl = data.firstIndex(of: 0x0a) {
            skipped = nl + 1 - data.startIndex
            data = data.subdata(in: (nl + 1)..<data.endIndex)
        }
        return (data, (center - Double(start) - Double(skipped)) / Double(max(data.count, 1)))
    }

    /// For compressed recordings (no random access): a sliding window over the whole stream.
    private static func slidingSlice(of url: URL, around fraction: Double, maxBytes: Int, key: SymmetricKey?) -> (Data, Double) {
        var all = Data()
        var dropped = 0
        try? forEachChunk(of: url, key: key) { chunk in
            all.append(chunk)
            if all.count > maxBytes * 2 {
                let cut = all.count - maxBytes * 2
                all.removeSubrange(0..<cut)
                dropped += cut
            }
            return true
        }
        let total = Double(dropped + all.count)
        let center = total * min(max(fraction, 0), 1) - Double(dropped)
        let start = max(0, min(Int(center) - maxBytes / 2, all.count - maxBytes))
        let data = all.subdata(in: start..<min(start + maxBytes, all.count))
        return lineAligned(data, start: start, center: center)
    }
}
