import Foundation

/// One `Keyword value` line inside an ssh config file.
public struct SSHConfigOption: Hashable, Sendable {
    /// Keyword as written in the file (case preserved).
    public var key: String
    /// Raw value text (quotes preserved).
    public var value: String
    /// Line index inside the owning document.
    public var line: Int

    /// Value split into arguments, honouring double quotes.
    public var arguments: [String] { SSHConfigDocument.tokenize(value) }
}

/// A `Host` block.
public struct SSHHostEntry: Hashable, Sendable, Identifiable {
    public var patterns: [String]
    public var options: [SSHConfigOption]
    /// Index of the `Host` header line.
    public var headerLine: Int
    /// Index one past the last line belonging to this block.
    public var endLine: Int
    /// File this entry was read from.
    public var sourceURL: URL?

    public var id: String { (sourceURL?.path ?? "") + "#" + patterns.joined(separator: " ") }

    /// The first non-wildcard, non-negated pattern; what you pass to `ssh`.
    public var alias: String? {
        patterns.first { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
    }

    /// True for blocks like `Host *` or `Host *.example.com` that are defaults, not destinations.
    public var isWildcardOnly: Bool { alias == nil }

    public func value(_ key: String) -> String? {
        options.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }.map { SSHConfigDocument.unquote($0.value) }
    }

    public func values(_ key: String) -> [String] {
        options.filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }.map { SSHConfigDocument.unquote($0.value) }
    }

    public var hostName: String? { value("HostName") }
    public var user: String? { value("User") }
    public var port: Int? { value("Port").flatMap(Int.init) }
    public var proxyJump: String? { value("ProxyJump") }
    public var identityFiles: [String] { values("IdentityFile") }
}

/// A round-trip safe representation of an ssh config file.
///
/// The document stores the original lines verbatim. Edits touch only the lines they need to,
/// so comments, blank lines, ordering and indentation are preserved.
public struct SSHConfigDocument: Sendable {
    public var lines: [String]
    public var sourceURL: URL?

    public init(text: String, sourceURL: URL? = nil) {
        var l = text.components(separatedBy: "\n")
        // `components` yields a trailing empty element for files ending in a newline.
        if l.last == "" { l.removeLast() }
        lines = l.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        self.sourceURL = sourceURL
    }

    public var text: String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    // MARK: Parsing

    /// Splits a line into keyword and value. Returns nil for blanks and comments.
    public static func parseLine(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let sep = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return (trimmed, "")
        }
        let key = String(trimmed[..<sep])
        var rest = trimmed[sep...].drop(while: { $0 == " " || $0 == "\t" })
        if rest.first == "=" { rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" }) }
        return (key, String(rest).trimmingCharacters(in: .whitespaces))
    }

    public static func tokenize(_ value: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inQuotes = false
        var hasToken = false
        for ch in value {
            if ch == "\"" { inQuotes.toggle(); hasToken = true; continue }
            if !inQuotes, ch == " " || ch == "\t" {
                if hasToken { out.append(current); current = ""; hasToken = false }
                continue
            }
            current.append(ch)
            hasToken = true
        }
        if hasToken { out.append(current) }
        return out
    }

