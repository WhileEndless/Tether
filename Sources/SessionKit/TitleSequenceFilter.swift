import Foundation

/// Removes screen/tmux "set window name" sequences (`ESC k <name> ESC \`) from a byte stream.
///
/// Shells (e.g. oh-my-zsh) emit these when they detect tmux or screen. A real tmux client consumes
/// them, but tmux control mode forwards the raw pane output, so a terminal emulator would print the
/// name as text (the command appearing again on the next line). The names are reported instead
/// and used as tab titles.
public struct TitleSequenceFilter: Sendable {
    private enum State: Sendable { case normal, escape, title, titleEscape }
    private var state: State = .normal
    private var title: [UInt8] = []

    public init() {}

    /// Filters a chunk. Returns the bytes to display and the last complete title, if any.
    public mutating func filter(_ input: [UInt8]) -> (output: [UInt8], title: String?) {
        if state == .normal, !input.contains(0x1b) { return (input, nil) }
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var found: String?
        for b in input {
            switch state {
            case .normal:
                if b == 0x1b { state = .escape } else { out.append(b) }
            case .escape:
                if b == 0x6b { // 'k'
                    state = .title
                    title.removeAll(keepingCapacity: true)
                } else {
                    out.append(0x1b)
                    if b == 0x1b { continue } // stay in .escape for ESC ESC
                    out.append(b)
                    state = .normal
                }
            case .title:
                if b == 0x1b { state = .titleEscape }
                else if b == 0x07 { found = finish() }
                else if title.count < 256 { title.append(b) }
            case .titleEscape:
                if b == 0x5c { found = finish() } // ESC \ terminates
                else { title.append(0x1b); title.append(b); state = .title }
            }
        }
        return (out, found)
    }

    private mutating func finish() -> String {
        state = .normal
        return String(decoding: title, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
