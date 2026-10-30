import Foundation
import TetherCore

/// OSC 7501, the Program Status Protocol: a program (Claude Code 2.1.295 and later) says whether it
/// is working, blocked on the user, done or idle. The program first asks whether the terminal
/// understands it (`OSC 7501 ; ? ST`); Tether answers, then gets an update on every change:
/// `OSC 7501 ; state=blocked:kind=question:msg=<base64> ST`.
public enum ProgramStatus: Equatable, Sendable {
    case query
    case update(state: String, kind: String?, message: String?, app: String?)

    /// The terminal's answer to the query: the states and kinds it shows.
    public static let reply = Array("\u{1b}]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u{1b}\\".utf8)

    public static func parse(_ payload: [UInt8]) -> ProgramStatus? {
        let text = String(decoding: payload, as: UTF8.self)
        if text == "?" || text.hasPrefix("?:") { return .query }
        var fields: [String: String] = [:]
        for part in text.split(separator: ":") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { fields[kv[0]] = kv[1] }
        }
        guard let state = fields["state"], !state.isEmpty else { return nil }
        // Records below the root (`id=…`, a program's sub-tasks) are not shown on the tab.
        if let id = fields["id"], !id.isEmpty { return nil }
        func decoded(_ key: String) -> String? {
            guard let b64 = fields[key], let data = Data(base64Encoded: b64) else { return nil }
            let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : String(s.prefix(200))
        }
        return .update(state: state, kind: fields["kind"], message: decoded("msg") ?? decoded("title"), app: fields["app"])
    }

    /// What the update means for the tab (nil: nothing to show, e.g. `clear`).
    public var activity: AgentActivity? {
        guard case .update(let state, let kind, let message, _) = self else { return nil }
        switch state {
        case "working": return .working
        case "blocked": return .waiting(message ?? Self.describe(kind))
        case "done": return .done
        case "idle", "error": return .idle
        default: return nil
        }
    }

    static func describe(_ kind: String?) -> String {
        switch kind {
        case "permission": "needs your permission"
        case "question": "has a question"
        case "auth": "needs you to sign in"
        default: "is waiting for you"
        }
    }
}

/// Unwraps tmux passthrough (`ESC P tmux ; … ESC \`, with every ESC inside doubled), which programs
/// in tmux use to reach the outer terminal — notifications (OSC 9/777/99) and OSC 7501 then work in
/// tmux tabs too. A wrapper cut across chunks is held back until it ends (at most 64 KB).
public struct TmuxPassthrough {
    private var held: [UInt8] = []
    private static let start = Array("\u{1b}Ptmux;".utf8)
    static let limit = 64 * 1024

    public init() {}

    public mutating func filter(_ bytes: [UInt8]) -> [UInt8] {
        // Nearly every chunk: nothing held and no `ESC P` in it — passed on without copying.
        if held.isEmpty, !Self.holdsDCS(bytes), Self.partialStart(bytes) == nil { return bytes }
        var input = held + bytes
        held = []
        guard input.count >= 2, Self.find(Self.start, in: input, from: 0) != nil || Self.partialStart(input) != nil else { return input }
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var i = 0
        while i < input.count {
            if let s = Self.find(Self.start, in: input, from: i) {
                out += input[i..<s]
                var j = s + Self.start.count
                var inner: [UInt8] = []
                var ended = false
                while j < input.count {
                    if input[j] == 0x1b, j + 1 < input.count {
                        if input[j + 1] == 0x1b { inner.append(0x1b); j += 2; continue }
                        if input[j + 1] == 0x5c { j += 2; ended = true; break }      // ESC \ ends it
                    } else if input[j] == 0x1b {
                        break                                                    // cut after an ESC
                    }
                    inner.append(input[j]); j += 1
                }
                if !ended {
                    if input.count - s <= Self.limit { held = Array(input[s...]); return out }
                    out += input[s...]                                           // too long: as it was
                    return out
                }
                out += inner
                i = j
            } else {
                if let p = Self.partialStart(input), p >= i { out += input[i..<p]; held = Array(input[p...]); return out }
                out += input[i...]
                break
            }
        }
        input = []
        return out
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
        var i = from
        while i <= hay.count - needle.count {
            if hay[i] == needle[0], hay[i..<(i + needle.count)].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }

    private static func holdsDCS(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer { b in
            var i = 0
            while i + 1 < b.count {
                if b[i] == 0x1b, b[i + 1] == 0x50 { return true }
                i += 1
            }
            return false
        }
    }

    /// Where the end of `bytes` may be the start of a wrapper cut short (`ESC`, `ESC P t`, …).
    private static func partialStart(_ bytes: [UInt8]) -> Int? {
        for n in stride(from: min(start.count - 1, bytes.count), through: 1, by: -1) {
            if bytes.suffix(n).elementsEqual(start.prefix(n)) { return bytes.count - n }
        }
        return nil
    }
}

/// Whether a tab's command is doing something worth a "working" mark, or just open (vim, less,
/// a quiet `tail -f`, a REPL), or the shell is at its prompt.
public enum TabActivity: Equatable, Sendable {
    case idle
    case quiet
    case working(String)

    /// - Parameters:
    ///   - running: the command watcher's view (nil when unknown: no watcher for the host).
    ///   - foreground: the foreground program's name, as a fallback when `running` is unknown.
    ///   - outputActive: output arrived recently (not the echo of typing).
    ///   - cpu: the command's CPU use in % of one core (nil until measured).
    ///   - io: network and disk bytes per second of the command (nil until measured).
    public static func decide(running: Bool?, foreground: String?, outputActive: Bool, cpu: Double?, io: Double?,
                              cpuThreshold: Double = 5, ioThreshold: Double = 20_000) -> TabActivity {
        let runs = running ?? foreground.map { !$0.isEmpty && !ShellNames.contains($0) } ?? false
        guard runs else { return .idle }
        if outputActive { return .working("output") }
        if let cpu, cpu.isFinite, cpu >= cpuThreshold { return .working("\(Int(cpu.rounded())) % CPU") }
        if let io, io >= ioThreshold { return .working("network or disk") }
        return .quiet
    }
}
