import Foundation

/// Loads an ssh config file together with the files it pulls in via `Include`,
/// and writes changes back safely (with backups).
public struct SSHConfigLibrary: Sendable {
    public private(set) var documents: [SSHConfigDocument]
    public let mainURL: URL

    public init(mainURL: URL) {
        self.mainURL = mainURL
        documents = []
        reload()
    }

    public mutating func reload() {
        var docs: [SSHConfigDocument] = []
        var visited = Set<String>()
        Self.load(url: mainURL, depth: 0, into: &docs, visited: &visited)
        documents = docs
    }

    private static func load(url: URL, depth: Int, into docs: inout [SSHConfigDocument], visited: inout Set<String>) {
        let path = url.standardizedFileURL.path
        guard depth < 8, !visited.contains(path) else { return }
        visited.insert(path)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let doc = SSHConfigDocument(text: text, sourceURL: url)
        docs.append(doc)
        for (i, line) in doc.lines.enumerated() {
            _ = i
            guard let (key, value) = SSHConfigDocument.parseLine(line),
                  key.caseInsensitiveCompare("Include") == .orderedSame else { continue }
            for pattern in SSHConfigDocument.tokenize(value) {
                for included in expandInclude(pattern) {
                    load(url: included, depth: depth + 1, into: &docs, visited: &visited)
                }
            }
        }
    }

    /// Resolves an Include argument: `~` expansion, paths relative to ~/.ssh, and globs.
    static func expandInclude(_ pattern: String) -> [URL] {
        var p = (pattern as NSString).expandingTildeInPath
        if !p.hasPrefix("/") {
            p = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh").appendingPathComponent(p).path
        }
        var g = glob_t()
        defer { globfree(&g) }
        guard glob(p, 0, nil, &g) == 0 else { return [] }
        var urls: [URL] = []
        for i in 0..<Int(g.gl_pathc) {
            if let c = g.gl_pathv[i], let s = String(validatingCString: c) {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: s, isDirectory: &isDir), !isDir.boolValue {
                    urls.append(URL(fileURLWithPath: s))
                }
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    /// All concrete (non-wildcard) hosts across all files, first definition wins.
    public var hosts: [SSHHostEntry] {
        var seen = Set<String>()
        var out: [SSHHostEntry] = []
        for doc in documents {
            for h in doc.hosts where !h.isWildcardOnly {
                guard let a = h.alias, !seen.contains(a) else { continue }
                seen.insert(a)
                out.append(h)
            }
        }
        return out
    }

    public var aliases: [String] { hosts.compactMap(\.alias) }

    public func entry(for alias: String) -> SSHHostEntry? {
        hosts.first { $0.patterns.contains(alias) }
    }

    /// Index of the document that defines `alias`, or the main document for new hosts.
    public func documentIndex(for alias: String?) -> Int {
        if let alias, let i = documents.firstIndex(where: { $0.host(named: alias) != nil }) { return i }
        return 0
    }

    /// Applies an edit to the document that owns `alias` and writes it to disk.
    public mutating func edit(alias: String?, backupDirectory: URL?, _ change: (inout SSHConfigDocument) throws -> Void) throws {
        if documents.isEmpty { documents = [SSHConfigDocument(text: "", sourceURL: mainURL)] }
        let index = documentIndex(for: alias)
        var doc = documents[index]
        try change(&doc)
        try Self.write(doc, backupDirectory: backupDirectory)
        documents[index] = doc
    }

    /// Writes a document atomically with 0600 permissions, keeping a timestamped backup
    /// of the previous contents (at most 10 per file).
    public static func write(_ doc: SSHConfigDocument, backupDirectory: URL?) throws {
        guard let url = doc.sourceURL else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if let backupDirectory, fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let name = url.lastPathComponent + "." + stamp + ".bak"
            try? fm.copyItem(at: url, to: backupDirectory.appendingPathComponent(name))
            pruneBackups(in: backupDirectory, prefix: url.lastPathComponent + ".", keep: 10)
        }
        try Data(doc.text.utf8).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func pruneBackups(in dir: URL, prefix: String, keep: Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let backups = items.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".bak") }.sorted()
        for name in backups.dropLast(keep) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
