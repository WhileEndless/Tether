import Foundation

/// A fake `ssh` that behaves like OpenSSH with shared connections, for tests (nothing goes over the
/// network, nothing outside `directory` is touched):
/// - `-G`: prints a socket in `directory` for the destination (and its `proxyjump` from the
///   `jumps` file there: lines of "destination jump-host").
/// - `ControlMaster=yes`: a "sign-in" (logged to `logins.log`, refused while `refuse` exists, never
///   ending while `hang-<destination>` exists — a server that does not answer), then a
///   real Unix socket held by `nc -lU` and an `.alive` marker; exits 0 like a backgrounded master.
/// - `-O check` / `-O exit`: answer from the marker / end the fake master.
/// - A client (`ControlMaster=no`) fails like real ssh when the connection is not there, otherwise
///   runs its last argument with `sh` here (tmux in a private `TMUX_TMPDIR`, `TMUX` unset).
public enum FakeSharedSSH {
    public static func install(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("ssh")
        let d = directory.path
        let script = #"""
        #!/bin/sh
        D="\#(d)"
        cp=""; master=""; op=""; resolve=""; prev=""; last=""
        for a in "$@"; do
          case "$prev" in
            -o) case "$a" in ControlPath=*) cp="${a#ControlPath=}";; ControlMaster=yes) master=yes;; esac;;
            -O) op="$a";;
          esac
          [ "$a" = "-G" ] && resolve=yes
          prev="$a"; last="$a"
        done
        echo "$*" >> "$D/ssh-calls.log"
        if [ -n "$resolve" ]; then
          name=$(printf '%s' "$last" | tr -c 'A-Za-z0-9' '_')
          echo "hostname $last"
          echo "controlpath $D/cm-$name"
          jump=$(awk -v n="$last" '$1 == n { print $2 }' "$D/jumps" 2>/dev/null)
          if [ -n "$jump" ]; then echo "proxyjump $jump"; fi
          exit 0
        fi
        case "$op" in
          check) if [ -e "$cp.alive" ]; then echo "Master running" >&2; exit 0; fi
                 echo "Control socket connect($cp): No such file or directory" >&2; exit 255;;
          exit) if [ -f "$cp.pid" ]; then kill "$(cat "$cp.pid")" 2>/dev/null; fi
                rm -f "$cp.alive" "$cp.pid" "$cp"; echo "Exit request sent." >&2; exit 0;;
          "") ;;
          *) exit 0;;
        esac
        if [ -n "$master" ]; then
          echo "start" >> "$D/logins.log"
          if [ -e "$D/hang-$(printf '%s' "$last" | tr -c 'A-Za-z0-9' '_')" ]; then exec sleep 120; fi
          sleep "${FAKE_LOGIN_DELAY:-0.3}"
          if [ -e "$D/refuse" ]; then echo "end refused" >> "$D/logins.log"; echo "user@example.com: Permission denied (password)." >&2; exit 255; fi
          rm -f "$cp"
          /usr/bin/nc -lU "$cp" >/dev/null 2>&1 </dev/null &
          echo $! > "$cp.pid"
          i=0; while [ ! -S "$cp" ] && [ $i -lt 100 ]; do sleep 0.02; i=$((i+1)); done
          touch "$cp.alive"
          echo "end" >> "$D/logins.log"
          exit 0
        fi
        if [ -n "$cp" ] && [ "$cp" != "none" ] && [ ! -e "$cp.alive" ]; then
          echo "Connection closed by UNKNOWN port 65535" >&2; exit 255
        fi
        export TMUX_TMPDIR="$D"
        unset TMUX
        export SHELL=/bin/sh
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        exec /bin/sh -c "$last"
        """#
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The sign-ins the fake performed ("start"/"end" lines).
    public static func logins(in directory: URL) -> [String] {
        ((try? String(contentsOf: directory.appendingPathComponent("logins.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    /// Ends every fake master in `directory` (their `nc` processes).
    public static func stopMasters(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".pid") {
            let path = directory.appendingPathComponent(name)
            if let text = try? String(contentsOf: path, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGTERM)
            }
            try? FileManager.default.removeItem(at: path)
        }
    }

    /// Ends a fake master as if its connection died (no `-O exit`): the marker and socket go.
    public static func killMaster(socket: String) {
        if let text = try? String(contentsOfFile: socket + ".pid", encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)
        }
        for suffix in [".alive", ".pid", ""] { try? FileManager.default.removeItem(atPath: socket + suffix) }
    }
}
