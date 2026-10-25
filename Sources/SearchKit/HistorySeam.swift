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
