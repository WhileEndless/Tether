import Foundation
import TetherCore

/// Builds the small POSIX shell program that runs on the remote host when a terminal connects.
///
/// It picks a persistence backend that already exists on the host (nothing is installed),
/// announces the choice with a private OSC marker, then `exec`s into it:
///
///     ESC ] 7770 ; mode=tmux;v=3.4 BEL     tmux control mode follows
///     ESC ] 7770 ; mode=screen BEL         GNU screen follows
///     ESC ] 7770 ; mode=plain;pid=123 BEL  a plain login shell (with this pid) follows
///     ESC ] 7770 ; gone BEL                re-attach requested but the session no longer exists
///     ESC ] 7770 ; unreachable;why=… BEL   re-attach requested but tmux or screen could not be
///                                          asked (not found, another version, its socket): the
///                                          session may well still be there
public enum RemoteBootstrap {
    /// The private OSC code of the marker.
    public static let markerCode = 7770
    public static let markerPrefix: [UInt8] = Array("\u{1b}]\(markerCode);".utf8)

    /// - Parameters:
    ///   - mode: requested persistence. On re-attach pass the backend that was negotiated originally.
    ///   - sessionName: tmux/screen session name.
    ///   - attachOnly: only re-attach; report `gone` instead of creating a new session.
    ///   - size: initial terminal size, so a new tmux session starts at the right size instead of
    ///     80x24 followed by a resize (which makes shells like zsh redraw their prompt).
    ///   - directory: start directory for a new session (ignored when re-attaching).
    ///   - historyLimit: scrollback lines the server keeps for a new session (tmux `history-limit`,
    ///     screen `defscrollback`), so output printed while Tether is not connected is still there.
    ///     Set on that session only; the user's own sessions and tmux settings are not touched.
    public static func command(mode: PersistenceMode, sessionName: String, attachOnly: Bool,
                               size: (cols: Int, rows: Int) = (80, 24), directory: String? = nil,
                               historyLimit: Int = 100_000) -> String {
        let m: String = switch mode {
        case .auto: "auto"
        case .tmux: "tmux"
        case .screen: "screen"
        case .off: "off"
        }
        // Kept on a single line: some login shells (csh) reject newlines inside quotes.
        let parts = [
            "N=\"$1\"", "M=\"$2\"", "A=\"$3\"", "W=\"$4\"", "H=\"$5\"", "D=\"$6\"", "L=\"$7\"",
            "if [ -n \"$D\" ]; then cd \"$D\" 2>/dev/null || D=\"\"; fi",
            "mark() { printf '\\033]7770;%s\\007' \"$1\"; }",
            // tmux >= 3.0 in control mode
            "if [ \"$M\" = auto ] || [ \"$M\" = tmux ]; then if command -v tmux >/dev/null 2>&1; then "
                + "V=$(tmux -V 2>/dev/null | sed 's/^[^0-9]*//;s/[^0-9.].*$//'); MAJ=${V%%.*}; "
                + "if [ \"${MAJ:-0}\" -ge 3 ] 2>/dev/null; then "
                // Gone only when tmux says so: it answers without the session, or no tmux server
                // runs at all. A tmux that cannot be asked (another version after an upgrade, its
                // socket) does not mean the session ended.
                + "if [ \"$A\" = 1 ] && ! tmux has-session -t \"=$N\" 2>/dev/null; then "
                + "E=$(tmux list-sessions 2>&1 >/dev/null); S=$?; "
                + "case \"$S:$E\" in 0:*|*'no server running'*|*'error connecting to'*'No such file'*) mark gone ;; "
                + "*) mark \"unreachable;why=tmux: $(printf %s \"$E\" | tr ';\\n\\007\\033' '    ' | cut -c1-160)\" ;; esac; exit 0; fi; "
                + "mark \"mode=tmux;v=$V\"; "
                // Tether's own sessions are never ended by tmux when Tether lets go of them (a
                // `destroy-unattached on` in the user's tmux.conf): set on that session only.
                + "case \"$N\" in tether-*) tmux set-option -t \"=$N:\" destroy-unattached off >/dev/null 2>&1 ;; esac; "
                // A new session gets its history limit before its window exists (tmux applies the
                // limit when a pane is created): start with a placeholder window, set the option on
                // this session only, open the real window, drop the placeholder.
                + "if ! tmux has-session -t \"=$N\" 2>/dev/null && [ \"${L:-0}\" -gt 0 ] 2>/dev/null "
                + "&& tmux new-session -d -s \"$N\" -n tether-init -x \"$W\" -y \"$H\" 2>/dev/null; then "
                + "tmux set-option -t \"=$N:\" history-limit \"$L\" >/dev/null 2>&1; "
                + "tmux set-option -t \"=$N:\" destroy-unattached off >/dev/null 2>&1; "
                + "if [ -n \"$D\" ]; then tmux new-window -t \"=$N:\" -c \"$D\" 2>/dev/null; else tmux new-window -t \"=$N:\" 2>/dev/null; fi "
                + "&& tmux kill-window -t \"=$N:tether-init\" 2>/dev/null; "
                + "exec tmux -CC attach-session -t \"=$N\"; fi; "
                + "if [ -n \"$D\" ]; then exec tmux -CC new-session -A -s \"$N\" -x \"$W\" -y \"$H\" -c \"$D\"; fi; "
                + "exec tmux -CC new-session -A -s \"$N\" -x \"$W\" -y \"$H\"; "
                + "fi; fi; fi",
            // Re-attaching to a tmux session, but no tmux 3 here (any more): not the same as gone.
            "if [ \"$M\" = tmux ] && [ \"$A\" = 1 ]; then mark \"unreachable;why=tmux 3 or later was not found\"; exit 0; fi",
            // GNU screen with the alternate screen disabled so local scrollback keeps history
            "if [ \"$M\" = auto ] || [ \"$M\" = screen ]; then if command -v screen >/dev/null 2>&1; then "
                + "if [ \"$A\" = 1 ] && ! screen -ls 2>/dev/null | grep -q \"[.]$N[[:space:]]\"; then mark gone; exit 0; fi; "
                // A private settings file with a random name: /tmp is shared, and a file planted
                // there by another account must never be read as this user's screen settings.
                + "R=$(umask 077; mktemp \"${TMPDIR:-/tmp}/.tether-screenrc.XXXXXXXX\" 2>/dev/null) || R=\"\"; "
                + "if [ -n \"$R\" ] && [ -O \"$R\" ] && [ ! -L \"$R\" ] && "
                + "printf 'termcapinfo xterm* ti@:te@\\ndefscrollback %s\\nstartup_message off\\nvbell off\\n' \"${L:-10000}\" > \"$R\"; then "
                + "(sleep 10; rm -f \"$R\") >/dev/null 2>&1 & "
                + "mark mode=screen; exec screen -c \"$R\" -D -RR -S \"$N\"; fi; "
                + "mark mode=screen; exec screen -D -RR -S \"$N\"; "
                + "fi; fi",
            "if [ \"$M\" = screen ] && [ \"$A\" = 1 ]; then mark \"unreachable;why=GNU screen was not found\"; exit 0; fi",
            // Plain shell: nothing survives a disconnect, so a re-attach always reports gone.
            "if [ \"$A\" = 1 ]; then mark gone; exit 0; fi",
            // `exec` keeps the process id: $$ is the shell's pid (to find what runs in it).
            "mark \"mode=plain;pid=$$\"",
            "exec \"${SHELL:-/bin/sh}\" -l",
        ]
        let script = parts.joined(separator: "; ")
        return "sh -c " + script.shellQuoted + " tether " + [sessionName, m, attachOnly ? "1" : "0", String(max(size.cols, 20)), String(max(size.rows, 4)),
                                                  directory ?? "", String(max(historyLimit, 0))]
            .map(\.shellQuoted).joined(separator: " ")
    }

