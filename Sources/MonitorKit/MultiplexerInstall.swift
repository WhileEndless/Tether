import Foundation
import SSHTransport

/// What a user can run to get tmux on a host that has no tmux or screen (its shells end when the
/// connection drops). Tether never installs anything: it finds the host's package manager (read
/// only) and offers the command, which the user runs in the terminal themselves.
public enum MultiplexerInstall {
    /// Says which package manager there is, the system, and whether the account is root and has
    /// sudo — one `key=value` per line. POSIX only: Windows has no tmux to install.
    public static let probe = RemoteScript(#"""
echo "os=$(uname -s 2>/dev/null)"
echo "uid=$(id -u 2>/dev/null)"
command -v sudo >/dev/null 2>&1 && echo "sudo=1"
for p in brew apt-get dnf yum zypper apk pacman xbps-install pkgin pkg port emerge; do
  if command -v "$p" >/dev/null 2>&1; then echo "pm=$p"; break; fi
done
"""#, windows: nil)

    public struct Suggestion: Equatable, Sendable {
        /// The command to type (nil: no package manager found; `note` says what to do).
        public var command: String?
        public var note: String
    }

    /// The suggestion for the probe's output.
    public static func suggestion(from output: String) -> Suggestion {
        var fields: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { fields[kv[0]] = kv[1].trimmingCharacters(in: .whitespaces) }
        }
        let mac = fields["os"] == "Darwin"
        let install: String? = switch fields["pm"] {
        case "brew": "brew install tmux"
        case "apt-get": "apt-get install tmux"
        case "dnf": "dnf install tmux"
        case "yum": "yum install tmux"
        case "zypper": "zypper install tmux"
        case "apk": "apk add tmux"
        case "pacman": "pacman -S tmux"
        case "xbps-install": "xbps-install tmux"
        case "pkgin": "pkgin install tmux"
        case "pkg": "pkg install tmux"
        case "port": "port install tmux"
        case "emerge": "emerge app-misc/tmux"
        default: nil
        }
        guard let install else {
            return Suggestion(command: nil, note: mac
                ? "No package manager was found on this Mac. Install Homebrew (brew.sh), then run `brew install tmux`."
                : "No package manager Tether knows was found. Install tmux with the system's own tools, or ask its administrator.")
        }
        // Homebrew never runs as root; the others need it.
        let root = fields["uid"] == "0"
        let needsRoot = fields["pm"] != "brew"
        if needsRoot, !root, fields["sudo"] != "1" {
            return Suggestion(command: install, note: "Run this as root (this account has no sudo), or ask the server's administrator.")
        }
        let command = needsRoot && !root ? "sudo " + install : install
        return Suggestion(command: command, note: "It asks before installing" + (needsRoot && !root ? " (and sudo for your password)" : "") + ".")
    }
}
