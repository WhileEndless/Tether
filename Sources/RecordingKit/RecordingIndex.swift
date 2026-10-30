import Foundation
import CryptoKit

/// Where lines and commands are in a recording, so any part of a long session can be found
/// without reading it all: the position of every `step`th line (at least `minSpacing` apart), and of every command the user
/// ran (with when). Kept by the recorder as it writes (`SessionRecorder.index`), or built by
/// reading a recording (`build`). Positions are bytes of output from the start of the recording,
/// as `RecordingReader` counts them (see `readerOffset` when the oldest parts were removed).
public struct RecordingIndex: Sendable, Equatable {
    public static let step = 256
    /// Checkpoints are at least this far apart: output of very short lines (`yes`, a counter) would
    /// otherwise add one every few hundred bytes, without limit.
    public static let minSpacing = 64 * 1024

    /// Where checkpoint lines start (every `step`th line, at least `minSpacing` apart).
    public private(set) var checkpoints: [Int] = [0]
    /// The line each checkpoint starts.
    public private(set) var checkpointLines: [Int] = [0]
    /// Line breaks so far: the lines before the one being written.
    public private(set) var lines = 0
    /// Bytes indexed.
    public private(set) var length = 0
    /// Where the line being written starts.
    public private(set) var lastLineStart = 0
    public struct Mark: Sendable, Equatable {
        /// Where the command's line starts (the prompt and what was typed).
        public var offset: Int
        public var line: Int
        public var time: Date
        /// Where Return was pressed (the marker's place): the cursor is on the command's line there,
        /// also when a program drew more below it (an agent's footer) or redrew in place.
        public var at: Int
        /// The column where typing started on the command's first row (after the prompt), when known.
        public var column: Int?
        /// Lines above the cursor's at `at` where the command is: typed ahead while a program still
        /// printed, it is noted once the shell has shown it, below what the program printed.
        public var up: Int

        public init(offset: Int, line: Int, time: Date, at: Int? = nil, column: Int? = nil, up: Int = 0) {
            self.offset = offset
            self.line = line
            self.time = time
            self.at = at ?? offset
            self.column = column
            self.up = up
        }
    }
    /// Commands run, oldest first.
    public private(set) var marks: [Mark] = []
    /// Bytes each part of the recording held, by part number - 1 (to translate positions once the
    /// storage limit removed the oldest parts).
    public private(set) var partLengths: [Int] = []
    /// False once output was lost on the way to the disk (a full disk): positions after that are
    /// not where this says.
    public private(set) var isExact = true

    public init() {}

    /// Notes output appended to the recording.
    public mutating func add(_ bytes: some Collection<UInt8>) {
        var position = length
        for b in bytes {
            position += 1
            if b == 0x0a {
                lines += 1
                lastLineStart = position
                if lines % Self.step == 0, position - checkpoints[checkpoints.count - 1] >= Self.minSpacing {
                    checkpoints.append(position)
                    checkpointLines.append(lines)
                }
            }
        }
        length = position
    }

    /// The user ran a command on the line being written.
    public mutating func addMark(at time: Date, column: Int? = nil, up: Int = 0) {
        if let last = marks.last, last.offset == lastLineStart { return }
        marks.append(Mark(offset: lastLineStart, line: lines, time: time, at: length, column: column, up: up))
    }

    mutating func addPart(length: Int) { partLengths.append(length) }
    mutating func lostOutput() { isExact = false }