    public static func unquote(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Quotes a value if it contains whitespace.
    public static func quoteIfNeeded(_ value: String) -> String {
        if value.contains(" ") || value.contains("\t"), !(value.hasPrefix("\"") && value.hasSuffix("\"")) {
            return "\"\(value)\""
        }
        return value
    }

    private static func isBlockHeader(_ key: String) -> Bool {
        key.caseInsensitiveCompare("Host") == .orderedSame || key.caseInsensitiveCompare("Match") == .orderedSame
    }

    /// All `Host` blocks in file order.
    public var hosts: [SSHHostEntry] {
        var result: [SSHHostEntry] = []
        var current: SSHHostEntry?
        for (i, line) in lines.enumerated() {
            guard let (key, value) = Self.parseLine(line) else { continue }
            if Self.isBlockHeader(key) {
                if var c = current { c.endLine = endOfBlock(c.headerLine, nextHeader: i); result.append(c) }
                current = key.caseInsensitiveCompare("Host") == .orderedSame
                    ? SSHHostEntry(patterns: Self.tokenize(value), options: [], headerLine: i, endLine: i + 1, sourceURL: sourceURL)
                    : nil
            } else if current != nil {
                current!.options.append(SSHConfigOption(key: key, value: value, line: i))
            }
        }
        if var c = current { c.endLine = endOfBlock(c.headerLine, nextHeader: lines.count); result.append(c) }
        return result
    }

    /// Options before the first Host/Match block (global defaults, Include lines).
    public var globalOptions: [SSHConfigOption] {
        var result: [SSHConfigOption] = []
        for (i, line) in lines.enumerated() {
            guard let (key, value) = Self.parseLine(line) else { continue }
            if Self.isBlockHeader(key) { break }
            result.append(SSHConfigOption(key: key, value: value, line: i))
        }
        return result
    }

    /// A block ends before the next header, but trailing blank/comment lines that sit directly
    /// above the next header are considered to belong to the next block.
    private func endOfBlock(_ header: Int, nextHeader: Int) -> Int {
        var end = nextHeader
        while end - 1 > header {
            let t = lines[end - 1].trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { end -= 1 } else { break }
        }
        return end
    }

    public func host(named alias: String) -> SSHHostEntry? {
        hosts.first { $0.patterns.contains(alias) }
    }

    // MARK: Editing

    public enum EditError: Error, LocalizedError {
        case hostNotFound(String)
        case hostExists(String)
        case invalidAlias(String)
        case invalidValue(String)

        public var errorDescription: String? {
            switch self {
            case .hostNotFound(let a): "Host \"\(a)\" was not found in the config file."
            case .hostExists(let a): "A host named \"\(a)\" already exists."
            case .invalidAlias(let a): "\"\(a)\" is not a valid host alias."
            case .invalidValue(let k): "The value for \(k) must be a single line without control characters."
            }
        }
    }

    /// Indentation used by existing option lines of a block, defaulting to four spaces.
    private func indentation(for entry: SSHHostEntry) -> String {
        if let first = entry.options.first {
            return String(lines[first.line].prefix(while: { $0 == " " || $0 == "\t" }))
        }
        return "    "
    }

    /// Replaces every occurrence of `key` in the host block with `values` (one line each).
    /// An empty array removes the option.
    public mutating func setOption(_ key: String, values: [String], forHost alias: String) throws {
        guard let entry = host(named: alias) else { throw EditError.hostNotFound(alias) }
        guard Self.isValidKeyword(key), values.allSatisfy(Self.isValidValue) else { throw EditError.invalidValue(key) }
        let existing = entry.options.filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }
        let indent = indentation(for: entry)
        let keyText = existing.first?.key ?? key
        let newLines = values.map { "\(indent)\(keyText) \(Self.quoteIfNeeded($0))" }

        if let first = existing.first {
            // Remove all old lines (from the bottom so indices stay valid), insert at the first one.
            for opt in existing.reversed() { lines.remove(at: opt.line) }
            lines.insert(contentsOf: newLines, at: first.line)
        } else if !newLines.isEmpty {
            let insertAt = (entry.options.last?.line).map { $0 + 1 } ?? entry.headerLine + 1
            lines.insert(contentsOf: newLines, at: insertAt)
        }
    }

    public mutating func setOption(_ key: String, value: String?, forHost alias: String) throws {
        let v = value?.trimmingCharacters(in: .whitespaces) ?? ""
        try setOption(key, values: v.isEmpty ? [] : [v], forHost: alias)
    }

    public static func isValidAlias(_ alias: String) -> Bool {
        !alias.isEmpty && !alias.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "#" })
    }

    /// One line, no control characters: a pasted value can never add lines (e.g. a ProxyCommand).
    public static func isValidValue(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    static func isValidKeyword(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Appends a new Host block at the end of the file.
    public mutating func addHost(_ alias: String, options: [(String, String)]) throws {
        guard Self.isValidAlias(alias) else { throw EditError.invalidAlias(alias) }
        guard host(named: alias) == nil else { throw EditError.hostExists(alias) }
        for (k, v) in options where !Self.isValidKeyword(k) || !Self.isValidValue(v) { throw EditError.invalidValue(k) }
        if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
        lines.append("Host \(alias)")
        for (k, v) in options where !v.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("    \(k) \(Self.quoteIfNeeded(v))")
        }
    }

    /// Removes a whole Host block, including one blank separator line.
    public mutating func removeHost(_ alias: String) throws {
        guard let entry = host(named: alias) else { throw EditError.hostNotFound(alias) }
        var end = entry.endLine
        if end < lines.count, lines[end].trimmingCharacters(in: .whitespaces).isEmpty { end += 1 }
        lines.removeSubrange(entry.headerLine..<end)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
    }

    /// Renames one pattern of a host header, keeping other patterns.
    public mutating func renameHost(_ alias: String, to newAlias: String) throws {
        guard Self.isValidAlias(newAlias) else { throw EditError.invalidAlias(newAlias) }
        guard let entry = host(named: alias) else { throw EditError.hostNotFound(alias) }
        if alias == newAlias { return }
        guard host(named: newAlias) == nil else { throw EditError.hostExists(newAlias) }
        let patterns = entry.patterns.map { $0 == alias ? newAlias : $0 }
        let header = lines[entry.headerLine]
        let indent = header.prefix(while: { $0 == " " || $0 == "\t" })
        let keyword = Self.parseLine(header)?.key ?? "Host"
        lines[entry.headerLine] = "\(indent)\(keyword) \(patterns.joined(separator: " "))"
    }

    /// Replaces the full block body for a host with the given ordered options.
    public mutating func replaceOptions(forHost alias: String, with options: [(String, String)]) throws {
        guard let entry = host(named: alias) else { throw EditError.hostNotFound(alias) }
        for (k, v) in options where !Self.isValidKeyword(k) || !Self.isValidValue(v) { throw EditError.invalidValue(k) }
        let indent = indentation(for: entry)
        // Keep comment lines inside the block, rewrite option lines.
        let bodyRange = (entry.headerLine + 1)..<entry.endLine
        let comments = lines[bodyRange].filter { Self.parseLine($0) == nil && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let newBody = comments + options
            .filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\(indent)\($0.0) \(Self.quoteIfNeeded($0.1))" }
        lines.replaceSubrange(bodyRange, with: newBody)
    }
}
