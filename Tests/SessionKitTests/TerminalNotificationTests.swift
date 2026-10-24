import Foundation
import Testing
@testable import SessionKit

/// The notification sequences programs send (Claude Code, builds, `printf '\e]9;done\a'`).
@Suite struct TerminalNotificationTests {
    func parse(_ code: Int, _ text: String, _ parser: inout TerminalNotificationParser) -> TerminalNotification? {
        parser.parse(code: code, payload: Array(text.utf8))
    }

    @Test func iTermStyleOSC9() {
        var p = TerminalNotificationParser()
        #expect(parse(9, "Claude is waiting for your input", &p) == TerminalNotification(body: "Claude is waiting for your input"))
        // ConEmu commands share the number: a progress bar is no notification.
        #expect(parse(9, "4;1;50", &p) == nil)
        #expect(parse(9, "4", &p) == nil)
        #expect(parse(9, "", &p) == nil)
    }

    @Test func rxvtStyleOSC777() {
        var p = TerminalNotificationParser()
        #expect(parse(777, "notify;Claude Code;Task finished; all tests pass", &p)
                == TerminalNotification(title: "Claude Code", body: "Task finished; all tests pass"))
        #expect(parse(777, "notify;Only a title", &p) == TerminalNotification(body: "Only a title"))
        #expect(parse(777, "preexec", &p) == nil)
    }

    @Test func kittyOSC99WithPartsAndBase64() {
        var p = TerminalNotificationParser()
        #expect(parse(99, ";Hello", &p) == TerminalNotification(body: "Hello"))
        #expect(parse(99, "i=1:d=0;Build", &p) == nil)
        #expect(parse(99, "i=1:p=body:e=1;" + Data("done in 3 min".utf8).base64EncodedString(), &p)
                == TerminalNotification(title: "Build", body: "done in 3 min"))
        #expect(parse(99, "i=2:p=?;", &p) == nil)        // a capability query, not shown
    }

    /// Text from a server is shown as plain, short text: no escape sequences, no control characters.
    @Test func textIsCleaned() {
        var p = TerminalNotificationParser()
        let n = parse(9, "bad\u{1b}[31m red\u{7}\u{9b}x" + String(repeating: "y", count: 400), &p)
        #expect(n?.body.hasPrefix("bad[31m redx") == true)
        #expect(n?.body.count == 240)
        #expect(n?.body.unicodeScalars.contains { $0.value < 0x20 } == false)
    }
}
