import Foundation
import Testing
@testable import TmuxControl

@Suite struct TmuxParserPerformanceTests {
    /// Heavy output (e.g. `cat` of a big file) must parse in linear time.
    @Test func parsesTenMegabytesQuickly() {
        var parser = TmuxControlParser()
        _ = parser.feed(Array("\u{1b}P1000p".utf8))
        let line = Array("%output %1 0123456789abcdefghijklmnopqrstuvwxyz0123456789abcdefghij\\015\\012\n".utf8)
        var chunk: [UInt8] = []
        for _ in 0..<2000 { chunk += line }          // ~160 KB per chunk, like a pty read burst
        let start = Date()
        var bytes = 0
        for _ in 0..<64 {                               // ~10 MB total
            for e in parser.feed(chunk) { if case .output(_, let d) = e { bytes += d.count } }
        }
        let elapsed = Date().timeIntervalSince(start)
        print("PARSE 10MB: \(elapsed)s")
        #expect(bytes > 7_000_000)
        #expect(elapsed < 2.0)
    }
}
