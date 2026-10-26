import AppKit
import Testing
import TerminalUI

/// Tab numbers show only while ⌘ alone is held in the active app, so they cannot stay after ⌘Tab.
@Suite struct TabNumberHoldTests {
    @Test func onlyCommandAloneInTheActiveApp() {
        #expect(TabNumberHold.shows(flags: [.command], appActive: true))
        #expect(TabNumberHold.shows(flags: [.command, .capsLock, .numericPad], appActive: true))   // not chord keys
        #expect(!TabNumberHold.shows(flags: [.command], appActive: false))                      // ⌘Tab away
        #expect(!TabNumberHold.shows(flags: [.command, .shift], appActive: true))
        #expect(!TabNumberHold.shows(flags: [.command, .option], appActive: true))
        #expect(!TabNumberHold.shows(flags: [], appActive: true))
    }
}
