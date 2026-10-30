import AppKit
import SwiftTerm
import TerminalText

extension TerminalView {
    /// Feeds output like Terminal.app: clearing the screen (Ctrl+L, `clear`) first moves the visible
    /// lines into the scrollback, so nothing is lost, and output cannot erase the scrollback (ESC[3J).
    /// A clear is `ESC[2J`, or — as shells inside tmux and screen send it — `ESC[J` with the cursor
    /// at the top left (after `ESC[H`). Full-screen programs on the alternate screen are left alone.
    func feedKeepingScrollback(_ bytes: ArraySlice<UInt8>, programsMayClear: Bool = false, cleared: (() -> Void)? = nil) {
        ScrollbackRule.feed(bytes, terminal: getTerminal(), programsMayClear: programsMayClear, cleared: cleared) { feed(byteArray: $0) }
    }

    /// The same for output that comes in pieces (see `ScrollbackRule.Context`).
    func feedKeepingScrollback(_ bytes: ArraySlice<UInt8>, programsMayClear: Bool, context: inout ScrollbackRule.Context,
                               cleared: (() -> Void)? = nil) {
        ScrollbackRule.feed(bytes, terminal: getTerminal(), programsMayClear: programsMayClear, context: &context,
                            cleared: cleared) { feed(byteArray: $0) }
    }

    /// The next erase-in-display (see `ScrollbackRule.findErase`).
    static func findErase(in bytes: ArraySlice<UInt8>) -> (Range<Int>, UInt8)? {
        ScrollbackRule.findErase(in: bytes)
    }
}
