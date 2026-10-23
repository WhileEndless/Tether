import Foundation

/// A server whose host key no longer matches the one in known_hosts, as reported by ssh
/// ("REMOTE HOST IDENTIFICATION HAS CHANGED"). ssh refuses to connect; the user decides.
public struct HostKeyChange: Equatable, Sendable {
    /// The name ssh looked up in known_hosts, e.g. `server.example.com` or `[192.0.2.10]:2222`.
    public var host: String
    /// Key type and fingerprint the server sent now, e.g. "ED25519", "SHA256:…".
    public var keyType: String?
    public var fingerprint: String?
    /// Where the old key is (file and 1-based line).
    public var knownHostsFile: String?
    public var line: Int?

    /// Finds a host key change in ssh's messages (one line per element, `debug1:` lines allowed).
    public static func parse(_ lines: [String]) -> HostKeyChange? {
        guard lines.contains(where: { $0.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") }) else { return nil }
        var change = HostKeyChange(host: "")
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let m = line.firstMatch(of: #/^Host key for (\S+) has changed/#) {
                change.host = String(m.1)
            } else if let m = line.firstMatch(of: #/^The fingerprint for the (\S+) key sent by the remote host is/#) {
                change.keyType = String(m.1)
                if i + 1 < lines.count {
                    let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                    if next.hasPrefix("SHA256:") || next.hasPrefix("MD5:") {
                        change.fingerprint = next.hasSuffix(".") ? String(next.dropLast()) : next
                    }
                }
            } else if let m = line.firstMatch(of: #/^Offending \S+ key in (.+):(\d+)$/#) {
                change.knownHostsFile = String(m.1)
                change.line = Int(m.2)
            }
        }
        return change.host.isEmpty ? nil : change
    }

    /// Removes every known_hosts entry for `host` with `ssh-keygen -R` (which keeps the previous
    /// file as `known_hosts.old`). Returns an error message, or nil on success.
    public func removeOldKey(sshKeygen: String = "/usr/bin/ssh-keygen") async -> String? {
        guard let file = knownHostsFile else { return "ssh did not say which known_hosts file holds the old key." }
        let result = await ProcessRunner.run(sshKeygen, arguments: ["-f", file, "-R", host], timeout: 15)
        guard result.status == 0 else {
            let text = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "ssh-keygen failed (code \(result.status))." : text
        }
        return nil
    }
}

/// The question ssh asks about a server it has never seen:
/// "The authenticity of host 'x (192.0.2.10)' can't be established. ED25519 key fingerprint is SHA256:…"
public struct UnknownHostKey: Equatable, Sendable {
    public var host: String?
    public var keyType: String?
    public var fingerprint: String
    /// ssh found the same key under other names (e.g. the host's IP address).
    public var knownAs: [String]

    public static func parse(_ prompt: String) -> UnknownHostKey? {
        guard let fp = prompt.firstMatch(of: #/(?:(\S+) )?key fingerprint is:? ((?:SHA256|MD5):\S+?)\.?(?:\s|$)/#) else { return nil }
        // "name (address)", shortened to "name" when both are the same.
        let host = prompt.firstMatch(of: #/authenticity of host '([^']+)'/#).map { m -> String in
            let full = String(m.1)
            if let p = full.firstMatch(of: #/^(.+) \((.+)\)$/#), p.1 == p.2 { return String(p.1) }
            return full
        }
        var knownAs: [String] = []
        var collecting = false
        for raw in prompt.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("This key is known by the following other names") { collecting = true; continue }
            if collecting {
                if line.hasPrefix("Are you sure") || line.isEmpty { break }
                knownAs.append(line)
            }
        }
        return UnknownHostKey(host: host, keyType: fp.1.map(String.init), fingerprint: String(fp.2), knownAs: knownAs)
    }

    /// Compares a fingerprint the user got from the server's administrator (spaces and the
    /// "SHA256:" prefix optional).
    public func matches(_ typed: String) -> Bool {
        func normal(_ s: String) -> String {
            var t = s.filter { !$0.isWhitespace }
            if t.hasSuffix(".") { t.removeLast() }
            if let colon = t.firstIndex(of: ":"), t[..<colon].uppercased() == "SHA256" { t = String(t[t.index(after: colon)...]) }
            return t
        }
        let a = normal(typed), b = normal(fingerprint)
        return !a.isEmpty && a == b
    }
}
