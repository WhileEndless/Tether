import Foundation
import CryptoKit
import TetherCore

/// Appends everything a terminal displays to a log file so history survives the session.
public final class SessionRecorder: @unchecked Sendable {
    public let url: URL
    /// The recordings folder this recording is in (quota checks look there).
    private let directory: URL
    private let queue = DispatchQueue(label: "tether.recorder")
    private var handle: FileHandle?
    private var pending = Data()
    private var bytesSinceQuotaCheck = 0
    /// Bytes of output in the recording, its parts included (as received: before encryption).
    private var written = 0
    /// Bytes of output in the file being written (since the last part was moved aside).
    private var fileWritten = 0
    /// Number of the next part (`RecordingParts`).
    private var nextPart = 1
    /// Set when this recording is encrypted: every batch is written as one sealed frame.
    private var sealer: RecordingCrypto.Sealer?
    /// Part size for this recording (nil: the configured one, `RecordingStore.partBytes`).
    var partBytes: Int?
    /// Keys derived from the recording key, for the fresh file after a part is moved aside; nil for
    /// plain text (or sealed while locked).
    private let keys: RecordingCrypto.FileKeys?
    /// Set when the recording is sealed while Tether is locked (no recording key in memory).
    private let locked: RecordingCrypto.LockedSealing?
    private var nextFrame = 0
    private let quotaCheckInterval = 8 * 1024 * 1024

