import Foundation

/// Converts raw terminal output (with escape sequences, carriage returns and backspaces) into the
/// plain text lines a person saw. Works incrementally so large recordings can be streamed.
public struct PlainTextConverter {
    private enum State { case text, escape, csi, osc, oscEscape, string, stringEscape }
    private var state: State = .text
    private var line: [UInt8] = []
    /// Set after a bare carriage return: the next printable character starts the line again.
    private var pendingCR = false

    public init() {}

    /// Feeds bytes; returns completed lines.
    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [String] {
        var out: [String] = []
        for b in bytes {
            switch state {
            case .text:
                switch b {
                case 0x1b: state = .escape
                case 0x0a:
                    out.append(finishLine())
                case 0x0d: pendingCR = true
                case 0x08: if !line.isEmpty { line.removeLast() }
                case 0x09: put(0x09)
                case 0..<0x20, 0x7f: break
                default: put(b)
                }
            case .escape:
                switch b {
                case 0x5b: state = .csi                    // [
                case 0x5d: state = .osc                    // ]
                case 0x50, 0x58, 0x5e, 0x5f, 0x6b: state = .string // P X ^ _ k
                default: state = .text                     // two-byte sequence
                }
            case .csi:
                if (0x40...0x7e).contains(b) {
                    // Erase-in-line / clear screen do not affect the text history we keep.
                    state = .text
                }
            case .osc:
                if b == 0x07 { state = .text } else if b == 0x1b { state = .oscEscape }
            case .oscEscape:
                state = b == 0x5c ? .text : .osc
            case .string:
                if b == 0x1b { state = .stringEscape } else if b == 0x07 { state = .text }
            case .stringEscape:
                state = b == 0x5c ? .text : .string
            }
        }
        return out
    }

    /// Returns the last unterminated line, if any.
    public mutating func finish() -> String? {
        line.isEmpty ? nil : finishLine()
    }

    private mutating func put(_ b: UInt8) {
        if pendingCR {
            // A carriage return without a newline overwrites the line (progress bars, prompts).
            line.removeAll(keepingCapacity: true)
            pendingCR = false
        }
        line.append(b)
    }

    private mutating func finishLine() -> String {
        pendingCR = false
        let s = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        return s.replacingOccurrences(of: "\u{FFFD}", with: "")
    }

    /// Converts a whole buffer at once.
    public static func lines(from data: Data) -> [String] {
        var c = PlainTextConverter()
        var lines = c.feed(data)
        if let last = c.finish() { lines.append(last) }
        return lines
    }
}
