import Foundation
import CryptoKit
import RecordingKit
import TerminalText

/// What to look for.
public struct SearchQuery: Sendable, Equatable {
    public var pattern: String
    public var isRegex = false
    public var caseSensitive = false
    public var wholeWord = false
    /// Lines of context kept around each match.
    public var contextLines = 2
    /// Stop after this many matches overall.
    public var limit = 10_000

    public init(pattern: String) { self.pattern = pattern }

    /// Builds the matcher, or throws a readable error for an invalid regular expression.
    public func makeRegex() throws -> NSRegularExpression {
        var p = isRegex ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        if wholeWord { p = "\\b(?:\(p))\\b" }
        var options: NSRegularExpression.Options = []
        if !caseSensitive { options.insert(.caseInsensitive) }
        do {
            return try NSRegularExpression(pattern: p, options: options)
        } catch {
            throw SearchError.invalidPattern("Invalid regular expression")
        }
    }
}

public enum SearchError: Error, LocalizedError, Equatable {
    case invalidPattern(String)
    public var errorDescription: String? {
        switch self { case .invalidPattern(let m): m }
    }
}

/// Something that can be searched.
public struct SearchSource: Identifiable, Sendable, Hashable {
    public enum Kind: Hashable, Sendable {
        /// The scrollback of an open terminal. `lineBase` is the scroll-invariant row of line 0.
        case live(sessionID: UUID, lineBase: Int)
        /// A recorded transcript on disk (archived session or old recording).
        case recording(url: URL, archiveID: UUID?)
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var host: String
    public var date: Date?
    public var status: String
    /// For live sources: the lines, captured on the main thread before searching.
    public var lines: [String]?
    /// For recordings of live sessions: about this many lines at the end are still in memory and
    /// searched there, so long sessions are searched completely without duplicates. The exact cut is
    /// found by content with `memoryHead`, the first logical lines in memory (`HistorySeam`).
    public var skipTrailingLines = 0
    public var memoryHead: [String] = []

    public init(id: String, kind: Kind, title: String, host: String, date: Date?, status: String, lines: [String]? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.host = host
        self.date = date
        self.status = status
        self.lines = lines
    }
}

/// One matching line.
public struct SearchMatch: Identifiable, Sendable, Hashable {
    public var id: String { "\(sourceID)#\(line)" }
    public var sourceID: String
    /// 0-based line number within the source.
    public var line: Int
    public var text: String
    /// Matched ranges within `text` (UTF-16 offsets, for NSString / AttributedString).
    public var ranges: [NSRange]
    public var before: [String]
    public var after: [String]

    /// The matched substrings only.
    public var matchedTexts: [String] {
        let ns = text as NSString
        return ranges.map { ns.substring(with: $0) }
    }
}

/// Runs a query over sources in the background and streams the results.
public enum SearchEngine {
    public struct Progress: Sendable {
        public var source: SearchSource
        public var matches: [SearchMatch]
    }

    /// What the search reports while it runs.
    public enum Event: Sendable {
        /// Starting on source `index` of `total`.
        case searching(index: Int, total: Int, source: SearchSource)
        case found(Progress)
    }

