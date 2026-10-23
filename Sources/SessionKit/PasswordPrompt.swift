import Foundation

/// A password prompt waiting at the end of a terminal's output (sudo, su, ssh to another host, …).
public struct PasswordPrompt: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// `[sudo] password for alice:`
        case sudo
        /// `alice@db.example.com's password:` (ssh from inside the session)
        case login
        /// `Enter passphrase for key '/home/user/.ssh/id_ed25519':`
        case passphrase
        /// `Password:` (su, login, mysql -p, …)
        case generic
    }

    public var kind: Kind
    /// The account the password is for, when the prompt says so.
    public var user: String?
    /// For `login` prompts: the host being logged in to.
    public var host: String?
    /// The prompt as shown (trimmed).
    public var text: String

    public init(kind: Kind, user: String? = nil, host: String? = nil, text: String) {
        self.kind = kind
        self.user = user
        self.host = host
        self.text = text
    }

    /// Recognizes a prompt from the last line of output (ANSI sequences already removed).
    public static func recognize(_ line: String) -> PasswordPrompt? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.count <= 200, text.hasSuffix(":") else { return nil }
        // Choosing a new password (passwd) is never filled from the keychain.
        let lower = text.lowercased()
        if ["new ", "retype", "confirm", "repeat", "again"].contains(where: lower.contains) { return nil }
        func match(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (0..<m.numberOfRanges).map { i in
                Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
            }
        }
        if let m = match(#"^\[sudo\] password for ([^:\s]+):$"#) { return PasswordPrompt(kind: .sudo, user: m[1], text: text) }
        // Localized or sudo-rs style prompts: "[sudo] Passwort für alice:", "[sudo: authenticate] Password:".
        if match(#"^\[sudo[^\]]*\] .*:$"#) != nil {
            let user = match(#"\s(\S+):$"#)?[1]
            return PasswordPrompt(kind: .sudo, user: user?.lowercased() == "password" ? nil : user, text: text)
        }
        if let m = match(#"^([^@\s]+)@([^'\s]+)'s password:$"#) {
            return PasswordPrompt(kind: .login, user: m[1], host: m[2], text: text)
        }
        if match(#"^Enter passphrase for (key )?'?[^']*'?:$"#) != nil { return PasswordPrompt(kind: .passphrase, text: text) }
        if let m = match(#"^Password for '?([^'\s]+?)'?:$"#) { return PasswordPrompt(kind: .generic, user: m[1], text: text) }
        if match(#"^(Enter )?(\S+ )?password:$"#) != nil { return PasswordPrompt(kind: .generic, text: text) }
        return nil
    }
}

/// Watches terminal output for a password prompt at the end of the current line.
public struct PasswordPromptDetector {
    private var line = ""
    private var inEscape = false
    private var escapeKind: Character?

    public init() {}

    /// Feeds output; returns the prompt now showing (nil if none).
    public mutating func feed(_ bytes: [UInt8]) -> PasswordPrompt? {
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            if inEscape {
                // CSI ends with a letter; OSC ends with BEL or ST (ESC \).
                if escapeKind == nil {
                    escapeKind = Character(scalar)
                    if scalar != "[" && scalar != "]" { inEscape = false; escapeKind = nil }
                } else if escapeKind == "[" {
                    if scalar.value >= 0x40 && scalar.value <= 0x7e { inEscape = false; escapeKind = nil }
                } else if scalar == "\u{07}" || scalar == "\\" {
                    inEscape = false; escapeKind = nil
                }
                continue
            }
            switch scalar {
            case "\u{1b}": inEscape = true; escapeKind = nil
            case "\n", "\r": line = ""
            case "\u{08}": if !line.isEmpty { line.removeLast() }
            default:
                if scalar.value >= 0x20 { line.unicodeScalars.append(scalar) }
            }
        }
        if line.count > 300 { line = String(line.suffix(300)) }
        return PasswordPrompt.recognize(line)
    }

    public mutating func reset() {
        line = ""
    }
}