    public enum Marker: Equatable, Sendable {
        case tmux(version: String)
        case screen
        case plain
        case gone
        /// tmux or screen could not be asked about the session (see the type's notes).
        case unreachable(String)
        case unknown(String)

        init(payload: String) {
            if payload == "gone" { self = .gone; return }
            let fields = Self.fields(payload)
            if payload.hasPrefix("unreachable") { self = .unreachable(fields["why"] ?? "unknown"); return }
            switch fields["mode"] {
            case "tmux": self = .tmux(version: fields["v"] ?? "")
            case "screen": self = .screen
            case "plain": self = .plain
            default: self = .unknown(payload)
            }
        }

        /// `key=value` pairs of a marker payload (`mode=plain;pid=123`); unknown keys are ignored.
        public static func fields(_ payload: String) -> [String: String] {
            var fields: [String: String] = [:]
            for f in payload.split(separator: ";") {
                let kv = f.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { fields[kv[0]] = kv[1] }
            }
            return fields
        }
    }

    /// Finds and removes the first marker in `buffer`.
    /// Returns bytes before the marker, the marker, and bytes after it.
    /// If no complete marker is present, returns nil.
    public static func extractMarker(from buffer: [UInt8]) -> (before: [UInt8], marker: Marker, after: [UInt8], fields: [String: String])? {
        guard let start = indexOf(markerPrefix, in: buffer) else { return nil }
        let payloadStart = start + markerPrefix.count
        guard let end = buffer[payloadStart...].firstIndex(of: 0x07) else { return nil }
        let payload = String(decoding: buffer[payloadStart..<end], as: UTF8.self)
        return (Array(buffer[..<start]), Marker(payload: payload), Array(buffer[(end + 1)...]), Marker.fields(payload))
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
