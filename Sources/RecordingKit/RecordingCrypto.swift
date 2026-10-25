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
    /// Header of a file encrypted with the recording key (`newFile`).
    public static let headerSize = 48
    /// Header of a file sealed while Tether was locked (`newLockedFile`).
    public static let lockedHeaderSize = 80
    static let magic = Data("TETHENC1".utf8)
    static let lockedMagic = Data("TETHENC2".utf8)
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
    /// Setting a key also sets `lockedSealing` (its public half), which locking keeps.
    public static var key: SymmetricKey? {
        get { lock.lock(); defer { lock.unlock() }; return _key }
        set {
            lock.lock()
            _key = newValue
            if let newValue { _lockedSealing = LockedSealing(key: newValue) }
            lock.unlock()
        }
    }

    // MARK: While locked

    /// While Tether is locked the recording key is not in memory, yet new output and command
    /// history must not be lost (or written in plain text). They are sealed to a public key
    /// (HPKE: X25519, HKDF-SHA256, ChaCha20-Poly1305) whose private half is derived from the
    /// recording key and never stored: only unlocking can open them. The public half is kept in a
    /// file so even a Tether started locked can seal.
    public struct LockedSealing: Codable, Equatable, Sendable {
        public var publicKey: Data
        /// Id of the recording key the private half comes from.
        public var keyID: Data

        public init(key: SymmetricKey) {
            publicKey = RecordingCrypto.privateKey(for: key).publicKey.rawRepresentation
            keyID = RecordingCrypto.keyID(key)
        }

        var recipient: Curve25519.KeyAgreement.PublicKey? { try? .init(rawRepresentation: publicKey) }
    }

    nonisolated(unsafe) private static var _lockedSealing: LockedSealing?

    nonisolated(unsafe) private static var _sealingLoader: (@Sendable () -> Data?)?
    nonisolated(unsafe) private static var _lastSealingRead = Date.distantPast

    /// Where the public half is stored (the app's keychain), read the first time something must be
    /// sealed while locked, so a launch never reads the keychain for it.
    public static var lockedSealingLoader: (@Sendable () -> Data?)? {
        get { lock.lock(); defer { lock.unlock() }; return _sealingLoader }
        set { lock.lock(); _sealingLoader = newValue; lock.unlock() }
    }

    /// What new files are sealed to while locked (nil: encryption was never set up, or was reset).
    public static var lockedSealing: LockedSealing? {
        get {
            lock.lock()
            if let s = _lockedSealing { lock.unlock(); return s }
            // Read when first needed; when that finds nothing (or the keychain said no), again
            // a minute later at the earliest, so a locked Tether never asks over and over.
            guard let loader = _sealingLoader, Date().timeIntervalSince(_lastSealingRead) > 60 else { lock.unlock(); return nil }
            _lastSealingRead = Date()
            lock.unlock()
            guard let data = loader(), let s = try? JSONDecoder().decode(LockedSealing.self, from: data), s.recipient != nil else { return nil }
            lock.lock()
            if _lockedSealing == nil { _lockedSealing = s }
            defer { lock.unlock() }
            return _lockedSealing
        }
        set { lock.lock(); _lockedSealing = newValue; _sealingLoader = nil; lock.unlock() }
    }

    /// The public half as the app stores it (without loading it).
    public static var encodedLockedSealing: Data? {
        lock.lock(); defer { lock.unlock() }
        return _lockedSealing.flatMap { try? JSONEncoder().encode($0) }
    }

    static let hpkeSuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    static let hpkeInfo = Data("tether-locked-v1".utf8)

    static func privateKey(for key: SymmetricKey) -> Curve25519.KeyAgreement.PrivateKey {
        let raw = subkey(key, "locked").withUnsafeBytes { Data($0) }
        return try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)   // any 32 bytes are a valid key
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
        init(framesKey: SymmetricKey, fileID: Data) {
            key = framesKey
            self.fileID = fileID
        }
    }

    /// What a recorder keeps to start new files (parts) with: the key's id and the two keys derived
    /// from it, never the recording key itself (which also opens history and the locked files).
    struct FileKeys: Sendable {
        let keyID: Data
        let header: SymmetricKey
        let frames: SymmetricKey
        init(_ key: SymmetricKey) {
            keyID = RecordingCrypto.keyID(key)
            header = RecordingCrypto.subkey(key, "header")
            frames = RecordingCrypto.subkey(key, "frames")
        }
    }

    // MARK: Revoked keys

    nonisolated(unsafe) private static var revoked = Set<Data>()

    /// The key with this id is gone for good (the Tether password was reset): recordings still
    /// being written with it stop and remove themselves, as nothing could ever read them.
    public static func revoke(keyID: Data) { lock.lock(); revoked.insert(keyID); lock.unlock() }

    static func isRevoked(_ keyID: Data) -> Bool { lock.lock(); defer { lock.unlock() }; return revoked.contains(keyID) }

    static func subkey(_ key: SymmetricKey, _ purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data("tether-recording-v1-\(purpose)".utf8), outputByteCount: 32)
    }

    /// A header for a new encrypted file, and the sealer for its frames.
    static func newFile(_ key: SymmetricKey) -> (header: Data, sealer: Sealer) { newFile(FileKeys(key)) }

    static func newFile(_ keys: FileKeys) -> (header: Data, sealer: Sealer) {
        let fileID = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let body = magic + keys.keyID + fileID
        let tag = Data(HMAC<SHA256>.authenticationCode(for: body, using: keys.header).prefix(16))
        return (body + tag, Sealer(framesKey: keys.frames, fileID: fileID))
    }

    /// A header for a new file sealed while locked, and the sealer for its frames:
    ///
    ///     "TETHENC2" · key id (8) · file id (16) · HPKE encapsulated key (32) · tag (16)
    ///
    /// The frame key and the header tag's key are HPKE exports: only the recording key (through its
    /// derived private key) opens the file. The tag shows the header was made for this public key
    /// (so output that merely starts like a header never passes for an encrypted file); it is not
    /// a signature, as anyone holding the public key could make such a file.
    static func newLockedFile(_ sealing: LockedSealing) -> (header: Data, sealer: Sealer)? {
        guard let recipient = sealing.recipient,
              let sender = try? HPKE.Sender(recipientKey: recipient, ciphersuite: hpkeSuite, info: hpkeInfo),
              let frames = try? sender.exportSecret(context: Data("frames".utf8), outputByteCount: 32),
              let headerKey = try? sender.exportSecret(context: Data("header".utf8), outputByteCount: 32) else { return nil }
        let fileID = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let body = lockedMagic + sealing.keyID + fileID + sender.encapsulatedKey
        let tag = Data(HMAC<SHA256>.authenticationCode(for: body, using: headerKey).prefix(16))
        return (body + tag, Sealer(key: frames, fileID: fileID))
    }

    private struct Header {
        var keyID: Data
        var fileID: Data
        var tag: Data
        var body: Data
        /// Set for files sealed while locked.
        var encapsulatedKey: Data?
        var size: Int { encapsulatedKey == nil ? headerSize : lockedHeaderSize }
    }

    private static func header(of url: URL) -> Header? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: lockedHeaderSize), head.count >= headerSize else { return nil }
        let d = Data(head)
        if d.prefix(8) == magic {
            return Header(keyID: d.subdata(in: 8..<16), fileID: d.subdata(in: 16..<32), tag: d.subdata(in: 32..<48), body: d.prefix(32))
        }
        guard d.prefix(8) == lockedMagic, d.count == lockedHeaderSize else { return nil }
        return Header(keyID: d.subdata(in: 8..<16), fileID: d.subdata(in: 16..<32), tag: d.subdata(in: 64..<80),
                      body: d.prefix(64), encapsulatedKey: d.subdata(in: 32..<64))
    }

    /// Whether an encrypted-looking file is made of whole frames up to its end (a frame cut short
    /// by a crash at the end is allowed). Checks the structure only; without the key nothing more
    /// can be known.
    static func isWellFormed(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let index = try? FrameIndex(handle: h), let size = try? h.seekToEnd() else { return false }
        let end = index.boxes.last.map { $0.offset + UInt64($0.length) + 4 } ?? index.start
        return size - end < 8 + UInt64(fileFrameBytes) && (index.boxes.count > 0 || size <= index.start + 8)
    }

    /// Bytes before the first frame of an encrypted file (0 for a plain one).
    static func headerLength(of handle: FileHandle) -> Int {
        guard (try? handle.seek(toOffset: 0)) != nil, let head = try? handle.read(upToCount: 8) else { return 0 }
        if Data(head) == lockedMagic { return lockedHeaderSize }
        return Data(head) == magic ? headerSize : 0
    }

    /// The frame key and header check of a file sealed while locked, opened with the recording key.
    private static func lockedKeys(_ h: Header, key: SymmetricKey) -> (frames: SymmetricKey, tagOK: Bool)? {
        guard let encapsulated = h.encapsulatedKey,
              let recipient = try? HPKE.Recipient(privateKey: privateKey(for: key), ciphersuite: hpkeSuite, info: hpkeInfo,
                                                  encapsulatedKey: encapsulated),
              let frames = try? recipient.exportSecret(context: Data("frames".utf8), outputByteCount: 32),
              let headerKey = try? recipient.exportSecret(context: Data("header".utf8), outputByteCount: 32) else { return nil }
        let signed = HMAC<SHA256>.authenticationCode(for: h.body, using: headerKey)
        return (frames, constantTimeEqual(Data(signed.prefix(16)), h.tag))
    }

    private static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    /// The key id in an encrypted recording's header, or nil for a plain one.
    public static func keyID(of url: URL) -> Data? { header(of: url)?.keyID }

    /// Looks encrypted (without a key this cannot be confirmed).
    public static func isEncrypted(_ url: URL) -> Bool { header(of: url) != nil }

    /// Really encrypted with `key`: its header is signed with it.
    public static func isEncrypted(_ url: URL, with key: SymmetricKey) -> Bool {
        guard let h = header(of: url), h.keyID == keyID(key) else { return false }
        if h.encapsulatedKey != nil { return lockedKeys(h, key: key)?.tagOK == true }
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
        if h.encapsulatedKey != nil {
            guard let opened = lockedKeys(h, key: key), opened.tagOK else { throw Failure.corrupt }
            return Sealer(key: opened.frames, fileID: h.fileID)
        }
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
    /// Where the first frame starts (after the header).
    private(set) var start = UInt64(RecordingCrypto.headerSize)

    init(handle: FileHandle) throws {
        start = UInt64(max(RecordingCrypto.headerLength(of: handle), RecordingCrypto.headerSize))
        let size = try handle.seekToEnd()
        var pos = start
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

/// Every way of reading a recording, for plain, encrypted and compressed files alike, and for
/// recordings kept in parts (`RecordingParts`): the parts and the file read as one recording.
public enum RecordingReader {
    /// Successive chunks of the recording's text (decrypted and decompressed). Return false to stop.
    public static func forEachChunk(of url: URL, key: SymmetricKey? = RecordingCrypto.key,
                                    _ body: (Data) throws -> Bool) throws {
        // The parts and the file being written are taken at one moment: no new part can start in
        // between (`RecordingParts.rotation`). The open file keeps its contents even when it is
        // moved aside as a part later, so nothing is skipped or read twice.
        let (parts, main) = try RecordingParts.rotation.withLock {
            (RecordingParts.parts(of: url), try RawCursor(url: url, key: key))
        }
        var stopped = false
        for part in parts where !stopped {
            do {
                try forEachChunk(ofFile: RecordingParts.current(part.url), key: key) { chunk in
                    if try !body(chunk) { stopped = true; return false }
                    return true
                }
            } catch CocoaError.fileReadNoSuchFile {
                continue      // removed meanwhile (the storage limit shortened this session)
            }
        }
        if !stopped { try forEachChunk(ofFile: url, cursor: main, body) }
    }

    /// One file's chunks (a recording without parts, or one part).
    static func forEachChunk(ofFile url: URL, key: SymmetricKey?, _ body: (Data) throws -> Bool) throws {
        try forEachChunk(ofFile: url, cursor: RawCursor(url: url, key: key), body)
    }

    private static func forEachChunk(ofFile url: URL, cursor: RawCursor, _ body: (Data) throws -> Bool) throws {
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

    /// The most `tail` reads: output with few line breaks (full-screen programs, progress bars)
    /// must never bring gigabytes into memory for a few thousand lines.
    public static let tailMaxBytes = 16 * 1024 * 1024

    /// The last `lines` lines of a recording (at most `tailMaxBytes`), starting at a line boundary.
    /// Reads only the end of the file (backwards) unless it is compressed, and only as many parts as
    /// those lines need.
    public static func tail(of url: URL, lines: Int, key loaded: SymmetricKey? = RecordingCrypto.key) -> [UInt8]? {
        // No new part starts while the end is read (quick: at most `tailMaxBytes`).
        RecordingParts.rotation.withLock { tailOfParts(url, lines: lines, key: loaded) }
    }

    private static func tailOfParts(_ url: URL, lines: Int, key loaded: SymmetricKey?) -> [UInt8]? {
        let last = tail(ofFile: url, lines: lines, key: loaded)
        var parts = RecordingParts.parts(of: url)
        guard !parts.isEmpty else { return last }
        var collected = Data(last ?? [])
        var newlines = collected.reduce(0) { $0 + ($1 == 0x0a ? 1 : 0) }
        while newlines <= lines, collected.count < tailMaxBytes, let part = parts.popLast() {
            guard let earlier = wholePart(part, key: loaded) else { break }
            newlines += earlier.reduce(0) { $0 + ($1 == 0x0a ? 1 : 0) }
            collected = earlier + collected
        }
        return Array(cutToLastLines(capped(collected), lines))
    }

    /// The last `tailMaxBytes` of `data`, from a line start when there is one.
    private static func capped(_ data: Data) -> Data {
        guard data.count > tailMaxBytes else { return data }
        let cut = data.suffix(tailMaxBytes)
        if let nl = cut.firstIndex(of: 0x0a), nl + 1 < cut.endIndex { return Data(cut[(nl + 1)...]) }
        return Data(cut)
    }

    /// The output of one part, kept for a while: scrolling back loads a few thousand lines at a
    /// time, and the same part would otherwise be decompressed again for each of them.
    private static func wholePart(_ part: RecordingParts.Part, key: SymmetricKey?) -> Data? {
        let url = RecordingParts.current(part.url)
        partCache.lock.lock()
        if let hit = partCache.entry, hit.path == url.path { partCache.lock.unlock(); return hit.data }
        partCache.lock.unlock()
        var data = Data(capacity: part.length)
        do { try forEachChunk(ofFile: url, key: key) { data.append($0); return true } } catch { return nil }
        partCache.lock.lock()
        partCache.entry = (url.path, data)
        partCache.lock.unlock()
        // Released after a minute so a large part never stays in memory for nothing.
        let path = url.path
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) {
            partCache.lock.lock()
            if partCache.entry?.path == path { partCache.entry = nil }
            partCache.lock.unlock()
        }
        return data
    }

    private final class PartCache: @unchecked Sendable {
        let lock = NSLock()
        var entry: (path: String, data: Data)?
    }
    private static let partCache = PartCache()

    static func tail(ofFile url: URL, lines: Int, key loaded: SymmetricKey?) -> [UInt8]? {
        if RecordingCompression.isCompressed(url) {
            let data = slice(ofFile: url, around: 1, maxBytes: tailMaxBytes, key: loaded).0
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
            if newlines > lines || collected.count >= tailMaxBytes { break }
        }
        return Array(cutToLastLines(capped(collected), lines))
    }

    private static func plainTail(handle: FileHandle, lines: Int) -> [UInt8]? {
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let block: UInt64 = 1 << 20
        var offset = size
        var newlines = 0
        var start: UInt64 = 0
        outer: while offset > 0 {
            if size - offset >= UInt64(tailMaxBytes) {     // enough: start at the next line from here
                start = offset
                try? handle.seek(toOffset: offset)
                if let rest = try? handle.read(upToCount: 1 << 20), let nl = rest.firstIndex(of: 0x0a) {
                    start = offset + UInt64(nl - rest.startIndex) + 1
                }
                break
            }
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
    /// where `fraction` lies within the returned data. In a recording kept in parts only the part
    /// holding that position is read; the parts' names say how long each one is.
    public static func slice(of url: URL, around fraction: Double, maxBytes: Int = 16 * 1024 * 1024,
                             key loaded: SymmetricKey? = RecordingCrypto.key) -> (Data, Double) {
        RecordingParts.rotation.withLock { sliceOfParts(url, around: fraction, maxBytes: maxBytes, key: loaded) }
    }

    private static func sliceOfParts(_ url: URL, around fraction: Double, maxBytes: Int, key loaded: SymmetricKey?) -> (Data, Double) {
        let parts = RecordingParts.parts(of: url)
        guard !parts.isEmpty else { return slice(ofFile: url, around: fraction, maxBytes: maxBytes, key: loaded) }
        let lengths = parts.map(\.length) + [length(ofFile: url, key: loaded)]
        let files = parts.map { RecordingParts.current($0.url) } + [url]
        let total = lengths.reduce(0, +)
        var target = Double(total) * min(max(fraction, 0), 1)
        for (i, len) in lengths.enumerated() {
            if target <= Double(len) || i == lengths.count - 1 {
                return slice(ofFile: files[i], around: len > 0 ? min(target / Double(len), 1) : 1, maxBytes: maxBytes, key: loaded,
                             length: i < parts.count ? len : nil)
            }
            target -= Double(len)
        }
        return (Data(), 0)
    }

    /// Bytes of output in one file (reads through it only when it is compressed).
    static func length(ofFile url: URL, key: SymmetricKey?) -> Int {
        if RecordingCompression.isCompressed(url) {
            var n = 0
            try? forEachChunk(ofFile: url, key: key) { n += $0.count; return true }
            return n
        }
        guard let h = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? h.close() }
        if (try? RecordingCrypto.sealer(for: url, loaded: key)) != nil {
            return (try? FrameIndex(handle: h))?.plainLengths.reduce(0, +) ?? 0
        }
        return Int((try? h.seekToEnd()) ?? 0)
    }

    static func slice(ofFile url: URL, around fraction: Double, maxBytes: Int, key loaded: SymmetricKey?,
                      length: Int? = nil) -> (Data, Double) {
        if RecordingCompression.isCompressed(url) { return slidingSlice(of: url, around: fraction, maxBytes: maxBytes, key: loaded, length: length) }
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

    /// For compressed recordings (no random access): the window is cut out of the stream as it
    /// goes by, so at most `maxBytes` are held, and reading stops after it. The length (from a
    /// part's name, or one counting pass) says where the window lies.
    private static func slidingSlice(of url: URL, around fraction: Double, maxBytes: Int, key: SymmetricKey?,
                                     length: Int? = nil) -> (Data, Double) {
        let total = length ?? self.length(ofFile: url, key: key)
        let center = Double(total) * min(max(fraction, 0), 1)
        let start = max(0, min(Int(center) - maxBytes / 2, total - maxBytes))
        let end = min(total, start + maxBytes)
        var data = Data()
        var pos = 0
        try? forEachChunk(ofFile: url, key: key) { chunk in
            defer { pos += chunk.count }
            let lo = max(start - pos, 0), hi = min(end - pos, chunk.count)
            if lo < hi { data += chunk.subdata(in: (chunk.startIndex + lo)..<(chunk.startIndex + hi)) }
            return pos + chunk.count < end
        }
        return lineAligned(data, start: start, center: center)
    }
}
