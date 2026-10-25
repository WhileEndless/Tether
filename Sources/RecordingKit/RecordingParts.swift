import Foundation

/// A busy session's recording is kept in parts: once the file being written passes the part size,
/// it is moved aside as the next part and compressed in the background, and recording goes on in a
/// fresh file under the same name. Very long sessions (gigabytes of output) then take a fraction of
/// the space, and the end of the session — what scrolling back reads — stays uncompressed.
///
///     2026-10-25_10-00-00_ab12cd34.ttylog                         the file being written (or .lzfse)
///     2026-10-25_10-00-00_ab12cd34.ttylog.part-000001-16777216.lzfse   earlier output, in order
///
/// A part's name holds its number and how many bytes of output it holds, so readers can find a
/// position without decompressing anything. Parts are plain, compressed or encrypted like any
/// recording, and every reader (`RecordingReader`) treats the parts and the file as one recording.
public enum RecordingParts {
    static let marker = ".part-"

    /// Held while a recording starts a new part, and while readers take the list of parts with
    /// the file being written (so they never see one without the other).
    static let rotation = NSLock()

    public struct Part: Sendable {
        public var url: URL
        public var number: Int
        /// Bytes of output it holds (decrypted, decompressed).
        public var length: Int
    }

    /// The name parts of `url` start with: the recording's file name without ".lzfse".
    static func baseName(of url: URL) -> String {
        RecordingCompression.isCompressed(url) ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }

    /// Whether `url` is a part of some recording (not a recording of its own).
    static func isPart(_ url: URL) -> Bool {
        url.lastPathComponent.contains(".\(RecordingStore.fileExtension)\(marker)")
    }

    /// The recording file a part belongs to, without ".lzfse" (it may be compressed).
    static func owner(of part: URL) -> String? {
        let name = part.lastPathComponent
        guard let r = name.range(of: marker) else { return nil }
        return part.deletingLastPathComponent().appendingPathComponent(String(name[..<r.lowerBound])).path
    }

    static func parse(_ url: URL, base: String) -> Part? {
        var name = url.lastPathComponent
        guard name.hasPrefix(base + marker) else { return nil }
        if name.hasSuffix(".tmp") { return nil }
        if RecordingCompression.isCompressed(url) { name = url.deletingPathExtension().lastPathComponent }
        let fields = name.dropFirst(base.count + marker.count).split(separator: "-")
        guard fields.count == 2, let n = Int(fields[0]), let len = Int(fields[1]) else { return nil }
        return Part(url: url, number: n, length: len)
    }

    /// The parts of the recording at `url`, oldest first.
    public static func parts(of url: URL) -> [Part] {
        let base = baseName(of: url)
        let folder = url.deletingLastPathComponent()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        // While a part is being compressed, its compressed copy is in place for an instant before the
        // original goes: both hold the same output, so each number is listed once (compressed first).
        var byNumber: [Int: Part] = [:]
        for part in names.filter({ $0.hasPrefix(base + marker) }).compactMap({ parse(folder.appendingPathComponent($0), base: base) }) {
            if let seen = byNumber[part.number], RecordingCompression.isCompressed(seen.url) { continue }
            byNumber[part.number] = part
        }
        return byNumber.values.sorted { $0.number < $1.number }
    }

    /// The name of part `number` holding `length` bytes, next to `url` (uncompressed).
    static func url(for url: URL, number: Int, length: Int) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(baseName(of: url) + marker + String(format: "%06d", number) + "-\(length)")
    }

    /// Where a part is now: compression renames `x` to `x.lzfse` while a reader may be about to open it.
    static func current(_ part: URL) -> URL {
        RecordingStore.resolve(part.path) ?? part
    }

    /// Compresses every part not compressed yet (parts are never written to again).
    @discardableResult
    static func compressAll(in directory: URL) -> Int {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        var count = 0
        for case let url as URL in e where isPart(url) && !RecordingCompression.isCompressed(url) && url.pathExtension != "tmp" {
            if (try? RecordingCompression.compress(url)) != nil { count += 1 }
        }
        return count
    }
}