    /// Creates a new recording file for a session.
    /// - Parameters:
    ///   - key: encrypts the recording (by default when encryption is on and Tether is unlocked).
    ///   - whileLocked: seals it to the public key instead (by default when encryption is on and
    ///     Tether is locked). With encryption on and neither, nothing is recorded rather than plain text.
    public init?(targetKey: String, sessionID: UUID, directory: URL = AppPaths.recordingsDirectory,
                 key: SymmetricKey? = RecordingCrypto.writerKey, whileLocked: RecordingCrypto.LockedSealing? = nil) {
        let locked = key != nil ? nil : (whileLocked ?? (RecordingCrypto.encryptNew ? RecordingCrypto.lockedSealing : nil))
        if key == nil, locked == nil, RecordingCrypto.encryptNew { return nil }
        keys = key.map(RecordingCrypto.FileKeys.init)
        self.locked = locked
        self.directory = directory
        let folder = directory.appendingPathComponent(RecordingStore.sanitize(targetKey), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "\(formatter.string(from: Date()))_\(sessionID.uuidString.prefix(8)).\(RecordingStore.fileExtension)"
        url = folder.appendingPathComponent(name)
        guard let file = Self.newFile(keys: keys, locked: locked),
              FileManager.default.createFile(atPath: url.path, contents: file.header, attributes: [.posixPermissions: 0o600]),
              let h = try? FileHandle(forWritingTo: url) else { return nil }
        h.seekToEndOfFile()
        sealer = file.sealer
        handle = h
        RecordingStore.markActive(url)
    }

    /// Re-opens an existing recording for appending (used when a restored session reattaches).
    public init?(existing url: URL, key loaded: SymmetricKey? = RecordingCrypto.key) {
        // A plain recording continues in plain text; an encrypted one only with its own key.
        let sealer: RecordingCrypto.Sealer?
        do { sealer = try RecordingCrypto.sealer(for: url, loaded: loaded) } catch { return nil }
        keys = sealer == nil ? nil : loaded.map(RecordingCrypto.FileKeys.init)
        locked = nil
        guard let (h, frames, length) = Self.openForAppending(url, encrypted: sealer != nil) else { return nil }
        nextFrame = frames
        written = length
        self.sealer = sealer
        self.url = url
        directory = url.deletingLastPathComponent().deletingLastPathComponent()
        let parts = RecordingParts.parts(of: url)
        fileWritten = written
        written += parts.reduce(0) { $0 + $1.length }
        nextPart = (parts.last?.number ?? 0) + 1
        handle = h
        RecordingStore.markActive(url)
    }

    private var flushScheduled = false

    /// Output is kept in memory and written in large, infrequent batches — when 512 KB have
    /// accumulated or 15 s after the first unwritten byte — so a busy terminal (e.g. `tail -f`)
    /// does not cause a stream of small writes that wear the SSD. Readers that need the file to be
    /// current (search, scrolling into older history) call `flushNow()` first; closing flushes too.
    /// At most 15 s of output is only in memory, and the terminal shows it anyway.
    public static let batchBytes = 512 * 1024
    public static let batchInterval: TimeInterval = 15

    public func append(_ bytes: some Sequence<UInt8>) {
        let data = Data(bytes)
        queue.async { [self] in
            pending.append(data)
            if pending.count >= Self.batchBytes {
                flushLocked()
            } else if !flushScheduled {
                flushScheduled = true
                queue.asyncAfter(deadline: .now() + Self.batchInterval) { [self] in
                    flushScheduled = false
                    flushLocked()
                }
            }
        }
    }

    /// Writes a human readable marker line (e.g. "connection lost") into the log.
    public func mark(_ text: String) {
        append(Self.markerBytes(text))
    }

    public func flush() {
        queue.async { [self] in flushLocked() }
    }

    /// Writes everything buffered before returning (for readers of the file).
    public func flushNow() {
        queue.sync { flushLocked() }
    }

    /// Writes everything buffered and returns how many bytes of output the file holds now, so a
    /// reader can stop exactly there while the session goes on writing.
    public func flushedLength() -> Int {
        queue.sync {
            flushLocked()
            // The parts there are now (the storage limit may have removed the oldest) and the file.
            return RecordingParts.rotation.withLock { RecordingParts.parts(of: url).reduce(0) { $0 + $1.length } } + fileWritten
        }
    }

    /// Opens a recording to append to it, after its last complete frame when it is encrypted (a
    /// frame cut short by a crash or a full disk is cut off, or every later frame would be lost).
    /// Returns the handle, the number of frames and the bytes of output in the file.
    private static func openForAppending(_ url: URL, encrypted: Bool) -> (FileHandle, Int, Int)? {
        guard let h = try? FileHandle(forUpdating: url) else { return nil }
        guard encrypted else {
            let end = h.seekToEndOfFile()
            return (h, 0, Int(end))
        }
        guard let index = try? FrameIndex(handle: h) else { try? h.close(); return nil }
        let end = index.boxes.last.map { $0.offset + UInt64($0.length) + 4 } ?? index.start
        do {
            try h.truncate(atOffset: end)
            try h.seek(toOffset: end)
        } catch { try? h.close(); return nil }
        return (h, index.boxes.count, index.plainLengths.reduce(0, +))
    }

    /// Set when writing failed (a full disk): writing is tried again a while later, and the
    /// recording then says how much output is missing.
    private var failedAt: Date?
    private var lostBytes = 0
    private var closed = false

    private func flushLocked() {
        if !closed, let id = keys?.keyID ?? locked?.keyID, RecordingCrypto.isRevoked(id) { abandonLocked(); return }
        guard !pending.isEmpty else { return }
        if handle == nil, !closed, let failed = failedAt, Date().timeIntervalSince(failed) > 30 { retryLocked() }
        guard handle != nil else {
            if failedAt != nil { lostBytes += pending.count }
            pending.removeAll()
            return
        }
        do {
            try writeLocked(pending)
        } catch {
            // Disk full or similar: stop for now, leaving everything written so far readable.
            try? handle?.close()
            handle = nil
            failedAt = Date()
            lostBytes += pending.count
            pending.removeAll()
            return
        }
        bytesSinceQuotaCheck += pending.count
        pending.removeAll(keepingCapacity: true)
        let partBytes = self.partBytes ?? RecordingStore.partBytes
        if partBytes > 0, fileWritten >= partBytes { startPartLocked() }
        if bytesSinceQuotaCheck >= quotaCheckInterval {
            bytesSinceQuotaCheck = 0
            RecordingStore.requestQuotaEnforcement(in: directory)
        }
    }

    /// The recording's key was revoked: nothing can read what it holds, so it is removed and
    /// nothing more is recorded.
    private func abandonLocked() {
        pending.removeAll()
        closed = true
        try? handle?.close()
        handle = nil
        RecordingStore.markInactive(url)
        RecordingStore.delete(path: url.path)        // with its parts, on the maintenance queue
    }

    /// Opens the file again after a failed write and notes the output that could not be kept.
    private func retryLocked() {
        guard let (h, frames, length) = Self.openForAppending(url, encrypted: sealer != nil) else {
            failedAt = Date()
            return
        }
        handle = h
        nextFrame = frames
        written += length - fileWritten       // what really reached the file
        fileWritten = length
        failedAt = nil
        let note = Self.markerBytes("\(Int64(lostBytes).formatted(.byteCount(style: .file))) of output could not be recorded (the disk was full)")
        do {
            try writeLocked(note)
            lostBytes = 0
        } catch {
            // Still no space: a frame cut short must not be followed by more (openForAppending cuts it).
            try? handle?.close()
            handle = nil
            failedAt = Date()
        }
    }

    private func writeLocked(_ data: Data) throws {
        guard let handle else { return }
        if let sealer {
            guard let frame = RecordingCrypto.frame(data, sealer: sealer, index: nextFrame) else { throw RecordingCrypto.Failure.corrupt }
            try handle.write(contentsOf: frame)
            nextFrame += 1          // only once the frame is on disk, so numbering never skips
        } else {
            try handle.write(contentsOf: data)
        }
        written += data.count
        fileWritten += data.count
    }

    /// The header and sealer of a new file: encrypted with the key, sealed to the public key while
    /// locked, or plain (no header, no sealer). Nil when sealing failed (nothing is then written).
    private static func newFile(keys: RecordingCrypto.FileKeys?, locked: RecordingCrypto.LockedSealing?)
        -> (header: Data?, sealer: RecordingCrypto.Sealer?)? {
        if let keys {
            let f = RecordingCrypto.newFile(keys)
            return (f.header, f.sealer)
        }
        if let locked {
            guard let f = RecordingCrypto.newLockedFile(locked) else { return nil }
            return (f.header, f.sealer)
        }
        return (nil, nil)
    }

    private static func markerBytes(_ text: String) -> Data {
        Data("\r\n\u{1b}[2m── \(text) ──\u{1b}[0m\r\n".utf8)
    }

    /// The file has reached the part size: it becomes the next part (compressed in the background)
    /// and recording goes on in a fresh file under the same name. If anything fails on the way, the
    /// recording simply goes on in the file it was writing.
    private func startPartLocked() {
        let fm = FileManager.default
        let part = RecordingParts.url(for: url, number: nextPart, length: fileWritten)
        // The fresh file is made first, then the two renames follow each other, so the recording's
        // name is without a file only for an instant. Any failure: carry on in the current file.
        let fresh = url.appendingPathExtension("tmp")
        guard let file = Self.newFile(keys: keys, locked: locked),
              fm.createFile(atPath: fresh.path, contents: file.header, attributes: [.posixPermissions: 0o600]),
              let h = try? FileHandle(forWritingTo: fresh) else {
            try? fm.removeItem(at: fresh)
            return
        }
        RecordingParts.rotation.lock()
        defer { RecordingParts.rotation.unlock() }
        guard (try? fm.moveItem(at: url, to: part)) != nil else {    // the open handle follows the file
            try? h.close()
            try? fm.removeItem(at: fresh)
            return
        }
        guard (try? fm.moveItem(at: fresh, to: url)) != nil else {
            try? h.close()
            try? fm.removeItem(at: fresh)
            try? fm.moveItem(at: part, to: url)                       // put it back and carry on
            return
        }
        h.seekToEndOfFile()
        try? handle?.close()
        handle = h
        sealer = file.sealer
        nextFrame = 0
        fileWritten = 0
        nextPart += 1
        RecordingStore.requestQuotaEnforcement(in: directory)                             // compresses the new part
    }

    /// Throws the recording away (a terminal closed without anything done in it).
    public func discard() {
        queue.sync {
            closed = true
            pending.removeAll()
            try? handle?.close()
            handle = nil
        }
        RecordingStore.markInactive(url)
        RecordingStore.delete(path: url.path)        // with its parts, on the maintenance queue
    }

    public func close() {
        queue.sync {
            flushLocked()
            closed = true
            try? handle?.close()
            handle = nil
        }
        RecordingStore.markInactive(url)
    }

    deinit {
        try? handle?.close()
    }
}
