import Foundation
import Testing
@testable import SearchKit

/// Looking through a long recording quickly (laying out only the parts that can hold a match) finds
/// the same lines, at the same places, as laying out all of it.
@Suite struct QuickSearchTests {
    func agentRecording() -> Data {
        var s = ""
        for b in 0..<400 {
            for k in 0..<20 {
                let needle = b % 37 == 0 && k == 4 ? " needle here" : ""
                s += "\u{1b}[38;5;250m● block \(b) line \(k)\(needle) \u{1b}[1mreading\u{1b}[22m some/file.swift\u{1b}[0m\r\n"
            }
            if b % 53 == 0 { s += String(repeating: "wrapped-", count: 40) + "needle at the end\r\n" }
            // The agent's status redrawn in place; the last frame says "needle" sometimes.
            for f in 0..<20 {
                s += f == 0 ? "" : "\u{1b}[2A"
                let word = b % 61 == 0 && f == 19 ? "needle" : "working"
                s += "\r\u{1b}[2K\u{1b}[35m✻ \(word) \(f)\u{1b}[0m\r\n\r\u{1b}[2K│ status " + String(repeating: "─", count: 60) + "\r\n"
            }
        }
        return Data(s.utf8)
    }

    func lines(_ url: URL, quick: Bool) throws -> [String] {
        let regex = try NSRegularExpression(pattern: "needle", options: .caseInsensitive)
        var found: [String] = []
        try SearchEngine.forEachLine(url, key: nil, skipping: quick ? SearchEngine.Prefilter(regex: regex, before: .max) : nil) { line, offset in
            if line.range(of: "needle", options: .caseInsensitive) != nil { found.append("\(offset / SearchEngine.offsetPiece)|\(line)") }
            return true
        }
        return found
    }

    @Test func theSameLinesAreFound() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tether-quick-\(UUID()).ttylog")
        try agentRecording().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let full = try lines(url, quick: false)
        let quick = try lines(url, quick: true)
        #expect(full.count >= 20)
        #expect(quick == full)
    }

    /// A line that starts in a piece with nothing to find and ends in one with a match is laid out
    /// whole (laying out starts a little before).
    @Test func aLineAcrossPiecesIsFoundWhole() throws {
        var s = ""
        while s.utf8.count < SearchEngine.offsetPiece * 3 - 600 { s += "plain filler line\r\n" }
        s += String(repeating: "a", count: 1_000) + " needle\r\nafter\r\n"
        while s.utf8.count < SearchEngine.offsetPiece * 6 { s += "more filler\r\n" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tether-quick-\(UUID()).ttylog")
        try Data(s.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let quick = try lines(url, quick: true)
        #expect(quick == (try lines(url, quick: false)))
        #expect(quick.first?.hasSuffix(String(repeating: "a", count: 1_000) + " needle") == true)
    }

    /// Corrected typing, a full-screen program's screen and anchored patterns: the quick look
    /// agrees with laying everything out.
    @Test func typingFullScreenProgramsAndAnchors() throws {
        var s = ""
        func filler() { for i in 0..<900 { s += "filler line \(i)\r\n" } }
        filler()
        s += "$ gti\u{08}\u{08}\u{08}git stat\u{1b}[3Dtatus needle-typed\r\n"
        filler()
        s += "\u{1b}[?1049h\u{1b}[Hvim shows needle-hidden\r\n"
        for i in 0..<900 { s += "\u{1b}[\(i % 20 + 1);1Hediting \(i)" }
        s += "\u{1b}[?1049l"
        filler()
        s += "needle-anchored at the start\r\n"
        filler()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tether-quick-\(UUID()).ttylog")
        try Data(s.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let quick = try lines(url, quick: true)
        #expect(quick == (try lines(url, quick: false)))
        #expect(quick.contains { $0.hasSuffix("git status needle-typed") })
        #expect(!quick.contains { $0.contains("needle-hidden") })

        let anchored = try NSRegularExpression(pattern: "^needle-anchored", options: [])
        var found = 0
        try SearchEngine.forEachLine(url, key: nil, skipping: SearchEngine.Prefilter(regex: anchored, before: .max)) { line, _ in
            if line.hasPrefix("needle-anchored") { found += 1 }
            return true
        }
        #expect(found == 1, "an anchored pattern finds the line inside a piece")
    }

    @Test func thePrefilterSeesTextBetweenEscapes() throws {
        let p = SearchEngine.Prefilter(regex: try NSRegularExpression(pattern: "nee\\s?dle", options: .caseInsensitive), before: .max)
        #expect(p.mayMatch(Data("\u{1b}[31mNEE\u{1b}[0mDLE\r\n".utf8)))
        #expect(p.mayMatch(Data("\u{1b}]0;title\u{07}x needle".utf8)))
        #expect(!p.mayMatch(Data("\u{1b}]0;needle\u{07}nothing here".utf8)), "a title is not output")
        #expect(!p.mayMatch(Data("working\r\n".utf8)))
        let anchored = SearchEngine.Prefilter(regex: try NSRegularExpression(pattern: "^error"), before: .max)
        #expect(anchored.mayMatch(Data("ok\nerror: x".utf8)))
    }
}
