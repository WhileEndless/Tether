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

public enum LocalFiles {
    /// Counts files (folders by their contents, symlinks not followed) and their total size.
    /// Stops counting after `limit` files so huge trees stay quick; the size is then a lower bound.
    public static func measure(_ urls: [URL], limit: Int = 200_000) -> TransferSize {
        var files = 0
        var bytes: Int64 = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true && values?.isSymbolicLink != true {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
                while let child = e?.nextObject() as? URL, files < limit {
                    let v = try? child.resourceValues(forKeys: Set(keys))
                    if v?.isDirectory == true && v?.isSymbolicLink != true { continue }
                    files += 1
                    bytes += Int64(v?.fileSize ?? 0)
                }
            } else {
                files += 1
                bytes += Int64(values?.fileSize ?? 0)
            }
        }
        return TransferSize(files: files, bytes: bytes)
    }

    /// Finder-style free names in a local folder: `report.pdf` → `report 2.pdf`, `report 3.pdf`, …
    /// Names already chosen earlier in the same batch count as taken.
    /// Case is ignored, as the Mac's disk does (README and readme cannot both exist).
    public static func uniqueNames(in directory: URL, for names: [String]) -> [String] {
        var taken = Set<String>()
        return names.map { name in
            let ext = (name as NSString).pathExtension
            let base = ext.isEmpty || name.hasPrefix(".") && !name.dropFirst().contains(".")
                ? name : (name as NSString).deletingPathExtension
            let suffix = base == name ? "" : "." + ext
            var candidate = name
            var i = 2
            while taken.contains(candidate.lowercased())
                    || FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                candidate = "\(base) \(i)\(suffix)"
                i += 1
            }
            taken.insert(candidate.lowercased())
            return candidate
        }
    }
}