    public static func search(_ query: SearchQuery, in sources: [SearchSource]) -> AsyncThrowingStream<Progress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    for try await event in events(query, in: sources) {
                        if case .found(let p) = event { continuation.yield(p) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Like `search`, but also reports which source is being searched (for progress bars).
    public static func events(_ query: SearchQuery, in sources: [SearchSource]) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let regex = try query.makeRegex()
                    var total = 0
                    for (i, source) in sources.enumerated() {
                        try Task.checkCancellation()
                        continuation.yield(.searching(index: i, total: sources.count, source: source))
                        let matches = try searchSource(source, regex: regex, query: query, remaining: query.limit - total)
                        total += matches.count
                        if !matches.isEmpty { continuation.yield(.found(Progress(source: source, matches: matches))) }
                        if total >= query.limit { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func searchSource(_ source: SearchSource, regex: NSRegularExpression, query: SearchQuery,
                             remaining: Int) throws -> [SearchMatch] {
        let lines: [String]
        if let l = source.lines {
            lines = l
        } else if case .recording(let url, _) = source.kind {
            let all = try readLines(url)
            if source.skipTrailingLines > 0 {
                let tail = Array(all.suffix(max(source.skipTrailingLines, 0) * 2 + HistorySeam.margin))
                lines = Array(all.dropLast(HistorySeam.overlap(tail: tail, memoryHead: source.memoryHead, expected: source.skipTrailingLines)))
            } else {
                lines = all
            }
        } else {
            lines = []
        }
        return match(lines, sourceID: source.id, regex: regex, context: query.contextLines, limit: remaining)
    }

    public static func match(_ lines: [String], sourceID: String, regex: NSRegularExpression, context: Int,
                             limit: Int) -> [SearchMatch] {
        var result: [SearchMatch] = []
        for (i, text) in lines.enumerated() {
            if result.count >= limit { break }
            if i % 2048 == 0, Task.isCancelled { break }
            let ns = text as NSString
            let found = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !found.isEmpty else { continue }
            let lo = max(0, i - context), hi = min(lines.count - 1, i + context)
            result.append(SearchMatch(sourceID: sourceID, line: i, text: text,
                                      ranges: found.map(\.range).filter { $0.length > 0 },
                                      before: Array(lines[lo..<i]), after: i < hi ? Array(lines[(i + 1)...hi]) : []))
        }
        return result
    }

    /// Reads a recording (compressed, encrypted or in parts) as the text the terminal showed
    /// (`ScreenText`), in chunks so large files stay manageable.
    public static func readLines(_ url: URL, key: SymmetricKey? = RecordingCrypto.key) throws -> [String] {
        let text = ScreenText()
        var lines: [String] = []
        try RecordingReader.forEachChunk(of: url, key: key) { chunk in
            try Task.checkCancellation()
            lines.append(contentsOf: text.feed(chunk))
            return true
        }
        lines.append(contentsOf: text.finish())
        return lines
    }
}

/// Export helpers for search results.
public enum SearchExport {
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case text = "Plain Text", csv = "CSV", json = "JSON"
        public var id: String { rawValue }
        public var fileExtension: String {
            switch self { case .text: "txt"; case .csv: "csv"; case .json: "json" }
        }
    }

    public static func render(_ groups: [(source: SearchSource, matches: [SearchMatch])], format: Format,
                              includeContext: Bool) -> String {
        switch format {
        case .text:
            var out = ""
            for g in groups {
                out += "== \(g.source.title) [\(g.source.host)] — \(g.matches.count) match\(g.matches.count == 1 ? "" : "es")\n"
                for m in g.matches {
                    if includeContext { m.before.forEach { out += "      \($0)\n" } }
                    out += String(format: "%5d: ", m.line + 1) + m.text + "\n"
                    if includeContext { m.after.forEach { out += "      \($0)\n" }; out += "\n" }
                }
                out += "\n"
            }
            return out
        case .csv:
            func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            var out = "source,host,status,line,text,matches\n"
            for g in groups {
                for m in g.matches {
                    out += [esc(g.source.title), esc(g.source.host), esc(g.source.status), String(m.line + 1),
                            esc(m.text), esc(m.matchedTexts.joined(separator: " | "))].joined(separator: ",") + "\n"
                }
            }
            return out
        case .json:
            let objects: [[String: Any]] = groups.flatMap { g in
                g.matches.map { m in
                    var o: [String: Any] = ["source": g.source.title, "host": g.source.host, "status": g.source.status,
                                            "line": m.line + 1, "text": m.text, "matches": m.matchedTexts]
                    if includeContext { o["before"] = m.before; o["after"] = m.after }
                    return o
                }
            }
            let data = (try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }
}
