import Foundation
import TetherCore

/// Appends everything a terminal displays to a log file so history survives the session.
public final class SessionRecorder: @unchecked Sendable {
    public let url: URL
    private let queue = DispatchQueue(label: "tether.recorder")
    private var handle: FileHandle?
    private var pending = Data()
    private var bytesSinceQuotaCheck = 0
    private let quotaCheckInterval = 8 * 1024 * 1024

    /// Creates a new recording file for a session.
    public init?(targetKey: String, sessionID: UUID, directory: URL = AppPaths.recordingsDirectory) {
        let folder = directory.appendingPathComponent(RecordingStore.sanitize(targetKey), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "\(formatter.string(from: Date()))_\(sessionID.uuidString.prefix(8)).\(RecordingStore.fileExtension)"
        url = folder.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h
        RecordingStore.markActive(url)
    }

    /// Re-opens an existing recording for appending (used when a restored session reattaches).
    public init?(existing url: URL) {
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
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
        try? handle.write(contentsOf: pending)
        bytesSinceQuotaCheck += pending.count
        pending.removeAll(keepingCapacity: true)
        if bytesSinceQuotaCheck >= quotaCheckInterval {
            bytesSinceQuotaCheck = 0
            RecordingStore.requestQuotaEnforcement()
        }
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
