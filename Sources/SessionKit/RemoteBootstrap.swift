import Foundation
import TetherCore

/// Builds the small POSIX shell program that runs on the remote host when a terminal connects.
///
/// It picks a persistence backend that already exists on the host (nothing is installed),
/// announces the choice with a private OSC marker, then `exec`s into it:
///
///     ESC ] 7770 ; mode=tmux;v=3.4 BEL     tmux control mode follows
///     ESC ] 7770 ; mode=screen BEL         GNU screen follows
///     ESC ] 7770 ; mode=plain BEL          a plain login shell follows
///     ESC ] 7770 ; gone BEL                re-attach requested but the session no longer exists
public enum RemoteBootstrap {
    public static let markerPrefix: [UInt8] = Array("\u{1b}]7770;".utf8)

    /// - Parameters:
    ///   - mode: requested persistence. On re-attach pass the backend that was negotiated originally.
    ///   - sessionName: tmux/screen session name.
    ///   - attachOnly: only re-attach; report `gone` instead of creating a new session.
    ///   - size: initial terminal size, so a new tmux session starts at the right size instead of
    ///     80x24 followed by a resize (which makes shells like zsh redraw their prompt).
    ///   - directory: start directory for a new session (ignored when re-attaching).
    public static func command(mode: PersistenceMode, sessionName: String, attachOnly: Bool,
                               size: (cols: Int, rows: Int) = (80, 24), directory: String? = nil) -> String {
        let m: String = switch mode {
        case .auto: "auto"
        case .tmux: "tmux"
        case .screen: "screen"
        case .off: "off"
        }
        // Kept on a single line: some login shells (csh) reject newlines inside quotes.
        let parts = [
            "N=\"$1\"", "M=\"$2\"", "A=\"$3\"", "W=\"$4\"", "H=\"$5\"", "D=\"$6\"",
            "if [ -n \"$D\" ]; then cd \"$D\" 2>/dev/null || D=\"\"; fi",
            "mark() { printf '\\033]7770;%s\\007' \"$1\"; }",
            // tmux >= 3.0 in control mode
            "if [ \"$M\" = auto ] || [ \"$M\" = tmux ]; then if command -v tmux >/dev/null 2>&1; then "
                + "V=$(tmux -V 2>/dev/null | sed 's/^[^0-9]*//;s/[^0-9.].*$//'); MAJ=${V%%.*}; "
                + "if [ \"${MAJ:-0}\" -ge 3 ] 2>/dev/null; then "
                + "if [ \"$A\" = 1 ] && ! tmux has-session -t \"=$N\" 2>/dev/null; then mark gone; exit 0; fi; "
                + "mark \"mode=tmux;v=$V\"; if [ -n \"$D\" ]; then exec tmux -CC new-session -A -s \"$N\" -x \"$W\" -y \"$H\" -c \"$D\"; fi; "
                + "exec tmux -CC new-session -A -s \"$N\" -x \"$W\" -y \"$H\"; "
                + "fi; fi; fi",
            // GNU screen with the alternate screen disabled so local scrollback keeps history
            "if [ \"$M\" = auto ] || [ \"$M\" = screen ]; then if command -v screen >/dev/null 2>&1; then "
                + "if [ \"$A\" = 1 ] && ! screen -ls 2>/dev/null | grep -q \"[.]$N[[:space:]]\"; then mark gone; exit 0; fi; "
                + "R=\"${TMPDIR:-/tmp}/.tether-screenrc-$(id -u)\"; "
                + "printf 'termcapinfo xterm* ti@:te@\\ndefscrollback 10000\\nstartup_message off\\nvbell off\\n' > \"$R\" 2>/dev/null; "
                + "mark mode=screen; exec screen -c \"$R\" -D -RR -S \"$N\"; "
                + "fi; fi",
            // Plain shell: nothing survives a disconnect, so a re-attach always reports gone.
            "if [ \"$A\" = 1 ]; then mark gone; exit 0; fi",
            "mark mode=plain",
            "exec \"${SHELL:-/bin/sh}\" -l",
        ]
        let script = parts.joined(separator: "; ")
        return "sh -c " + script.shellQuoted + " tether " + [sessionName, m, attachOnly ? "1" : "0", String(max(size.cols, 20)), String(max(size.rows, 4)),
                                                  directory ?? ""]
            .map(\.shellQuoted).joined(separator: " ")
    }

    public enum Marker: Equatable, Sendable {
        case tmux(version: String)
        case screen
        case plain
        case gone
        case unknown(String)

        init(payload: String) {
            if payload == "gone" { self = .gone; return }
            var fields: [String: String] = [:]
            for f in payload.split(separator: ";") {
                let kv = f.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { fields[kv[0]] = kv[1] }
            }
            switch fields["mode"] {
            case "tmux": self = .tmux(version: fields["v"] ?? "")
            case "screen": self = .screen
            case "plain": self = .plain
            default: self = .unknown(payload)
            }
        }
    }

    /// Finds and removes the first marker in `buffer`.
    /// Returns bytes before the marker, the marker, and bytes after it.
    /// If no complete marker is present, returns nil.
    public static func extractMarker(from buffer: [UInt8]) -> (before: [UInt8], marker: Marker, after: [UInt8])? {
        guard let start = indexOf(markerPrefix, in: buffer) else { return nil }
        let payloadStart = start + markerPrefix.count
        guard let end = buffer[payloadStart...].firstIndex(of: 0x07) else { return nil }
        let payload = String(decoding: buffer[payloadStart..<end], as: UTF8.self)
        return (Array(buffer[..<start]), Marker(payload: payload), Array(buffer[(end + 1)...]))
    }

    /// Number of trailing bytes that might be the beginning of a marker, to hold back.
    public static func pendingPrefixLength(_ buffer: [UInt8]) -> Int {
        // A started-but-unfinished marker.
        if let start = indexOf(markerPrefix, in: buffer) { return buffer.count - start }
        var n = min(markerPrefix.count - 1, buffer.count)
        while n > 0 {
            if Array(buffer.suffix(n)) == Array(markerPrefix.prefix(n)) { return n }
            n -= 1
        }
        return 0
    }

    static func indexOf(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard needle.count <= hay.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
            if hay[i..<(i + needle.count)].elementsEqual(needle) { return i }
        }
        return nil
    }
}
