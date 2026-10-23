import Foundation
import Testing
@testable import SearchKit
import RecordingKit

@Suite struct SearchTests {
    @Test func stripsEscapesAndOverwrites() {
        let raw = "\u{1b}[1;32mok\u{1b}[0m done\r\n\u{1b}]0;title\u{07}prompt$ ls\r\n10%\r50%\r100%\r\nab\u{08}c\n\u{1b}kvim\u{1b}\\last"
        let lines = PlainTextConverter.lines(from: Data(raw.utf8))
        #expect(lines == ["ok done", "prompt$ ls", "100%", "ac", "last"])
    }

    @Test func plainAndRegexMatching() throws {
        let lines = ["error: disk full", "all good", "ERROR timeout after 30s", "terror"]
        var q = SearchQuery(pattern: "error")
        var m = SearchEngine.match(lines, sourceID: "s", regex: try q.makeRegex(), context: 1, limit: 100)
        #expect(m.map(\.line) == [0, 2, 3])
        q.wholeWord = true
        m = SearchEngine.match(lines, sourceID: "s", regex: try q.makeRegex(), context: 1, limit: 100)
        #expect(m.map(\.line) == [0, 2])
        q.caseSensitive = true
        m = SearchEngine.match(lines, sourceID: "s", regex: try q.makeRegex(), context: 1, limit: 100)
        #expect(m.map(\.line) == [0])
        #expect(m[0].after == ["all good"])

        var r = SearchQuery(pattern: #"after (\d+)s"#)
        r.isRegex = true
        m = SearchEngine.match(lines, sourceID: "s", regex: try r.makeRegex(), context: 0, limit: 100)
        #expect(m.first?.matchedTexts == ["after 30s"])
    }

    @Test func invalidRegexIsReported() {
        var q = SearchQuery(pattern: "(unclosed")
        q.isRegex = true
        #expect(throws: SearchError.self) { try q.makeRegex() }
    }

    @Test func searchesRecordingsOnDisk() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tether-search-\(UUID()).ttylog")
        try Data("one\r\n\u{1b}[31mneedle\u{1b}[0m here\r\nthree\r\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = SearchSource(id: "r", kind: .recording(url: url, archiveID: nil), title: "t", host: "h", date: nil, status: "Archived")
        var found: [SearchMatch] = []
        for try await p in SearchEngine.search(SearchQuery(pattern: "needle"), in: [source]) { found += p.matches }
        #expect(found.map(\.text) == ["needle here"])
        #expect(found.first?.line == 1)
    }

    @Test func exportFormats() {
        let s = SearchSource(id: "a", kind: .recording(url: URL(fileURLWithPath: "/x"), archiveID: nil), title: "web", host: "h", date: nil, status: "Online")
        let m = SearchMatch(sourceID: "a", line: 4, text: "say \"hi\"", ranges: [NSRange(location: 4, length: 4)], before: [], after: [])
        #expect(SearchExport.render([(s, [m])], format: .csv, includeContext: false).contains("\"say \"\"hi\"\"\""))
        #expect(SearchExport.render([(s, [m])], format: .text, includeContext: false).contains("    5: say \"hi\""))
        #expect(SearchExport.render([(s, [m])], format: .json, includeContext: false).contains("\"line\" : 5"))
    }
}

@Suite struct CompressedSearchTests {
    @Test func searchesCompressedRecordings() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tether-zs-\(UUID()).ttylog")
        try Data("first\r\nthe \u{1b}[1mneedle\u{1b}[0m line\r\nlast\r\n".utf8).write(to: url)
        let z = try RecordingCompression.compress(url)
        defer { try? FileManager.default.removeItem(at: z) }
        let source = SearchSource(id: "z", kind: .recording(url: z, archiveID: nil), title: "t", host: "h", date: nil, status: "")
        var events: [String] = []
        for try await e in SearchEngine.events(SearchQuery(pattern: "needle"), in: [source]) {
            switch e {
            case .searching: events.append("searching")
            case .found(let p): events.append("found:" + p.matches.map(\.text).joined())
            }
        }
        #expect(events == ["searching", "found:the needle line"])
    }
}
