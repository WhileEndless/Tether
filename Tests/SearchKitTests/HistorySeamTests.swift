import Foundation
import Testing
@testable import SearchKit

/// Where the recording's text meets the lines in memory: found by content, and never at the cost
/// of a line (when unsure, lines may show twice).
@Suite struct HistorySeamTests {
    @Test func foundWhenTheTextIsShorterThanMemory() {
        // The text took a redraw once; memory (starting at line 40) still holds it twice.
        let text = (0..<100).map { "line \($0)" }
        let memory = Array(text[40...]) + Array(text[60..<80])
        #expect(HistorySeam.overlap(tail: text, memoryHead: Array(memory.prefix(64)), expected: memory.count) == 60)
    }

    @Test func foundWhenMemoryStartsWithLinesTheTextDropped() {
        // Memory's first lines are a repeat the text left out; the run after them still matches.
        let text = ["a", "b", "c"] + (0..<50).map { "line \($0)" }
        let memory = ["x1", "x2", "x3"] + Array(text[20...])
        #expect(HistorySeam.overlap(tail: text, memoryHead: memory, expected: memory.count) == text.count - 20)
    }

    @Test func nothingIsCutWhenNothingMatches() {
        let text = (0..<50).map { "old \($0)" }
        let memory = (0..<30).map { "new \($0)" }
        #expect(HistorySeam.overlap(tail: text, memoryHead: memory, expected: 30) == 0)
    }
}
