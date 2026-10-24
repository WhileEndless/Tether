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
}

public extension TerminalSink {
    func screenTail(maxRows: Int) -> (lines: [String], lastRow: Int)? { nil }
    var hasRealSize: Bool { true }
}
