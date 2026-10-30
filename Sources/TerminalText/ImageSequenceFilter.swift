/// Stricter handling of Kitty image sequences: an image is taken only with its data inline (`t=d`,
/// the default). A transmission of another kind (`t=f`, `t=t`, `t=s`) is given one the terminal
/// does not take (`t=x`, answered "not supported"). Nothing else changes, and the length stays the
/// same (positions in a recording still match); a sequence split across chunks is held until its
/// keys are complete.
public struct ImageSequenceFilter: Sendable {
    private enum State: Sendable { case normal, escape, head }
    private var state: State = .normal
    /// `ESC _ G` and the keys after it, until the payload (`;`) or the end.
    private var head: [UInt8] = []

    public init() {}

    public mutating func filter(_ input: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        if state == .normal, !Self.mayHoldOne(input) { return input }
        var out: [UInt8] = []
        out.reserveCapacity(input.count + head.count)
        for b in input {
            switch state {
            case .normal:
                if b == 0x1b { state = .escape } else { out.append(b) }   // an ESC is held until the next byte
            case .escape:
                if b == 0x5f { // '_': an application program command, held while its keys come
                    head = [0x1b, 0x5f]
                    state = .head
                } else {
                    out.append(0x1b)
                    if b != 0x1b { out.append(b); state = .normal }
                }
            case .head:
                head.append(b)
                if head.count == 3, b != 0x47 { // not 'G': not an image
                    out.append(contentsOf: head)
                    head.removeAll(keepingCapacity: true)
                    state = .normal
                } else if b == 0x3b || b == 0x1b || b == 0x18 || b == 0x1a || head.count >= 1024 {
                    if b == 0x1b { head.removeLast() }   // held again: it may start the end (ESC \)
                    Self.neutralize(&head)
                    out.append(contentsOf: head)
                    head.removeAll(keepingCapacity: true)
                    state = b == 0x1b ? .escape : .normal
                }
            }
        }
        return out[...]
    }

    /// What is still held (the end of a stream, or of a whole recording read at once).
    public mutating func flush() -> [UInt8] {
        defer { head.removeAll(); state = .normal }
        switch state {
        case .head: Self.neutralize(&head); return head
        case .escape: return [0x1b]
        case .normal: return []
        }
    }

    /// The bytes with every such transmission changed (same length).
    public static func filtered(_ data: [UInt8]) -> [UInt8] {
        var f = ImageSequenceFilter()
        if !mayHoldOne(data[...]) { return data }
        return Array(f.filter(data[...])) + f.flush()
    }

    /// Changes `t=f`, `t=t` or `t=s` among the keys of `ESC _ G a=T,t=f…` to `t=x`.
    static func neutralize(_ head: inout [UInt8]) {
        var i = 3
        while i + 2 < head.count {
            if head[i] == 0x74, head[i + 1] == 0x3d, head[i - 1] == 0x47 || head[i - 1] == 0x2c,
               [0x66, 0x74, 0x73].contains(head[i + 2]) {
                head[i + 2] = 0x78
            }
            i += 1
        }
    }

    /// Holds `ESC _`, or ends with ESC (the rest may come in the next chunk).
    static func mayHoldOne(_ input: ArraySlice<UInt8>) -> Bool {
        guard let last = input.last else { return false }
        if last == 0x1b { return true }
        var i = input.startIndex
        while i + 1 < input.endIndex {
            if input[i] == 0x1b, input[i + 1] == 0x5f { return true }
            i += 1
        }
        return false
    }
}
