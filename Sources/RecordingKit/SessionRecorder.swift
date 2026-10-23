import Foundation
import CryptoKit
import TetherCore

/// Appends everything a terminal displays to a log file so history survives the session.
public final class SessionRecorder: @unchecked Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "tether.recorder")
    private var handle: FileHandle?
    private var pending = Data()
    private var bytesSinceQuotaCheck = 0
    /// Set when this recording is encrypted: every batch is written as one sealed frame.
    private let sealer: RecordingCrypto.Sealer?
    private var nextFrame = 0
    private let quotaCheckInterval = 8 * 1024 * 1024

    /// Creates a new recording file for a session.
    /// - Parameter key: encrypts the recording (by default when encryption is on and Tether is unlocked).
    public init?(targetKey: String, sessionID: UUID, directory: URL = AppPaths.recordingsDirectory,
                 key: SymmetricKey? = RecordingCrypto.writerKey) {
        // Encryption is on but Tether is locked (no key): record nothing rather than plain text.
        if key == nil, RecordingCrypto.encryptNew { return nil }
        let folder = directory.appendingPathComponent(RecordingStore.sanitize(targetKey), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "\(formatter.string(from: Date()))_\(sessionID.uuidString.prefix(8)).\(RecordingStore.fileExtension)"
        url = folder.appendingPathComponent(name)
        let file = key.map(RecordingCrypto.newFile)
        guard FileManager.default.createFile(atPath: url.path, contents: file?.header,
                                             attributes: [.posixPermissions: 0o600]),
              let h = try? FileHandle(forWritingTo: url) else { return nil }
        h.seekToEndOfFile()
        sealer = file?.sealer
        handle = h
        RecordingStore.markActive(url)
    }

    /// Re-opens an existing recording for appending (used when a restored session reattaches).
    public init?(existing url: URL) {
        // A plain recording continues in plain text; an encrypted one only with its own key.
        let sealer: RecordingCrypto.Sealer?
        do { sealer = try RecordingCrypto.sealer(for: url) } catch { return nil }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        if sealer != nil, let r = try? FileHandle(forReadingFrom: url) {
            nextFrame = (try? FrameIndex(handle: r).boxes.count) ?? 0
            try? r.close()
        }
        self.sealer = sealer
        self.url = url
        h.seekToEndOfFile()
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
        append(Array("\r\n\u{1b}[2m── \(text) ──\u{1b}[0m\r\n".utf8))
    }

    public func flush() {
        queue.async { [self] in flushLocked() }
    }

    /// Writes everything buffered before returning (for readers of the file).
    public func flushNow() {
        queue.sync { flushLocked() }
    }

    private func flushLocked() {
        guard let handle, !pending.isEmpty else { return }
        do {
            if let sealer {
                guard let frame = RecordingCrypto.frame(pending, sealer: sealer, index: nextFrame) else { throw RecordingCrypto.Failure.corrupt }
                try handle.write(contentsOf: frame)
                nextFrame += 1          // only once the frame is on disk, so numbering never skips
            } else {
                try handle.write(contentsOf: pending)
            }
        } catch {
            // Disk full or similar: stop here, leaving everything written so far readable.
            try? handle.close()
            self.handle = nil
            pending.removeAll()
            return
        }
        bytesSinceQuotaCheck += pending.count
        pending.removeAll(keepingCapacity: true)
        if bytesSinceQuotaCheck >= quotaCheckInterval {
            bytesSinceQuotaCheck = 0
            RecordingStore.requestQuotaEnforcement()
        }
    }

    /// Throws the recording away (a terminal closed without anything done in it).
    public func discard() {
        queue.sync {
            pending.removeAll()
            try? handle?.close()
            handle = nil
        }
        try? FileManager.default.removeItem(at: url)
        RecordingStore.markInactive(url)
    }

    public func close() {
        queue.sync {
            flushLocked()
            try? handle?.close()
            handle = nil
        }
        RecordingStore.markInactive(url)
    }

    deinit {
        try? handle?.close()
    }
}
