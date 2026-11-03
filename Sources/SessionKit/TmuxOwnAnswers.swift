import Foundation

/// In a tmux tab, a program's questions to the terminal (who are you, where is the cursor, which
/// modes) reach Tether in the pane's output, but tmux answers them itself at once, or keeps them
/// from the outer terminal as it does for every client. Tether's own answers would go in as typed
/// input through `send-keys`, a network round trip later: a second, late answer the program has
/// stopped waiting for. A program that has left raw mode meanwhile (Claude Code between its probe
/// and its screen) gets them echoed on its terminal as text such as `^[[?65;4;1;2;6;21;22;17;28c`.
///
/// This strips those answers from what the terminal sends by itself in a tmux tab. Mouse and focus
/// reports, colour answers (OSC) and everything else pass unchanged.
public enum TmuxOwnAnswers {
    /// `bytes` without the answers tmux gives (or keeps from) its panes itself.
    public static func strip(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        guard bytes.contains(0x1b) else { return bytes }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        while i < bytes.endIndex {
            guard bytes[i] == 0x1b, i + 1 < bytes.endIndex else { out.append(bytes[i]); i += 1; continue }
            switch bytes[i + 1] {
            case 0x5b:                                                      // ESC [  (CSI)
                if let end = csiEnd(bytes, from: i + 2) {
                    if !isAnswer(csi: bytes[(i + 2)..<end], final: bytes[end]) { out += bytes[i...end] }
                    i = end + 1
                    continue
                }
            case 0x50:                                                      // ESC P  (DCS)
                if let end = stringEnd(bytes, from: i + 2) {
                    if !isAnswer(dcs: bytes[(i + 2)...]) { out += bytes[i..<end] }
                    i = end
                    continue
                }
            default: break
            }
            out.append(bytes[i])
            i += 1
        }
        return out[...]
    }

    /// The index of a CSI sequence's final byte (parameters 0x30–0x3F, intermediates 0x20–0x2F).
    private static func csiEnd(_ b: ArraySlice<UInt8>, from start: Int) -> Int? {
        var i = start
        while i < b.endIndex, i - start < 64 {
            let c = b[i]
            if (0x40...0x7e).contains(c) { return i }
            guard (0x20...0x3f).contains(c) else { return nil }
            i += 1
        }
        return nil
    }

    /// Just past the string terminator (`ESC \` or BEL) of a DCS string starting at `start`.
    private static func stringEnd(_ b: ArraySlice<UInt8>, from start: Int) -> Int? {
        var i = start
        while i < b.endIndex, i - start < 4096 {
            if b[i] == 0x07 { return i + 1 }
            if b[i] == 0x1b, i + 1 < b.endIndex, b[i + 1] == 0x5c { return i + 2 }
            i += 1
        }
        return nil
    }

    private static func isAnswer(csi body: ArraySlice<UInt8>, final: UInt8) -> Bool {
        let first = body.first
        let params = body.filter { (0x30...0x3f).contains($0) }
        let intermediates = body.filter { (0x20...0x2f).contains($0) }
        let text = String(decoding: params, as: UTF8.self)
        switch final {
        case UInt8(ascii: "c"):                     // device attributes (DA1 `?`, DA2 `>`, DA3 `=`)
            return first == UInt8(ascii: "?") || first == UInt8(ascii: ">") || first == UInt8(ascii: "=")
        case UInt8(ascii: "y"):                     // mode reports (DECRPM)
            return intermediates == [UInt8(ascii: "$")]
        case UInt8(ascii: "R"):                     // cursor position (row;column); keys never come here
            return first != UInt8(ascii: "?") && intermediates.isEmpty && text.split(separator: ";").count == 2
                && text.allSatisfy { $0.isNumber || $0 == ";" }
        case UInt8(ascii: "n"):                     // device status
            return intermediates.isEmpty && (text == "0" || text == "3")
        case UInt8(ascii: "t"):                     // text area size in characters or pixels
            return intermediates.isEmpty && (text.hasPrefix("8;") || text.hasPrefix("4;"))
        case UInt8(ascii: "u"):                     // keyboard protocol flags
            return first == UInt8(ascii: "?")
        default:
            return false
        }
    }

    private static func isAnswer(dcs body: ArraySlice<UInt8>) -> Bool {
        let start = Array(body.prefix(3))
        if start.starts(with: Array(">|".utf8)) || start.starts(with: Array("!|".utf8)) { return true }   // version, DA3
        return start == Array("1$r".utf8) || start == Array("0$r".utf8)                                   // setting reports
    }
}
