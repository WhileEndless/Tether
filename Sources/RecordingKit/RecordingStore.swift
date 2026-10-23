import Foundation
import TetherCore

public struct RecordingInfo: Identifiable, Hashable, Sendable {
    public var url: URL
    public var isCompressed: Bool { RecordingCompression.isCompressed(url) }
    public var targetKey: String
    public var size: Int64
    public var modified: Date
    public var isActive: Bool
    public var id: URL { url }
}

/// Lists recordings and keeps their total size under the configured quota.
public enum RecordingStore {
    public static let fileExtension = "ttylog"

    nonisolated(unsafe) private static var active = Set<String>()
    nonisolated(unsafe) private static var quotaBytes: Int64 = 1024 * 1024 * 1024
    nonisolated(unsafe) private static var retentionDays = 0
    nonisolated(unsafe) private static var compressAfterDays = 7
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "tether.recording-quota", qos: .utility)

    public static func sanitize(_ key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.@"))
        let s = key.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return s.isEmpty ? "unknown" : s
    }

    static func markActive(_ url: URL) { lock.lock(); active.insert(url.path); lock.unlock() }
    static func markInactive(_ url: URL) { lock.lock(); active.remove(url.path); lock.unlock() }

    public static func configure(quotaMB: Int, retentionDays days: Int, compressAfterDays compressDays: Int = 7) {
        lock.lock()
        quotaBytes = Int64(max(quotaMB, 16)) * 1024 * 1024
        retentionDays = max(days, 0)
        compressAfterDays = max(compressDays, 0)
        lock.unlock()
        requestQuotaEnforcement()
    }

    /// The file currently holding a recording: compression renames `x.ttylog` to `x.ttylog.lzfse`.
    public static func resolve(_ path: String) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        let compressed = path + "." + RecordingCompression.compressedExtension
        return fm.fileExists(atPath: compressed) ? URL(fileURLWithPath: compressed) : nil
    }

    /// Compresses inactive recordings older than the configured number of days.
    @discardableResult
    public static func compressOld(in directory: URL = AppPaths.recordingsDirectory, now: Date = Date(),
                                   olderThanDays: Int? = nil) -> Int {
        lock.lock(); let days = olderThanDays ?? compressAfterDays; lock.unlock()
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var count = 0
        for item in all(in: directory) where !item.isActive && !item.isCompressed && item.modified < cutoff {
            if (try? RecordingCompression.compress(item.url)) != nil { count += 1 }
        }
        return count
    }

    public static func requestQuotaEnforcement() {
        queue.async { enforceQuota() }
    }

    public static func all(in directory: URL = AppPaths.recordingsDirectory) -> [RecordingInfo] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return [] }
        lock.lock(); let activeNow = active; lock.unlock()
        var list: [RecordingInfo] = []
        for case let url as URL in e where url.pathExtension == fileExtension
            || (url.pathExtension == RecordingCompression.compressedExtension && url.deletingPathExtension().pathExtension == fileExtension) {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            list.append(RecordingInfo(url: url, targetKey: url.deletingLastPathComponent().lastPathComponent,
                                      size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate ?? .distantPast,
                                      isActive: activeNow.contains(url.path)))
        }
        return list.sorted { $0.modified > $1.modified }
    }

    public static func totalSize(in directory: URL = AppPaths.recordingsDirectory) -> Int64 {
        all(in: directory).reduce(0) { $0 + $1.size }
    }

    /// Deletes the oldest inactive recordings until the total fits the quota,
    /// and anything older than the retention period.
    @discardableResult
    public static func enforceQuota(in directory: URL = AppPaths.recordingsDirectory,
                                    quota: Int64? = nil, now: Date = Date()) -> [URL] {
        lock.lock()
        let limit = quota ?? quotaBytes
        let days = retentionDays
        lock.unlock()
        // Compress first: it frees most of the space without losing anything.
        if quota == nil { compressOld(in: directory, now: now) }
        let fm = FileManager.default
        var items = all(in: directory).sorted { $0.modified < $1.modified } // oldest first
        var removed: [URL] = []
        if days > 0 {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            for item in items where !item.isActive && item.modified < cutoff {
                if (try? fm.removeItem(at: item.url)) != nil { removed.append(item.url) }
            }
            items.removeAll { removed.contains($0.url) }
        }
        var total = items.reduce(0) { $0 + $1.size }
        for item in items where total > limit && !item.isActive {
            if (try? fm.removeItem(at: item.url)) != nil {
                total -= item.size
                removed.append(item.url)
            }
        }
        // Remove now-empty host folders.
        if let folders = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for f in folders where (try? fm.contentsOfDirectory(atPath: f.path))?.isEmpty == true {
                try? fm.removeItem(at: f)
            }
        }
        return removed
    }

    public static func deleteAll(in directory: URL = AppPaths.recordingsDirectory) {
        for item in all(in: directory) where !item.isActive {
            try? FileManager.default.removeItem(at: item.url)
        }
    }

    /// Reads up to `maxBytes` of a recording centred on `fraction` (0…1) of the file.
    /// Returns the data and where the requested position lies within it (0…1).
    public static func slice(of url: URL, around fraction: Double, maxBytes: Int = 16 * 1024 * 1024) -> (Data, Double) {
        if RecordingCompression.isCompressed(url) { return RecordingCompression.slice(of: url, around: fraction, maxBytes: maxBytes) }
        guard let h = try? FileHandle(forReadingFrom: url) else { return (Data(), 0) }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        guard size > UInt64(maxBytes) else {
            try? h.seek(toOffset: 0)
            return ((try? h.readToEnd()) ?? Data(), fraction)
        }
        let center = Double(size) * min(max(fraction, 0), 1)
        let start = UInt64(max(0, min(center - Double(maxBytes) / 2, Double(size) - Double(maxBytes))))
        try? h.seek(toOffset: start)
        var data = (try? h.read(upToCount: maxBytes)) ?? Data()
        // Start at a line boundary so the replay does not begin inside an escape sequence.
        var skipped = 0
        if start > 0, let nl = data.firstIndex(of: 0x0a) {
            skipped = nl + 1 - data.startIndex
            data = data.subdata(in: (nl + 1)..<data.endIndex)
        }
        return (data, (center - Double(start) - Double(skipped)) / Double(max(data.count, 1)))
    }

    /// Reads the tail of a recording (bounded so huge logs stay responsive).
    public static func tail(of url: URL, maxBytes: Int = 16 * 1024 * 1024) -> Data {
        if RecordingCompression.isCompressed(url) { return RecordingCompression.slice(of: url, around: 1, maxBytes: maxBytes).0 }
        guard let h = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        return (try? h.readToEnd()) ?? Data()
    }
}
