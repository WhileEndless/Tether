import Foundation
import Testing
@testable import SearchKit

/// The recording's text and memory meet where memory's first lines are, also when a program that
/// redraws its screen (a dashboard, a coding agent's full redraw) made the text much longer than
/// memory there: every redrawn screen is in the text, once each, while the terminal kept none of
/// them. Matches in memory are then not found again in the recording (Find went through them
/// twice: the upper, the lower, the upper once more), and a saved session has them once.
@Suite struct SeamUnderRedrawsTests {
    /// 1,000 old lines, then the part the terminal still holds: blocks of 40 lines whose first 16
    /// scrolled into memory before a program cleared and redrew the screen 40 times (far more text than memory has there).
    static func session(needleAt needle: Int? = nil) -> (recording: Data, memory: [String]) {
        var s = ""
        for i in 0..<1_000 { s += (i == 10 ? "needle old \(i)" : "old \(i)") + "\r\n" }
        var memory: [String] = []
        for b in 0..<10 {
            for k in 0..<40 {
                let n = b * 40 + k
                let line = n == needle ? "needle new \(n)" : "mem \(n)"
                s += line + "\r\n"
                if k < 16 { memory.append(line) }
            }
            for f in 0..<40 { s += "\u{1b}[H\u{1b}[2J" + (0..<12).map { "frame \(b) \(f) row \($0)" }.joined(separator: "\r\n") + "\r\n" }
        }
        return (Data(s.utf8), memory)
    }

    @Test func memoryIsLeftOutHoweverLongTheTextIsThere() throws {
        let (data, memory) = Self.session(needleAt: 245)     // block 6, line 5: in memory
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tether-seam-\(UUID()).ttylog")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var source = SearchSource(id: "e", kind: .recording(url: url, archiveID: nil), title: "e", host: "h", date: nil, status: "")
        source.skipTrailingLines = memory.count
        source.memoryHead = Array(memory.prefix(64))
        let regex = try NSRegularExpression(pattern: "needle")
        let found = try SearchEngine.searchSource(source, regex: regex, query: SearchQuery(pattern: "needle"), remaining: 100)
        #expect(found.map(\.text) == ["needle old 10"], "only the match before memory: \(found.map(\.text))")
    }

    /// Saving the whole session the same way: memory's lines once, not again from the recording.
    @Test func savingWritesMemoryOnce() throws {
        let (data, memory) = Self.session()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-seam-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("r.ttylog")
        try data.write(to: url)
        let out = dir.appendingPathComponent("saved.txt")
        try SessionExport.writeText(recording: url, dropLast: memory.count, lines: memory, to: out, key: nil)
        let saved = try String(contentsOf: out, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(saved.filter { $0 == "mem 245" }.count == 1, "each line once")
        #expect(saved.contains("old 0") && saved.last == memory.last)
    }
}