    /// The checkpoint at or before line `line`: its line number and where it starts.
    public func checkpoint(forLine line: Int) -> (line: Int, offset: Int) {
        var lo = 0, hi = checkpointLines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if checkpointLines[mid] <= line { lo = mid } else { hi = mid - 1 }
        }
        return (checkpointLines[lo], checkpoints[lo])
    }

    /// The checkpoint at or before position `offset`.
    public func checkpoint(before offset: Int) -> (line: Int, offset: Int) {
        var lo = 0, hi = checkpoints.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if checkpoints[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return (checkpointLines[lo], checkpoints[lo])
    }

    /// About which line position `offset` is on: counted exactly up to the checkpoint before it,
    /// then in proportion to the bytes to the next checkpoint (or the end).
    public func line(near offset: Int) -> Double {
        var lo = 0, hi = checkpoints.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if checkpoints[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        let (startLine, start) = (checkpointLines[lo], checkpoints[lo])
        let (endLine, end) = lo + 1 < checkpoints.count ? (checkpointLines[lo + 1], checkpoints[lo + 1]) : (lines, length)
        guard end > start else { return Double(startLine) }
        let f = min(max(Double(offset - start) / Double(end - start), 0), 1)
        return Double(startLine) + f * Double(endLine - startLine)
    }

    /// Bytes of output in parts that are gone: positions here minus this are `RecordingReader`'s.
    /// `firstPart` is the number of the oldest part still there (nil: none was ever removed).
    /// nil with parts known: every part is gone.
    public func removedLength(firstPart: Int?) -> Int {
        guard let firstPart else { return partLengths.reduce(0, +) }
        guard firstPart > 1 else { return 0 }
        return partLengths.prefix(firstPart - 1).reduce(0, +)
    }

    // MARK: Command marks in the recording

    /// Written into the recording when the user runs a command (`ESC ] 7771 ; mark=<ms> BEL`, an
    /// OSC sequence terminals ignore), so a recording read later knows where commands were, and when;
    /// with `;col=<n>` the column typing started at (after the prompt), `;up=<n>` the lines above the
    /// cursor's the command is on (noted after the shell showed a command typed ahead).
    public static func markBytes(at time: Date, column: Int? = nil, up: Int = 0) -> [UInt8] {
        let ms = Int64((time.timeIntervalSince1970 * 1000).rounded())
        return Array("\u{1b}]7771;mark=\(ms)\(column.map { ";col=\($0)" } ?? "")\(up > 0 ? ";up=\(up)" : "")\u{07}".utf8)
    }

    static let markPrefix = Array("\u{1b}]7771;mark=".utf8)

    /// The time, column and lines up of a marker's body (`<ms>`, then `;col=<n>`, `;up=<n>`,
    /// after `mark=`).
    public static func parseMark(_ body: some Collection<UInt8>) -> (time: Date, column: Int?, up: Int)? {
        let text = String(decoding: body, as: UTF8.self)
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        guard let first = parts.first, let ms = Int64(first) else { return nil }
        func value(_ key: String) -> Int? { parts.dropFirst().first { $0.hasPrefix(key) }.flatMap { Int($0.dropFirst(key.count)) } }
        return (Date(timeIntervalSince1970: Double(ms) / 1000), value("col=").map { max($0, 0) }, min(max(value("up=") ?? 0, 0), 10_000))
    }

    /// Reads a recording through to index it (for one the recorder did not index: an earlier run's).
    /// The parts' lengths are noted too (parts already removed as none), so a recorder continuing
    /// the recording keeps positions right when its oldest parts go later.
    /// `stop` ends it early (the recording is being closed); the index then says it is not exact,
    /// as it does when the recording cannot be read through.
    public static func build(_ url: URL, key: SymmetricKey? = RecordingCrypto.key,
                             stop: () -> Bool = { false }) -> RecordingIndex {
        var index = RecordingIndex()
        var carry: [UInt8] = []
        var partStart = 0
        var complete = true
        do { try RecordingReader.forEachChunk(of: url, key: key, partDone: { number in
            let end = index.length + carry.count
            while index.partLengths.count < number - 1 { index.partLengths.append(0) }
            index.partLengths.append(end - partStart)
            partStart = end
        }) { chunk in
            // Marks are found in the bytes before indexing them (one may be cut by the chunk).
            let bytes = carry + Array(chunk)
            let keep = min(bytes.count, 64)
            let ready = bytes[..<(bytes.count - keep)]
            index.scan(ready)
            carry = Array(bytes[(bytes.count - keep)...])
            if stop() { complete = false; return false }
            return true
        } } catch { complete = false }
        index.scan(carry[...])
        if !complete { index.lostOutput() }
        return index
    }

    private mutating func scan(_ bytes: ArraySlice<UInt8>) {
        var from = bytes.startIndex
        var i = bytes.startIndex
        while let esc = bytes[i...].firstIndex(of: 0x1b) {
            if bytes[esc...].starts(with: Self.markPrefix) {
                let body = esc + Self.markPrefix.count
                if let bell = bytes[body...].prefix(48).firstIndex(of: 0x07),
                   let mark = Self.parseMark(bytes[body..<bell]) {
                    // Noted where the marker starts, as the recorder notes it while writing.
                    add(bytes[from..<esc])
                    addMark(at: mark.time, column: mark.column, up: mark.up)
                    add(bytes[esc..<(bell + 1)])
                    from = bell + 1
                    i = from
                    continue
                }
            }
            i = esc + 1
        }
        add(bytes[from...])
    }
}
