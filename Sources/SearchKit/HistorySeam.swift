import Foundation

/// Where a session's recording (its text, older output) meets what the terminal still holds in
/// memory, so search and export show each line once. The rule is never to lose a line: when the
/// seam cannot be found for sure, lines may show twice instead.
///
/// Memory and the recording's text do not always have the same lines: the text takes repeated
/// redraws once while the terminal keeps them on screen. So the seam is found by content — a run of
/// memory's lines, starting at any of its first lines, found at the end of the text — rather than
/// by counting.
public enum HistorySeam {
    /// Recording lines that are kept back before the cut is decided.
    public static let margin = 2_000
    /// Non-empty lines that must agree in a row (at least 3 when memory has fewer).
    static let compared = 6
    /// Memory lines tried as the start of the run (the first ones may be missing from the text).
    static let starts = 64

    /// How many lines at the end of `tail` (the last lines of the recording's text) are also in
    /// memory, whose first lines are `memoryHead`. `expected`, the count of logical lines in memory,
    /// is used only when the line there is memory's first line; otherwise nothing is cut.
    public static func overlap(tail: [String], memoryHead: [String], expected: Int) -> Int {
        guard !tail.isEmpty, !memoryHead.isEmpty else { return 0 }
        for k in 0..<min(starts, memoryHead.count) where !memoryHead[k].isEmpty {
            let run = Array(memoryHead[k...].prefix(compared * 4))
            guard run.filter({ !$0.isEmpty }).count >= 3 else { break }
            // The latest place in the text: memory holds the end of the session.
            if let p = (0..<tail.count).reversed().first(where: { matches(tail, at: $0, run) }) {
                // Memory's lines before k may or may not be in the text: keeping the text up to p
                // can only repeat them, never lose any.
                return tail.count - p
            }
        }
        let start = tail.count - min(max(expected, 0), tail.count)
        if start < tail.count, tail[start] == memoryHead[0], !memoryHead[0].isEmpty { return tail.count - start }
        return 0
    }

    /// Whether memory's first lines are found in `tail` at all (else `overlap` only guesses).
    public static func headFound(tail: [String], memoryHead: [String]) -> Bool {
        guard !tail.isEmpty, !memoryHead.isEmpty else { return false }
        for k in 0..<min(starts, memoryHead.count) where !memoryHead[k].isEmpty {
            let run = Array(memoryHead[k...].prefix(compared * 4))
            guard run.filter({ !$0.isEmpty }).count >= 3 else { break }
            if (0..<tail.count).contains(where: { matches(tail, at: $0, run) }) { return true }
        }
        return false
    }

    /// The run of memory lines starts the recording's text at `start` (as far as the text goes).
    static func matches(_ tail: [String], at start: Int, _ run: [String]) -> Bool {
        let need = min(compared, run.filter { !$0.isEmpty }.count)
        var agreed = 0
        for (i, line) in run.enumerated() {
            let j = start + i
            guard j < tail.count else { break }
            guard tail[j] == line else { return false }
            if !line.isEmpty { agreed += 1 }
            if agreed >= compared { break }
        }
        return agreed >= need && need >= 3
    }
}

/// The end of a recording's text read line by line, held back until it is known where memory
/// starts (`HistorySeam`): `hold` lines at least, and — since a program that redraws makes the
/// text much longer than memory there — from any line that could start memory onwards, until a
/// few lines more show whether it does. Lines given back are before memory for sure.
struct SeamTail {
    typealias Item = (line: String, offset: Int)
    private let hold: Int
    private let memoryHead: [String]
    private let starts: Set<String>
    private let window = HistorySeam.compared * 4 + 8
    private var items: [Item] = []
    private var head = 0
    private var candidates: [Int] = []      // places (in `items`) where memory may start, oldest first
    private var unchecked = 0
    /// Lines held beyond `hold` at most, from a place memory may start.
    static let maxExtra = 200_000

    init(hold: Int, memoryHead: [String]) {
        self.hold = hold
        self.memoryHead = memoryHead
        starts = Set(memoryHead.prefix(HistorySeam.starts).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    private var count: Int { items.count - head }

    /// Adds a line; `release` gets the lines that can go (before memory for sure), in order, and
    /// returns false to stop.
    @discardableResult
    mutating func push(_ line: String, offset: Int = 0, release: (Item) throws -> Bool) rethrows -> Bool {
        items.append((line, offset))
        if starts.contains(line) {
            candidates.append(items.count - 1)
            unchecked += 1
        }
        while unchecked > 0 {
            let at = candidates.count - unchecked
            let c = candidates[at]
            guard items.count - c >= window else { break }
            if HistorySeam.headFound(tail: items[c..<c + window].map(\.line), memoryHead: memoryHead) {
                unchecked -= 1
            } else {
                candidates.remove(at: at)
                unchecked -= 1
            }
        }
        // Memory starts at the earliest place checked (later ones are memory's own further lines).
        // Only if what is held grows far beyond any redrawing (the same lines in much older
        // output) does an earlier place give way, so the text held stays bounded.
        while candidates.count - unchecked > 1, count > hold + Self.maxExtra { candidates.removeFirst() }
        while count > hold, candidates.first.map({ $0 > head }) ?? true {
            let item = items[head]
            head += 1
            if try !release(item) { return false }
        }
        if head > 4096, head * 2 > items.count {
            items.removeFirst(head)
            candidates = candidates.map { $0 - head }
            head = 0
        }
        return true
    }

    /// What is still held (the end of the text, memory's part among it).
    var rest: [Item] { Array(items[head...]) }
}
