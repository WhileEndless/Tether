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
        do {
            return try BufferSearch.regex(pattern, isRegex: isRegex, caseSensitive: caseSensitive, wholeWord: wholeWord)
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
    /// For recordings of live sessions: output its recorder still keeps in memory (it follows what
    /// is on disk), searched too, so nothing has to be written early for a search.
    public var pendingOutput = Data()
    /// For recordings: before this position, only the parts that can hold a match are laid out as
    /// the terminal showed them (`SearchEngine.forEachLine(skipping:)`); nil: all of it. A find in a
    /// terminal sets it to some way before the end, so what memory holds is always laid out in full.
    public var quickBefore: Int?

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
    /// In a recording: about where in its output the line is (bytes from the start: the end of the
    /// `SearchEngine.offsetPiece` that completed it; lines a program drew in place are completed
    /// later, when they leave the screen, so this is a little after the line, never before),
    /// so a terminal can show it in place.
    public var offset: Int?

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

    public static func searchSource(_ source: SearchSource, regex: NSRegularExpression, query: SearchQuery,
                             remaining: Int, progress: ((Int) -> Void)? = nil,
                             partial: (([SearchMatch]) -> Void)? = nil) throws -> [SearchMatch] {
        if let l = source.lines {
            return match(l, sourceID: source.id, regex: regex, context: query.contextLines, limit: remaining)
        }
        guard case .recording(let url, _) = source.kind else { return [] }
        // Line by line as the recording is read: a long recording is never held as text in memory,
        // and reading stops once enough matches are found.
        var matcher = LineMatcher(sourceID: source.id, regex: regex, context: query.contextLines, limit: remaining)
        // The end of a live session's recording is also in memory (searched there): the last lines
        // are held back until the end shows how many of them to leave out (`HistorySeam`).
        let hold = source.skipTrailingLines > 0 ? source.skipTrailingLines * 2 + HistorySeam.margin : 0
        var held = SeamTail(hold: hold, memoryHead: source.memoryHead)
        let quick = source.quickBefore.map { before in Prefilter(regex: regex, before: before) }
        var lastSkipped = -1
        // With the progress, the matches so far (when there are new ones): a find shows them at once.
        var told = 0
        let report: ((Int) -> Void)? = progress.map { progress in
            { at in
                progress(at)
                if let partial, matcher.soFar.count > told { told = matcher.soFar.count; partial(matcher.soFar) }
            }
        }
        try forEachLine(url, pending: source.pendingOutput, skipping: quick, progress: report, skipped: { lastSkipped = $0 }) { line, offset in
            if hold > 0 {
                return held.push(line, offset: offset) { matcher.add($0.line, offset: $0.offset) }
            }
            return matcher.add(line, offset: offset)
        }
        if hold > 0 {
            let tail = held.rest
            // Looked at quickly, the place where memory starts must have been laid out in full: if
            // memory's first lines are not there, everything is looked at again, in full.
            if quick != nil, let first = tail.first?.offset, lastSkipped >= first - SearchEngine.offsetPiece,
               !HistorySeam.headFound(tail: tail.map(\.line), memoryHead: source.memoryHead) {
                var full = source
                full.quickBefore = nil
                return try searchSource(full, regex: regex, query: query, remaining: remaining, progress: progress, partial: partial)
            }
            let drop = HistorySeam.overlap(tail: tail.map(\.line), memoryHead: source.memoryHead, expected: source.skipTrailingLines)
            for item in tail.dropLast(drop) where matcher.add(item.line, offset: item.offset) {}
        }
        return matcher.finish()
    }

    /// Finds matches in lines given one at a time, with `context` lines before and after each.
    struct LineMatcher {
        let sourceID: String
        let regex: NSRegularExpression
        let context: Int
        let limit: Int
        private var index = 0
        private var recent: [String] = []
        /// Matches still collecting the lines after them.
        private var open: [Int] = []
        private var result: [SearchMatch] = []
        /// The matches found so far (their context lines may still be coming).
        var soFar: [SearchMatch] { result }

        init(sourceID: String, regex: NSRegularExpression, context: Int, limit: Int) {
            self.sourceID = sourceID
            self.regex = regex
            self.context = max(context, 0)
            self.limit = limit
        }

        /// False once nothing more is wanted (enough matches, their context complete).
        mutating func add(_ text: String, offset: Int? = nil) -> Bool {
            defer { index += 1 }
            var stillOpen: [Int] = []
            for i in open {
                result[i].after.append(text)
                if result[i].after.count < context { stillOpen.append(i) }
            }
            open = stillOpen
            if result.count < limit {
                let found = regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
                if !found.isEmpty {
                    result.append(SearchMatch(sourceID: sourceID, line: index, text: text,
                                              ranges: found.map(\.range).filter { $0.length > 0 }, before: recent, after: [],
                                              offset: offset))
                    if context > 0 { open.append(result.count - 1) }
                }
            }
            if context > 0 {
                recent.append(text)
                if recent.count > context { recent.removeFirst() }
            }
            return result.count < limit || !open.isEmpty
        }

        func finish() -> [SearchMatch] { result }
    }

    /// A first-in first-out list of lines without moving the rest on every removal.
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
        var lines: [String] = []
        try forEachLine(url, key: key) { lines.append($0); return true }
        return lines
    }

    /// The recording's lines one at a time (as `readLines`); `body` returns false to stop reading.
    public static func forEachLine(_ url: URL, key: SymmetricKey? = RecordingCrypto.key, _ body: (String) throws -> Bool) throws {
        try forEachLine(url, key: key) { line, _ in try body(line) }
    }

    /// How exactly `SearchMatch.offset` says where a line is.
    public static let offsetPiece = 16 * 1024

    /// The same, with about where each line is in the output: the end of the `offsetPiece` of the
    /// recording that completed it.
    ///
    /// `skipping`: before its position, pieces that cannot hold a match (seen through a quick look
    /// at their text without escape sequences) are not laid out at all — that layout is most of the
    /// time a long recording takes. Laying out starts afresh a little before a piece that can, and
    /// stops again two pieces after. `progress` is told the position about every 256 KB.
    public static func forEachLine(_ url: URL, key: SymmetricKey? = RecordingCrypto.key, pending: Data = Data(),
                                   skipping quick: Prefilter? = nil, progress: ((Int) -> Void)? = nil,
                                   skipped: ((Int) -> Void)? = nil,
                                   _ body: (String, Int) throws -> Bool) throws {
        let layout = LineLayout(quick: quick, progress: progress, skipped: skipped)
        try withoutActuallyEscaping(body) { body in
            let lines: (String, Int, Int) throws -> Bool = { line, offset, _ in try body(line, offset) }
            try RecordingReader.forEachChunk(of: url, key: key) { try layout.take($0, lines) }
            if !layout.stopped, !pending.isEmpty { try layout.take(pending, lines) }
            try layout.finish(lines)
        }
    }

    /// Lays output out as the terminal showed it, a piece (`offsetPiece`) at a time, and hands on
    /// each finished line with the end of the piece that finished it and where its first row was
    /// made (the output first reached it: its text was written there or after — long before it
    /// finished where a program redrew below it).
    final class LineLayout {
        private var text: ScreenText
        private(set) var stopped = false
        private var offset: Int
        private var reported: Int
        /// Laying out now (or skipping), the pieces skipped last (to start from) and how many quiet
        /// pieces were laid out since one that could match.
        private var active: Bool
        private var context: [(bytes: Data, end: Int)] = []
        /// A full-screen program's screen was up where skipping reached (laid out again in it).
        private var inAlternate = false
        private var quiet = 0
        private var tail = Data()
        private let quick: Prefilter?
        private let progress: ((Int) -> Void)?
        private let skipped: ((Int) -> Void)?
        private let cols: Int, rows: Int
        /// Where each piece laid out started, and the rows the output had reached by its end.
        private var made: [(start: Int, rows: Int)] = []
        /// Where the current layout started (its first rows were made there).
        private var layoutStart: Int

        /// `start`: where the output begins in the recording; `cols`/`rows`: the terminal's size there.
        init(start: Int = 0, cols: Int = ScreenText.defaultCols, rows: Int = ScreenText.defaultRows, startsInAlternate: Bool = false,
             quick: Prefilter?, progress: ((Int) -> Void)? = nil, skipped: ((Int) -> Void)? = nil) {
            self.cols = cols
            self.rows = rows
            text = ScreenText(cols: cols, rows: rows)
            offset = start
            reported = start
            layoutStart = start
            active = quick == nil
            self.quick = quick
            self.progress = progress
            self.skipped = skipped
            inAlternate = startsInAlternate
            if startsInAlternate { _ = text.feed(Array("\u{1b}[?1049h".utf8)) }
        }

        /// Where the row `row` was made (the start of the piece the output reached it in).
        private func madeAt(_ row: Int) -> Int {
            var lo = 0, hi = made.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if made[mid].rows > row { hi = mid } else { lo = mid + 1 }
            }
            return lo < made.count ? made[lo].start : (made.last?.start ?? layoutStart)
        }

        /// How finely where rows were reached is noted: at these multiples of the position (the
        /// same in every layout of the same output, wherever it started).
        static let reachStep = 2048

        /// Feeds a piece that started at `start` and hands on the lines it finished.
        private func feed(_ bytes: Data, start: Int, _ body: (String, Int, Int) throws -> Bool) throws {
            if made.isEmpty { made.append((layoutStart, text.rowsReached)) }
            var at = bytes.startIndex, position = start
            while at < bytes.endIndex {
                let next = min(at + (Self.reachStep - position % Self.reachStep), bytes.endIndex)
                let before = text.rowsTaken
                let lines = text.feed(bytes[at..<next])
                made.append((position, text.rowsReached))
                try emit(lines, from: before, body)
                position += next - at
                at = next
            }
        }

        private func emit(_ lines: [String], from row: Int, _ body: (String, Int, Int) throws -> Bool) throws {
            for (j, line) in lines.enumerated() where !stopped {
                if try !body(line, offset, madeAt(row + j)) { stopped = true }
            }
            // What is taken is not looked up again.
            if made.count > 64, let keep = made.firstIndex(where: { $0.rows > text.rowsTaken }), keep > 1 { made.removeFirst(keep - 1) }
        }

        /// Starts a layout afresh at `start` (after pieces that were not laid out).
        private func restart(at start: Int) {
            text = ScreenText(cols: cols, rows: rows)
            if inAlternate { _ = text.feed(Array("\u{1b}[?1049h".utf8)) }
            layoutStart = start
            made = []
        }

        /// Lays out a chunk of output (any length); false once `body` said to stop.
        @discardableResult
        func take(_ chunk: Data, _ body: (String, Int, Int) throws -> Bool) throws -> Bool {
            try Task.checkCancellation()
            var piece = chunk.startIndex
            while piece < chunk.endIndex, !stopped {
                let end = min(piece + SearchEngine.offsetPiece, chunk.endIndex)
                let bytes = chunk[piece..<end]
                let start = offset
                offset += end - piece
                if let progress, offset - reported >= 1 << 18 { reported = offset; progress(offset) }
                if let quick {
                    let wanted = offset > quick.before || quick.mayMatch(tail, bytes)
                    tail = Data(bytes.suffix(256))
                    if wanted {
                        if !active {
                            // Afresh, from a little before (a line drawn across the cut is kept whole).
                            restart(at: context.first.map { $0.end - $0.bytes.count } ?? start)
                            let now = offset
                            for c in context { offset = c.end; try feed(c.bytes, start: c.end - c.bytes.count, body) }
                            offset = now
                            context = []
                            active = true
                        }
                        quiet = 0
                    } else if active {
                        quiet += 1
                        // Stopped only well after the last piece that could match: what is still on
                        // the screen then is mostly not what it was.
                        if quiet > 8 {
                            try feed(Data(bytes), start: start, body)
                            inAlternate = text.inAlternateScreen
                            let before = text.rowsTaken
                            try emit(text.finish(), from: before, body)
                            active = false
                            context = []
                            piece = end
                            continue
                        }
                    } else {
                        if let alternate = Prefilter.alternateScreen(after: Data(bytes)) { inAlternate = alternate }
                        skipped?(offset)
                        context.append((Data(bytes), offset))
                        if context.count > 2 { context.removeFirst() }
                        piece = end
                        continue
                    }
                }
                try feed(Data(bytes), start: start, body)
                piece = end
            }
            return !stopped
        }

        /// The lines still on the screen.
        func finish(_ body: (String, Int, Int) throws -> Bool) throws {
            guard !stopped, active else { return }
            let before = text.rowsTaken
            try emit(text.finish(), from: before, body)
        }
    }

    /// A quick look at raw output: whether a piece can hold a match of `regex` (its text with escape
    /// sequences left out; carriage returns and other controls as line breaks, so text drawn over
    /// is looked at too). Never says no to a piece that holds a match on one line.
    public struct Prefilter: Sendable {
        let regex: NSRegularExpression
        /// Only before this position (after it everything is laid out).
        public let before: Int

        public init(regex: NSRegularExpression, before: Int) {
            // `^` and `$` at every line of the piece, as they are for the lines laid out.
            self.regex = (try? NSRegularExpression(pattern: regex.pattern, options: regex.options.union(.anchorsMatchLines))) ?? regex
            self.before = before
        }

        /// Whether `bytes` enter (true) or leave (false) a full-screen program's screen last
        /// (`ESC[?1049h`, `?1047`, `?47`; `l` leaves), read from the end.
        static func alternateScreen(after bytes: Data) -> Bool? {
            bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool? in
                let b = raw.bindMemory(to: UInt8.self)
                var i = b.count - 1
                while i >= 3 {
                    let c = b[i]
                    if c == 0x68 || c == 0x6c {                      // h, l
                        var j = i - 1
                        while j >= 0, b[j] >= 0x30, b[j] <= 0x39 { j -= 1 }
                        if j >= 2, b[j] == 0x3f, b[j - 1] == 0x5b, b[j - 2] == 0x1b {
                            let digits = String(decoding: UnsafeBufferPointer(rebasing: b[(j + 1)..<i]), as: UTF8.self)
                            if digits == "1049" || digits == "1047" || digits == "47" { return c == 0x68 }
                        }
                    }
                    i -= 1
                }
                return nil
            }
        }

        func mayMatch(_ bytes: Data) -> Bool { mayMatch(Data(), bytes) }

        /// `before` (the end of the piece before) and `piece` as one.
        func mayMatch(_ before: Data, _ piece: Data) -> Bool {
            var bytes = [UInt8]()
            bytes.reserveCapacity(before.count + piece.count)
            bytes.append(contentsOf: before)
            bytes.append(contentsOf: piece)
            var out = [UInt8]()
            out.reserveCapacity(bytes.count)
            var i = bytes.startIndex
            let end = bytes.endIndex
            while i < end {
                let b = bytes[i]
                if b == 0x1b, i + 1 < end {
                    let kind = bytes[i + 1]
                    i += 2
                    if kind == 0x5b {                      // CSI: up to a final byte
                        while i < end, !(0x40...0x7e).contains(bytes[i]) { i += 1 }
                        // Text put together on the screen (moved over, inserted, deleted within a
                        // line): this look cannot tell what it says, so the piece is laid out.
                        if i < end, [0x43, 0x44, 0x40, 0x50, 0x58].contains(bytes[i]) { return true }   // C D @ P X
                        i += 1
                    } else if kind == 0x5d || kind == 0x50 || kind == 0x5f { // OSC, DCS, APC: up to BEL or ST
                        while i < end, bytes[i] != 0x07, !(bytes[i] == 0x1b && i + 1 < end && bytes[i + 1] == 0x5c) { i += 1 }
                        i += bytes.indices.contains(i) && bytes[i] == 0x1b ? 2 : 1
                    }
                    continue
                }
                if b == 0x08 { return true }               // a backspace: corrected typing
                out.append(b < 0x20 && b != 0x09 ? 0x0a : b)
                i += 1
            }
            let s = String(decoding: out, as: UTF8.self)
            return regex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
        }
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
