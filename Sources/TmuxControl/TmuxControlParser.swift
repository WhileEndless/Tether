import Foundation

/// Events produced by `TmuxControlParser`.
public enum TmuxEvent: Equatable, Sendable {
    /// Bytes received before tmux entered control mode (e.g. shell noise or errors).
    case passthrough([UInt8])
    /// Control mode started (DCS `ESC P 1000 p` seen).
    case enteredControlMode
    /// Output for a pane.
    case output(pane: String, data: [UInt8])
    /// Reply to a command: the lines between %begin and %end/%error.
    case commandReply(number: Int, success: Bool, lines: [[UInt8]])
    /// tmux is detaching or the session ended.
    case exit(reason: String?)
    /// Any other notification (%session-changed, %window-add, %layout-change, ...).
    case notification(name: String, arguments: String)
    /// The control mode DCS was terminated (ST received).
    case leftControlMode
}

/// Incremental parser for tmux control mode (`tmux -CC`).
///
/// Protocol reference: tmux(1), section "CONTROL MODE".
public struct TmuxControlParser: Sendable {
    private static let dcsStart: [UInt8] = [0x1b, 0x50, 0x31, 0x30, 0x30, 0x30, 0x70] // ESC P 1000 p
    private static let st: [UInt8] = [0x1b, 0x5c]                                        // ESC \

    public private(set) var inControlMode = false
    private var buffer: [UInt8] = []
    private var block: (number: Int, lines: [[UInt8]])?

    public init() {}

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [TmuxEvent] {
        buffer.append(contentsOf: bytes)
        var events: [TmuxEvent] = []
        while true {
            if !inControlMode {
                if let r = Self.find(Self.dcsStart, in: buffer) {
                    if r.lowerBound > 0 { events.append(.passthrough(Array(buffer[..<r.lowerBound]))) }
                    buffer.removeSubrange(..<r.upperBound)
                    inControlMode = true
                    events.append(.enteredControlMode)
                    continue
                }
                // Keep a possible partial DCS prefix at the end, pass the rest through.
                let keep = Self.partialSuffixLength(of: buffer, matching: Self.dcsStart)
                if buffer.count > keep {
                    events.append(.passthrough(Array(buffer[..<(buffer.count - keep)])))
                    buffer.removeSubrange(..<(buffer.count - keep))
                }
                return events
            }

            // Control mode: ST at the start of a line ends it.
            if buffer.starts(with: Self.st) {
                buffer.removeSubrange(..<2)
                inControlMode = false
                block = nil
                events.append(.leftControlMode)
                continue
            }
            guard let nl = buffer.firstIndex(of: 0x0a) else { return events }
            var line = Array(buffer[..<nl])
            buffer.removeSubrange(...nl)
            if line.last == 0x0d { line.removeLast() }
            // Some terminals echo stray CRs before the line; drop leading CRs.
            while line.first == 0x0d { line.removeFirst() }
            if let e = handle(line: line) { events.append(e) }
        }
    }

    private mutating func handle(line: [UInt8]) -> TmuxEvent? {
        if var b = block {
            if line.starts(with: Array("%end ".utf8)) || line.starts(with: Array("%error ".utf8)) {
                let parts = String(decoding: line, as: UTF8.self).split(separator: " ")
                if parts.count >= 3, Int(parts[2]) == b.number {
                    block = nil
                    return .commandReply(number: b.number, success: parts[0] == "%end", lines: b.lines)
                }
            }
            b.lines.append(line)
            block = b
            return nil
        }

        guard line.first == 0x25 /* % */ else { return nil }
        let spaceIndex = line.firstIndex(of: 0x20) ?? line.endIndex
        let name = String(decoding: line[1..<spaceIndex], as: UTF8.self)
        let rest = spaceIndex < line.endIndex ? Array(line[(spaceIndex + 1)...]) : []

        switch name {
        case "begin":
            let parts = String(decoding: rest, as: UTF8.self).split(separator: " ")
            block = (parts.count >= 2 ? Int(parts[1]) ?? -1 : -1, [])
            return nil
        case "output":
            guard let sp = rest.firstIndex(of: 0x20) else { return nil }
            let pane = String(decoding: rest[..<sp], as: UTF8.self)
            return .output(pane: pane, data: Self.unescape(rest[(sp + 1)...]))
        case "extended-output":
            // %extended-output %pane age ... : data
            let s = rest
            guard let sp = s.firstIndex(of: 0x20) else { return nil }
            let pane = String(decoding: s[..<sp], as: UTF8.self)
            guard let colon = Self.find([0x20, 0x3a, 0x20], in: Array(s))?.upperBound else { return nil }
            return .output(pane: pane, data: Self.unescape(s[colon...]))
        case "exit":
            let reason = String(decoding: rest, as: UTF8.self)
            return .exit(reason: reason.isEmpty ? nil : reason)
        default:
            return .notification(name: name, arguments: String(decoding: rest, as: UTF8.self))
        }
    }

    /// Decodes tmux's octal escaping (`\ooo`) used in %output lines.
    public static func unescape(_ bytes: some Collection<UInt8>) -> [UInt8] {
        let a = Array(bytes)
        var out: [UInt8] = []
        out.reserveCapacity(a.count)
        var i = 0
        while i < a.count {
            if a[i] == 0x5c, i + 3 < a.count,
               let v = octal(a[i + 1], a[i + 2], a[i + 3]) {
                out.append(v)
                i += 4
            } else {
                out.append(a[i])
                i += 1
            }
        }
        return out
    }

    private static func octal(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8? {
        func d(_ x: UInt8) -> Int? { (0x30...0x37).contains(x) ? Int(x - 0x30) : nil }
        guard let x = d(a), let y = d(b), let z = d(c) else { return nil }
        let v = x * 64 + y * 8 + z
        return v <= 255 ? UInt8(v) : nil
    }

    static func find(_ needle: [UInt8], in hay: [UInt8]) -> Range<Int>? {
        guard needle.count <= hay.count else { return nil }
        var i = 0
        while i + needle.count <= hay.count {
            if hay[i] == needle[0], Array(hay[i..<(i + needle.count)]) == needle { return i..<(i + needle.count) }
            i += 1
        }
        return nil
    }

    /// Length of the longest suffix of `buffer` that is a proper prefix of `needle`.
    static func partialSuffixLength(of buffer: [UInt8], matching needle: [UInt8]) -> Int {
        var n = min(needle.count - 1, buffer.count)
        while n > 0 {
            if Array(buffer.suffix(n)) == Array(needle.prefix(n)) { return n }
            n -= 1
        }
        return 0
    }
}
