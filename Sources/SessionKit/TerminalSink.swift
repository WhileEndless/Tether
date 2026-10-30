import Foundation

/// What a session needs from the terminal view that displays it.
@MainActor
public protocol TerminalSink: AnyObject {
    /// Displays bytes as if they came from the remote program.
    func feed(_ bytes: ArraySlice<UInt8>)
    /// Current size in character cells.
    var cellSize: (cols: Int, rows: Int) { get }
    /// Whether `cellSize` is the view's real size. A terminal that was never laid out (a tab in the
    /// background after a restart) still has the emulator's default size, which must never be
    /// sent to the server: programs there would redraw at 80x24 and again at the real size.
    var hasRealSize: Bool { get }
    /// The last used rows of the main screen as plain text (up to `maxRows`) and the row of the last
    /// one; nil while a full-screen program uses the alternate screen or the screen is empty.
    func screenTail(maxRows: Int) -> (lines: [String], lastRow: Int)?
    /// The cursor's row on the main screen (the rows `screenTail` counts); nil while a full-screen
    /// program uses the alternate screen.
    func screenCursorRow() -> Int?
    /// Shows output from an earlier run (a restored tab's recording): only drawn — terminal queries
    /// in it are not answered, and titles, folders, bells and clipboard copies in it do nothing.
    func showEarlierOutput(_ bytes: ArraySlice<UInt8>)
    /// The earlier output shown is only the end of a longer recording (more is there to scroll
    /// back and find into).
    func earlierOutputIsPartial()
    /// Tether redraws the screen itself now (a re-attach putting back what tmux has): the clear
    /// that comes with it keeps what is on screen.
    func screenWillBeRedrawn()
    /// A command typed while the connection was away was sent now: it is marked where the cursor
    /// is (as a command typed now is when Return is pressed).
    func heldCommandSent()
}

public extension TerminalSink {
    func screenTail(maxRows: Int) -> (lines: [String], lastRow: Int)? { nil }
    func screenCursorRow() -> Int? { nil }
    var hasRealSize: Bool { true }
    func showEarlierOutput(_ bytes: ArraySlice<UInt8>) { feed(bytes) }
    func heldCommandSent() {}
    func earlierOutputIsPartial() {}
    func screenWillBeRedrawn() {}
}
