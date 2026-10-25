/// Whether a stream of terminal output stands between escape sequences (so something can be put in
/// there, such as a `SizeMarker`, without cutting a sequence in two).
public struct EscapeState: Sendable {
    private enum State: Sendable { case text, escape, csi, string, stringEscape }
    private var state = State.text

    public init() {}

    /// Inside an escape sequence at the end of what was fed.
    public var isInside: Bool { state != .text }

    public mutating func feed(_ bytes: some Sequence<UInt8>) {
        for b in bytes {
            switch state {
            case .text:
                if b == 0x1b { state = .escape }
            case .escape:
                switch b {
                case 0x5b: state = .csi                                   // [
                case 0x5d, 0x50, 0x58, 0x5e, 0x5f: state = .string        // ] P X ^ _
                case 0x20...0x2f: break                                   // intermediates (ESC ( B)
                default: state = .text
                }
            case .csi:
                if (0x40...0x7e).contains(b) { state = .text }
            case .string:
                if b == 0x07 { state = .text } else if b == 0x1b { state = .stringEscape }
            case .stringEscape:
                state = b == 0x5c ? .text : .string
            }
        }
    }
}
