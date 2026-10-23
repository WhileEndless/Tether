import Foundation
import Compression

/// Compresses old recordings with LZFSE (fast, typically 5–10× smaller for terminal output) and
/// reads them back in chunks, so even very large transcripts never have to be held in memory.
public enum RecordingCompression {
    public static let compressedExtension = "lzfse"

    public static func isCompressed(_ url: URL) -> Bool { url.pathExtension == compressedExtension }

    /// Compresses `url` into `url.lzfse`, keeps its modification date, then removes the original.
    @discardableResult
    public static func compress(_ url: URL) throws -> URL {
        let out = url.appendingPathExtension(compressedExtension)
        let tmp = out.appendingPathExtension("tmp")
        let fm = FileManager.default
        fm.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let input = try? FileHandle(forReadingFrom: url), let output = try? FileHandle(forWritingTo: tmp) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { try? input.close(); try? output.close() }
        let filter = try OutputFilter(.compress, using: .lzfse) { data in
            if let data { try output.write(contentsOf: data) }
        }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try filter.write(chunk)
        }
        try filter.finalize()
        try output.close()
        let date = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        try fm.moveItem(at: tmp, to: out)
        if let date { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: out.path) }
        try fm.removeItem(at: url)
        return out
    }

    /// Calls `body` with successive chunks of the (decompressed) recording. Return false to stop.
    public static func forEachChunk(of url: URL, _ body: (Data) throws -> Bool) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        if !isCompressed(url) {
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                if try !body(chunk) { return }
            }
            return
        }
        let filter = try InputFilter(.decompress, using: .lzfse) { length in
            try handle.read(upToCount: length)
        }
        while let chunk = try filter.readData(ofLength: 4 << 20), !chunk.isEmpty {
            if try !body(chunk) { return }
        }
    }

    /// The decompressed contents, keeping at most `maxBytes` around `fraction` (0…1) of the file.
    /// Returns the data and the position of `fraction` inside it.
    public static func slice(of url: URL, around fraction: Double, maxBytes: Int) -> (Data, Double) {
        var all = Data()
        var dropped = 0
        // Without knowing the decompressed size up front, keep a sliding window of 2×maxBytes.
        try? forEachChunk(of: url) { chunk in
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
        var data = all.subdata(in: start..<min(start + maxBytes, all.count))
        var skipped = 0
        if start > 0, let nl = data.firstIndex(of: 0x0a) {
            skipped = nl + 1 - data.startIndex
            data = data.subdata(in: (nl + 1)..<data.endIndex)
        }
        return (data, (center - Double(start) - Double(skipped)) / Double(max(data.count, 1)))
    }
}
