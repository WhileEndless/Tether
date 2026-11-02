import Foundation
import Testing
import TetherCore
@testable import MonitorKit

/// Sessions on a server are listed under the host one by one: those tabs closed on this Mac left
/// running first, then Tether's other detached sessions (each the most recently used first), then
/// the rest as the server lists them. What the server says is bounded and made safe to show.
@Suite struct ServerSessionOrderTests {
    private func entry(_ name: String, attached: Bool = false, used: TimeInterval? = nil) -> RemoteSessionEntry {
        RemoteSessionEntry(kind: .tmux, name: name, created: Date(timeIntervalSince1970: 1_000),
                           attached: attached, lastActivity: used.map { Date(timeIntervalSince1970: $0) })
    }

    @Test func thisMacsComeFirstThenOtherTetherSessions() {
        let list = [entry("work"), entry("tether-aaaa1111", used: 2_000), entry("tether-bbbb2222", attached: true, used: 9_000),
                    entry("tether-cccc3333", used: 5_000), entry("main"), entry("tether-dddd4444"), entry("tether-eeee5555", used: 3_000)]
        let mine: Set = ["tether-dddd4444", "tether-eeee5555"]
        #expect(RemoteSessionEntry.listOrder(list) { mine.contains($0.name) }.map(\.name)
                == ["tether-eeee5555", "tether-dddd4444", "tether-cccc3333", "tether-aaaa1111", "work", "tether-bbbb2222", "main"])
    }

    @Test func nothingIsLeftOutOrAdded() {
        let list = (0..<20).map { entry($0.isMultiple(of: 3) ? "own-\($0)" : String(format: "tether-%08x", $0), attached: $0 == 5, used: Double($0 % 7)) }
        let ordered = RemoteSessionEntry.listOrder(list) { $0.name.hasSuffix("2") }
        #expect(Set(ordered.map(\.id)) == Set(list.map(\.id)))
        #expect(ordered.count == list.count)
    }

    /// Only Tether's own names count as Tether's: a session someone named "tether-…" by hand is theirs.
    @Test func tetherNamesAreExact() {
        #expect(RemoteSessionEntry.isTetherName("tether-0a1b2c3d"))
        #expect(!RemoteSessionEntry.isTetherName("tether-0A1B2C3D"))
        #expect(!RemoteSessionEntry.isTetherName("tether-0a1b2c3"))
        #expect(!RemoteSessionEntry.isTetherName("tether-0a1b2c3d4"))
        #expect(!RemoteSessionEntry.isTetherName("tether-build"))
        #expect(!RemoteSessionEntry.isTetherName("tether-"))
    }

    @Test func textFromTheServerIsMadeSafeToShow() {
        // Bidirectional overrides and zero-width characters could make one name pass for another.
        #expect(DisplayText.clean("abc\u{202E}fdp.exe") == "abcfdp.exe")
        #expect(DisplayText.clean("a\u{200B}b\u{2066}c\u{FEFF}") == "abc")
        #expect(DisplayText.clean("one\ntwo\r\tthree\u{1B}[31m") == "one two three [31m")
        #expect(DisplayText.clean("👩‍💻 work") == "👩‍💻 work", "emoji joiners stay")
        let long = DisplayText.clean(String(repeating: "x", count: 10_000), limit: 50)
        #expect(long.count == 51 && long.hasSuffix("…"))
        // Cut between characters, never inside one.
        #expect(DisplayText.clean(String(repeating: "👩‍💻", count: 10), limit: 3) == "👩‍💻👩‍💻👩‍💻…")
        #expect(DisplayText.clean("می\u{200C}خواهم") == "می\u{200C}خواهم", "the non-joiner stays")
        #expect(DisplayText.clean("\u{3164}\u{3164}") == "", "fillers that draw nothing go")
    }

    @Test func aHugeOrHostileListIsBounded() {
        var text = "@@tmux\n"
        for i in 0..<2_000 { text += String(format: "tether-%08x|1000|0|1|1000\n", i) }
        text += String(repeating: "n", count: 1_000) + "|1000|0|1|1000\n"          // too long a name
        text += "tether-0000abcd|1000|0|1|1000\ntether-0000abcd|1000|0|1|1000\n"    // twice
        text += "@@tmuxpanes\n"
        for i in 0..<300 { text += "tether-00000000|\(i)|win\u{202E}dow|1|1|%\(i)|/dev/pts/1|vim|/srv\n" }
        text += "@@end\n"
        let list = ProbeParser.remoteSessions(text)
        #expect(list.count == ProbeParser.SessionLimits.sessions)
        #expect(Set(list.map(\.id)).count == list.count)
        #expect(!list.contains { $0.name.count > ProbeParser.SessionLimits.nameLength })
        let first = list.first { $0.name == "tether-00000000" }
        #expect(first?.panes.count == ProbeParser.SessionLimits.panesPerSession)
        #expect(first?.panes.first?.windowName == "window")
    }
}
