import Foundation

/// How much a transfer moves.
public struct TransferSize: Sendable, Equatable {
    public var files: Int
    public var bytes: Int64

    public init(files: Int, bytes: Int64) {
        self.files = files
        self.bytes = bytes
    }
}

/// The running total of a count in progress, readable from any thread; `cancel()` stops the count.
public final class MeasureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var files = 0
    private var bytes: Int64 = 0
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// What has been counted so far.
    public var snapshot: TransferSize {
        lock.lock(); defer { lock.unlock() }
        return TransferSize(files: files, bytes: bytes)
    }

    func set(files: Int, bytes: Int64) {
        lock.lock(); self.files = files; self.bytes = bytes; lock.unlock()
    }
}

public enum LocalFiles {
    /// Counts files (folders by their contents, symlinks inside them not followed: as tar sends
    /// them) and the size of the regular ones. Stops after `limit` files (the result is then a
    /// lower bound), or when `counter` is cancelled; `counter` also shows the total as it grows.
    /// Runs on the calling thread: call it off the main thread for folders of unknown size.
    public static func measure(_ urls: [URL], limit: Int = 200_000, counter: MeasureCounter? = nil) -> TransferSize {
        var files = 0
        var bytes: Int64 = 0
        for url in urls {
            guard files < limit, counter?.isCancelled != true else { break }
            walk(url.path, limit: limit, counter: counter, files: &files, bytes: &bytes)
        }
        counter?.set(files: files, bytes: bytes)
        return TransferSize(files: files, bytes: bytes)
    }

    /// One item with fts: a top-level link is followed (tar's -H), links inside are counted as
    /// themselves; unreadable folders are skipped.
    private static func walk(_ path: String, limit: Int, counter: MeasureCounter?, files: inout Int, bytes: inout Int64) {
        guard let start = strdup(path) else { return }
        defer { free(start) }
        var roots: [UnsafeMutablePointer<CChar>?] = [start, nil]
        guard let fts = fts_open(&roots, FTS_PHYSICAL | FTS_COMFOLLOW | FTS_NOCHDIR, nil) else { return }
        defer { fts_close(fts) }
        var seen = 0
        while let entry = fts_read(fts) {
            switch Int32(entry.pointee.fts_info) {
            case FTS_D, FTS_DP, FTS_DC, FTS_DNR, FTS_ERR:
                break
            case FTS_F:
                files += 1
                bytes += Int64(entry.pointee.fts_statp?.pointee.st_size ?? 0)
            default:
                files += 1      // links, sockets, devices, entries that could not be read
            }
            seen += 1
            if seen % 512 == 0 {
                counter?.set(files: files, bytes: bytes)
                if counter?.isCancelled == true { return }
            }
            if files >= limit { return }
        }
    }

    /// Finder-style free names in a local folder: `report.pdf` → `report 2.pdf`, `report 3.pdf`, …
    /// Names already chosen earlier in the same batch count as taken.
    /// Case is ignored, as the Mac's disk does (README and readme cannot both exist).
    /// `alsoTaken`: names (lowercased) other transfers will write into this folder.
    public static func uniqueNames(in directory: URL, for names: [String], alsoTaken: Set<String> = []) -> [String] {
        var taken = alsoTaken
        return names.map { name in
            let (base, suffix) = numberedParts(name, separator: " ")
            var candidate = name
            var i = 2
            while taken.contains(candidate.lowercased()) || exists(directory.appendingPathComponent(candidate).path) {
                candidate = "\(base) \(i)\(suffix)"
                i += 1
            }
            taken.insert(candidate.lowercased())
            return candidate
        }
    }

    /// A name and the extension a number goes before (`report.pdf` → `report`, `.pdf`): only an
    /// extension that reads as one — up to 10 letters and digits, a letter among them — so
    /// `v1.2`, `app.log.1` or `.env` get the number at the end, as Finder does. The same rule as
    /// the servers' (`RemoteFileSystem.uniqueNamesScript`).
    /// The longest a name may be on the Mac's disks and the servers' (255 bytes of UTF-8).
    public static let maxNameBytes = 255

    /// `splitExtension`, with the part before the extension made short enough that a number can
    /// still go in (`<base><separator>9999<ext>` within `maxNameBytes`), cut at whole characters:
    /// a name near the limit gets a free name that the disk takes, not one it refuses.
    public static func numberedParts(_ name: String, separator: String) -> (base: String, ext: String) {
        var (base, ext) = splitExtension(name)
        // Counted as macOS hands names to programs (decomposed: `ç` is `c` and a mark, 3 bytes): a
        // name that fits then fits in either form, here and on the server.
        func bytes(_ s: String) -> Int { s.decomposedStringWithCanonicalMapping.utf8.count }
        // An extension so long the name would be mostly that: it is part of the name instead.
        if bytes(ext) > maxNameBytes / 2 { (base, ext) = (name, "") }
        let room = maxNameBytes - bytes(ext) - separator.utf8.count - 4
        while bytes(base) > room, !base.isEmpty { base.removeLast() }
        return (base, ext)
    }

    public static func splitExtension(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = name[name.index(after: dot)...]
        guard (1...10).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              ext.contains(where: \.isLetter) else { return (name, "") }
        return (String(name[..<dot]), "." + ext)
    }

    /// Something has the name, a link to nowhere included (`fileExists` follows links and would
    /// miss it, and writing there would write where the link points).
    public static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    // MARK: Removing what a transfer made

    /// Removes what a transfer made without holding up the caller: a file at once; a folder is
    /// first renamed to a hidden staging name beside it (gone from view at once, and one a crash
    /// leaves behind is a leftover `removeLeftoverStaging` knows) and then removed in the background.
    /// Links are removed themselves, never followed.
    public static func discard(_ url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { unlink(url.path); return }
        // An empty folder (a staging folder after everything moved into place) goes at once.
        if rmdir(url.path) == 0 { return }
        var target = url
        let hidden = url.deletingLastPathComponent().appendingPathComponent(newStagingName())
        var probe = stat()
        if url.lastPathComponent != hidden.lastPathComponent, lstat(hidden.path, &probe) != 0, rename(url.path, hidden.path) == 0 {
            target = hidden
        }
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: target) }
    }

    /// A fresh staging-style name (`.tether-transfer-` and twelve hex digits).
    public static func newStagingName() -> String {
        stagingPrefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    // MARK: Leftovers

    /// The prefix of the hidden folders packed transfers unpack into.
    public static let stagingPrefix = ".tether-transfer-"

    /// Whether a name is one of Tether's staging folders (`.tether-transfer-` and hex digits).
    public static func isStagingName(_ name: String) -> Bool {
        guard name.hasPrefix(stagingPrefix) else { return false }
        let rest = name.dropFirst(stagingPrefix.count)
        return rest.count >= 8 && rest.allSatisfy(\.isHexDigit)
    }

    /// Removes staging folders a packed download left in `folder` when Tether ended in the middle
    /// of it (a crash, a forced quit): only real folders (not links) named like Tether's, not in
    /// use (`active`), and untouched for `olderThan`. Returns what was removed.
    @discardableResult
    public static func removeLeftoverStaging(in folder: URL, active: Set<String> = [], olderThan age: TimeInterval = 3600) -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        var removed: [URL] = []
        for name in names where isStagingName(name) {
            let url = folder.appendingPathComponent(name, isDirectory: true)
            var info = stat()
            guard !active.contains(url.standardizedFileURL.path), lstat(url.path, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR,
                  Date().timeIntervalSince1970 - TimeInterval(info.st_mtimespec.tv_sec) >= age else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed.append(url) }
        }
        return removed
    }
}
