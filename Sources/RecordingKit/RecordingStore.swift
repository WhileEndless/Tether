import Foundation
import CryptoKit
import TetherCore

public struct RecordingInfo: Identifiable, Hashable, Sendable {
    public var url: URL
    public var isCompressed: Bool { RecordingCompression.isCompressed(url) }
    public var targetKey: String
    public var size: Int64
    public var modified: Date
    public var isActive: Bool
    /// Earlier output of a long session, moved aside and compressed while it ran (`RecordingParts`).
    public var parts: [URL] = []
    /// The recording's files: its parts, then the file itself.
    public var files: [URL] { parts + [url] }
    public var id: URL { url }
}

/// Lists recordings and keeps their total size under the configured quota.
public enum RecordingStore {
    public static let fileExtension = "ttylog"

    nonisolated(unsafe) private static var active = Set<String>()
    nonisolated(unsafe) private static var quotaBytes: Int64 = 1024 * 1024 * 1024
    nonisolated(unsafe) private static var retentionDays = 0
    nonisolated(unsafe) private static var compressAfterDays = 7
    nonisolated(unsafe) private static var _partBytes = 16 * 1024 * 1024
    nonisolated(unsafe) private static var shortenLargest = true
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "tether.recording-quota", qos: .utility)

    public static func sanitize(_ key: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.@"))
        let s = key.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        return s.isEmpty ? "unknown" : s
    }

    static func markActive(_ url: URL) { lock.lock(); active.insert(url.path); lock.unlock() }
    static func markInactive(_ url: URL) { lock.lock(); active.remove(url.path); lock.unlock() }

    /// - Parameters:
    ///   - partMB: a recording still being written moves its output aside as a compressed part
    ///     every this many MB (0 = never: it is compressed only after the session, as configured).
    ///   - shortenLargestFirst: when space runs out, a recording that holds more than half of it
    ///     loses its oldest parts before any other recording is removed.
    public static func configure(quotaMB: Int, retentionDays days: Int, compressAfterDays compressDays: Int = 7,
                                 partMB: Int = 16, shortenLargestFirst: Bool = true) {
        lock.lock()
        quotaBytes = Int64(max(quotaMB, 16)) * 1024 * 1024
        retentionDays = max(days, 0)
        compressAfterDays = max(compressDays, 0)
        _partBytes = max(partMB, 0) * 1024 * 1024
        shortenLargest = shortenLargestFirst
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
        // Parts are never written to again: they are compressed right away, whatever their age.
        var count = RecordingParts.compressAll(in: directory)
        guard days > 0 else { return count }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        for item in all(in: directory) where !item.isActive && !item.isCompressed && item.modified < cutoff {
            if (try? RecordingCompression.compress(item.url)) != nil { count += 1 }
        }
        return count
    }

    /// Bytes of output after which a recording being written starts a new part (0 = never).
    static var partBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return _partBytes
    }

    public static func requestQuotaEnforcement(in directory: URL = AppPaths.recordingsDirectory) {
        queue.async { enforceQuota(in: directory) }
    }

    /// Runs `work` on the maintenance queue, after (and never at the same time as) quota checks,
    /// compression and other passes, so two of them never rewrite the same recording at once.
    public static func perform<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Waits until queued maintenance (quota, compression of parts) has run.
    static func waitForMaintenance() { queue.sync {} }

    public static func all(in directory: URL = AppPaths.recordingsDirectory) -> [RecordingInfo] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return [] }
        lock.lock(); let activeNow = active; lock.unlock()
        var list: [RecordingInfo] = []
        var parts: [String: [(url: URL, size: Int64)]] = [:]
        for case let url as URL in e {
            if RecordingParts.isPart(url) {
                guard url.pathExtension != "tmp", let owner = RecordingParts.owner(of: url) else { continue }
                parts[owner, default: []].append((url, Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)))
                continue
            }
            guard url.pathExtension == fileExtension
                || (url.pathExtension == RecordingCompression.compressedExtension && url.deletingPathExtension().pathExtension == fileExtension) else { continue }
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            list.append(RecordingInfo(url: url, targetKey: url.deletingLastPathComponent().lastPathComponent,
                                      size: Int64(v?.fileSize ?? 0), modified: v?.contentModificationDate ?? .distantPast,
                                      isActive: activeNow.contains(url.path)))
        }
        // A recording's parts count as the recording (listed, sized and removed with it). Parts
        // whose recording is gone (it was removed while a part was being compressed) are listed
        // under their own name, so the quota still sees and removes them.
        for i in list.indices {
            let owner = RecordingCompression.isCompressed(list[i].url) ? list[i].url.deletingPathExtension().path : list[i].url.path
            guard let mine = parts.removeValue(forKey: owner) else { continue }
            let sorted = mine.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
            list[i].parts = sorted.map(\.url)
            list[i].size += sorted.reduce(0) { $0 + $1.size }
        }
        for orphan in parts.values.flatMap({ $0 }) {
            let v = try? orphan.url.resourceValues(forKeys: [.contentModificationDateKey])
            list.append(RecordingInfo(url: orphan.url, targetKey: orphan.url.deletingLastPathComponent().lastPathComponent,
                                      size: orphan.size, modified: v?.contentModificationDate ?? .distantPast, isActive: false))
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
        // Leftovers of an interrupted compression or encryption (possibly plain text) go first.
        removeStaleTemporaryFiles(in: directory, now: now)
        // Compress first: it frees most of the space without losing anything.
        if quota == nil { compressOld(in: directory, now: now) }
        // Recordings follow the encryption switch once they are closed: those still open when it was
        // turned on are encrypted, those still open when it was turned off are decrypted (only while
        // Tether is unlocked, when the key is there).
        if quota == nil, let key = RecordingCrypto.key {
            if RecordingCrypto.encryptNew { encryptAll(with: key, in: directory) } else { decryptAll(in: directory) }
        }
        let fm = FileManager.default
        var items = all(in: directory).sorted { $0.modified < $1.modified } // oldest first
        var removed: [URL] = []
        if days > 0 {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            for item in items where !item.isActive && item.modified < cutoff {
                if remove(item) { removed.append(item.url) }
            }
            items.removeAll { removed.contains($0.url) }
        }
        var total = items.reduce(0) { $0 + $1.size }
        lock.lock(); let shorten = shortenLargest; lock.unlock()
        if shorten, total > limit {
            // One very long session must not push every other recording out: while the largest
            // holds more than half of the space, its oldest output goes first (part by part, the
            // file being written is never touched).
            for i in items.indices.sorted(by: { items[$0].size > items[$1].size }).prefix(1) {
                var item = items[i]
                while total > limit, item.size > limit / 2, let oldest = item.parts.first {
                    let size = Int64((try? oldest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    guard (try? fm.removeItem(at: oldest)) != nil else { break }
                    item.parts.removeFirst()
                    item.size -= size
                    total -= size
                    removed.append(oldest)
                }
                items[i] = item
            }
        }
        for item in items where total > limit && !item.isActive {
            if remove(item) {
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
        for item in all(in: directory) where !item.isActive { remove(item) }
    }

    /// Removes a recording with its parts. True if the recording itself is gone.
    @discardableResult
    static func remove(_ item: RecordingInfo) -> Bool {
        let fm = FileManager.default
        guard (try? fm.removeItem(at: item.url)) != nil else { return false }
        for part in item.parts { try? fm.removeItem(at: part) }
        return true
    }

    /// Removes the recording at `path` (an archived session's) with its parts, on the maintenance
    /// queue (so a compression running at that moment cannot bring it back).
    public static func delete(path: String) {
        queue.async {
            guard let url = resolve(path) else { return }
            for part in RecordingParts.parts(of: url) { try? FileManager.default.removeItem(at: part.url) }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Reads up to `maxBytes` of a recording centred on `fraction` (0…1) of the file.
    /// Returns the data and where the requested position lies within it (0…1).
    public static func slice(of url: URL, around fraction: Double, maxBytes: Int = 16 * 1024 * 1024) -> (Data, Double) {
        RecordingReader.slice(of: url, around: fraction, maxBytes: maxBytes)
    }

    /// Reads the tail of a recording (bounded so huge logs stay responsive).
    public static func tail(of url: URL, maxBytes: Int = 16 * 1024 * 1024) -> Data {
        RecordingReader.slice(of: url, around: 1, maxBytes: maxBytes).0
    }

    // MARK: Encryption

    /// Encrypts every inactive plain recording with `key` (when encryption is switched on, and in
    /// the regular maintenance pass for recordings that were still open then). Returns how many.
    @discardableResult
    public static func encryptAll(with key: SymmetricKey, in directory: URL = AppPaths.recordingsDirectory) -> Int {
        // Everything not really encrypted with this key, including output that merely starts like an
        // encrypted file (a server can print that). Recordings of a key that was reset are removed
        // (`RecordingCrypto.revoke`, `deleteEncrypted`), so none is left to be wrapped again.
        files(in: directory).filter { !RecordingCrypto.isEncrypted($0, with: key) }
            .reduce(0) { $0 + (RecordingCrypto.encryptFile($1, key: key) ? 1 : 0) }
    }

    /// Decrypts every inactive recording the loaded key opens (when encryption is switched off).
    @discardableResult
    public static func decryptAll(in directory: URL = AppPaths.recordingsDirectory) -> Int {
        files(in: directory).filter { RecordingCrypto.isEncrypted($0) }
            .reduce(0) { $0 + (RecordingCrypto.decryptFile($1) ? 1 : 0) }
    }

    /// Every file of every recording that is not being written: inactive recordings with their
    /// parts, and the parts of active ones (never written to again).
    private static func files(in directory: URL) -> [URL] {
        all(in: directory).flatMap { $0.isActive ? $0.parts : $0.files }
    }

    /// Removes `*.tmp` files older than an hour (from an interrupted compression or encryption).
    static func removeStaleTemporaryFiles(in directory: URL, now: Date = Date()) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for case let url as URL in e where url.pathExtension == "tmp" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > 3600 { try? fm.removeItem(at: url) }
        }
    }

    /// Whether any recording is encrypted with the key that has this id.
    public static func anyEncrypted(keyID: Data, in directory: URL = AppPaths.recordingsDirectory) -> Bool {
        all(in: directory).contains { $0.files.contains { RecordingCrypto.keyID(of: $0) == keyID } }
    }

    /// Deletes every encrypted recording (its key is gone for good).
    public static func deleteEncrypted(in directory: URL = AppPaths.recordingsDirectory) {
        // Only files built like encrypted ones throughout: plain output that merely starts with
        // the same letters is the user's text and stays.
        for url in files(in: directory) where RecordingCrypto.isEncrypted(url) && RecordingCrypto.isWellFormed(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// How many recordings are encrypted, out of how many.
    public static func encryptionStatus(in directory: URL = AppPaths.recordingsDirectory) -> (encrypted: Int, total: Int) {
        let items = all(in: directory)
        let key = RecordingCrypto.key
        let encrypted = items.filter { item in
            item.files.allSatisfy { url in key.map { RecordingCrypto.isEncrypted(url, with: $0) } ?? RecordingCrypto.isEncrypted(url) }
        }
        return (encrypted.count, items.count)
    }
}
