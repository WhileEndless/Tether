import Foundation
import CryptoKit
import RecordingKit

/// Saves a whole session to a file (⌘S). Recordings are streamed chunk by chunk, so even a very
/// long session is written without holding it in memory.
public enum SessionExport {
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        /// What the terminal shows, as plain text: older output from the recording, then the
        /// scrollback and screen.
        case text
        /// The recording as it was received, with colors and control sequences (`cat` replays it).
        case raw

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .text: "Plain Text"
            case .raw: "Raw Output (with colors)"
            }
        }
        public var fileExtension: String { self == .text ? "txt" : "log" }
    }

    /// Writes plain text: the recording's lines without its last `dropLast` lines (they are still
    /// on screen and come with `lines`), then `lines`. With no recording, only `lines`.
    /// `length` stops reading the recording there (what it held when `lines` were taken).
    public static func writeText(recording: URL?, length: Int? = nil, dropLast: Int, lines: [String], to url: URL,
                                 key: SymmetricKey? = RecordingCrypto.key) throws {
        try write(to: url) { out in
            if let recording {
                // Lines are held back `dropLast` deep, so the ones also in `lines` are never written.
                var held: [String] = []
                held.reserveCapacity(min(dropLast, 100_000) + 1)
                var start = 0
                var converter = PlainTextConverter()
                func take(_ new: [String]) throws {
                    for line in new {
                        held.append(line)
                        if held.count - start > dropLast {
                            try out.write(contentsOf: Data((held[start] + "\n").utf8))
                            start += 1
                        }
                    }
                    // Keep the buffer small: drop what was written.
                    if start > 4_096 { held.removeFirst(start); start = 0 }
                }
                try forEachChunk(of: recording, length: length, key: key) { chunk in
                    try take(converter.feed(chunk))
                }
                if let last = converter.finish() { try take([last]) }
            }
            for line in lines { try out.write(contentsOf: Data((line + "\n").utf8)) }
        }
    }

    /// Writes the recording's bytes as received (decrypted and decompressed).
    public static func writeRaw(recording: URL, length: Int? = nil, to url: URL, key: SymmetricKey? = RecordingCrypto.key) throws {
        try write(to: url) { out in
            try forEachChunk(of: recording, length: length, key: key) { chunk in
                try out.write(contentsOf: chunk)
            }
        }
    }

    /// The recording's output in order, up to `length` bytes (all of it when nil).
    private static func forEachChunk(of recording: URL, length: Int?, key: SymmetricKey?, _ body: (Data) throws -> Void) throws {
        var left = length ?? Int.max
        try RecordingReader.forEachChunk(of: recording, key: key) { chunk in
            guard left > 0 else { return false }
            let part = chunk.count > left ? chunk.prefix(left) : chunk
            left -= part.count
            try body(Data(part))
            return left > 0
        }
    }

    /// Writes next to the destination first and moves it into place only when complete, so a
    /// failed save never leaves half a file under the chosen name.
    private static func write(to url: URL, _ body: (FileHandle) throws -> Void) throws {
        let fm = FileManager.default
        let partial = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8)).partial")
        guard fm.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            try body(handle)
            try handle.synchronize()
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        // The save panel already asked before an existing file is replaced.
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: partial)
        } else {
            try fm.moveItem(at: partial, to: url)
        }
    }

    /// `web-01 - deploy 2026-10-24 14.05.txt`
    public static func suggestedName(host: String, title: String, date: Date = Date(), format: Format) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm"
        var base = title == host || title.isEmpty ? host : "\(host) - \(title)"
        base = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return String(base.prefix(100)) + " " + f.string(from: date) + "." + format.fileExtension
    }
}
