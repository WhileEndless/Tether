import Foundation

/// What a session needs from the terminal view that displays it.
@MainActor
public protocol TerminalSink: AnyObject {
    /// Displays bytes as if they came from the remote program.
    func feed(_ bytes: ArraySlice<UInt8>)
    /// Current size in character cells.
    var cellSize: (cols: Int, rows: Int) { get }
}
