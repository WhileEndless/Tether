import Foundation
import Testing
@testable import SearchKit

/// Recordings are searched line by line as they are read: the same matches, with the same
/// context, as searching all the lines at once.
struct LineMatcherTests {
    @Test func matchingLineByLineEqualsMatchingAllLines() throws {
        let lines = (0..<500).map { i in i % 7 == 0 ? "error \(i) here" : "line \(i)" }
        let regex = try NSRegularExpression(pattern: "error")
        for context in [0, 1, 3] {
            for limit in [5, 1000] {
                let whole = SearchEngine.match(lines, sourceID: "s", regex: regex, context: context, limit: limit)
                var matcher = SearchEngine.LineMatcher(sourceID: "s", regex: regex, context: context, limit: limit)
                for line in lines where matcher.add(line) {}
                let streamed = matcher.finish()
                #expect(streamed.map(\.line) == whole.map(\.line))
                #expect(streamed.map(\.before) == whole.map(\.before))
                #expect(streamed.map(\.after) == whole.map(\.after))
            }
        }
    }

    /// The held end of a text gives lines back in order and keeps exactly `hold` of them.
    @Test func heldTailKeepsOrder() {
        var tail = SeamTail(hold: 1_000, memoryHead: [])
        var released: [String] = []
        for i in 0..<10_000 { tail.push("\(i)") { released.append($0.line); return true } }
        #expect(released == (0..<9_000).map { "\($0)" })
        #expect(tail.rest.first?.line == "9000" && tail.rest.count == 1_000)
    }
}
