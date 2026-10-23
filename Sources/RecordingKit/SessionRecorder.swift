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

    /// Buffers output and writes it in batches: when 64 KB have accumulated, or at most a second
    /// later, so the file stays current (for search and crash safety) without a write per chunk.
    public func append(_ bytes: some Sequence<UInt8>) {
        let data = Data(bytes)
        queue.async { [self] in
            pending.append(data)
            if pending.count >= 64 * 1024 {
                flushLocked()
            } else if !flushScheduled {
                flushScheduled = true
                queue.asyncAfter(deadline: .now() + 1) { [self] in
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
