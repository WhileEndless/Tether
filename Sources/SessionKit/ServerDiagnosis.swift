import Foundation

/// A short, read-only look at a server after a session on it ended by itself: how full its memory
/// is, whether the kernel's out-of-memory killer acted lately, whether the user's shell has an idle
/// limit (TMOUT), and whether the server restarted. Only tools already there; nothing is changed.
enum ServerDiagnosis {
    static let script = #"""
    if [ -r /proc/meminfo ]; then
      awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{ if (t > 0 && a != "") printf "@@mem %d\n", (t-a)*100/t }' /proc/meminfo
    fi
    # The kernel's out-of-memory killer in the last 15 minutes (the journal knows when; without it,
    # the kernel's own buffer, which may be older).
    if command -v journalctl >/dev/null 2>&1 && journalctl -k -n 1 -q --no-pager >/dev/null 2>&1; then
      oom=$(journalctl -k --since '-15 min' -q --no-pager -o short-iso 2>/dev/null | grep -i 'killed process' | tail -n 1)
    else
      oom=$(dmesg 2>/dev/null | grep -i 'killed process' | tail -n 1)
    fi
    [ -n "$oom" ] && printf '@@oom %s\n' "$oom"
    [ -r /proc/uptime ] && printf '@@uptime %s\n' "$(cut -d' ' -f1 /proc/uptime)"
    t=$(cd / && TMOUT= ${SHELL:-sh} -lc 'printf "%s" "${TMOUT:-}"' </dev/null 2>/dev/null | tail -c 32)
    case "$t" in ''|*[!0-9]*) ;; *) printf '@@tmout %s\n' "$t";; esac
    exit 0
    """#

    static func hints(from output: String) -> [String] {
        var hints: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "@@mem":
                if let used = Int(parts[1]), used >= 90 { hints.append("the server is low on memory (\(used)% used)") }
            case "@@oom":
                hints.append(oomHint(parts[1]))
            case "@@uptime":
                if let up = Double(parts[1]), up < 600 { hints.append("the server restarted \(Int(up / 60)) min ago") }
            case "@@tmout":
                if let t = Int(parts[1]), t > 0 { hints.append("the shell has an idle limit (TMOUT=\(t) s)") }
            default:
                break
            }
        }
        return hints
    }

    /// "Killed process 4321 (example-worker)", with the journal's time if there is one.
    static func oomHint(_ line: String) -> String {
        var hint = "the server's kernel ended "
        if let open = line.range(of: "Killed process "), let start = line[open.upperBound...].firstIndex(of: "("),
           let end = line[start...].firstIndex(of: ")") {
            hint += String(line[line.index(after: start)..<end])
        } else {
            hint += "a process"
        }
        hint += " for lack of memory"
        // short-iso: 2026-01-05T09:30:12+0000
        if let m = line.firstMatch(of: #/^\d{4}-\d{2}-\d{2}T(\d{2}:\d{2})/#) { hint += " at " + String(m.1) } else { hint += " recently" }
        return hint
    }
}
