import Foundation

/// A pattern for secrets (API keys, tokens, passwords) that are masked in archived recordings.
///
/// - `pattern` is a regular expression matched on each line of output. With a group named
///   `secret` (`(?<secret>…)`) only that part is masked, e.g. the value after `password=`.
/// - With `endPattern`, a line matching `pattern` starts a block that runs to the line matching
///   `endPattern` (a private key); the lines in between are masked.
public struct SecretRule: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var pattern: String
    public var endPattern: String?
    public var enabled = true

    public init(id: String = UUID().uuidString, name: String, pattern: String, endPattern: String? = nil, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.endPattern = endPattern
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        pattern = (try? c.decode(String.self, forKey: .pattern)) ?? ""
        endPattern = try? c.decode(String.self, forKey: .endPattern)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
    }

    /// Why the pattern cannot be used, or nil when it can.
    public var problem: String? {
        if pattern.isEmpty { return "The pattern is empty" }
        for p in [pattern] + (endPattern.map { [$0] } ?? []) {
            guard let regex = try? NSRegularExpression(pattern: p) else { return "Invalid regular expression" }
            if regex.firstMatch(in: "", range: NSRange(location: 0, length: 0)) != nil { return "The pattern matches empty text" }
        }
        return nil
    }
}

/// Which secrets are masked when a session goes to the archive (Settings ▸ Security).
public struct SecretRedactionSettings: Codable, Equatable, Sendable {
    public var enabled = true
    /// Built-in rules switched off, by id.
    public var disabledBuiltIns: Set<String> = []
    /// Rules added by the user.
    public var custom: [SecretRule] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ key: CodingKeys, _ into: inout T) {
            if let v = try? c.decode(T.self, forKey: key) { into = v }
        }
        d(.enabled, &enabled)
        d(.disabledBuiltIns, &disabledBuiltIns)
        d(.custom, &custom)
    }

    /// The rules in force: the built-in ones not switched off, then the user's (valid, enabled) ones.
    public var activeRules: [SecretRule] {
        guard enabled else { return [] }
        return SecretRule.builtIn.filter { !disabledBuiltIns.contains($0.id) }
            + custom.filter { $0.enabled && $0.problem == nil }
    }
}

extension SecretRule {
    /// Common secret formats. Specific formats come first, the generic `name=value` rule last.
    public static let builtIn: [SecretRule] = [
        SecretRule(id: "private-key", name: "Private key blocks",
                   pattern: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----"#,
                   endPattern: #"-----END [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----"#),
        SecretRule(id: "aws-access-key", name: "AWS access key IDs", pattern: #"\b(?:AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}\b"#),
        SecretRule(id: "aws-secret-key", name: "AWS secret access keys",
                   pattern: #"(?i)aws_?secret_?access_?key["']?\s*[:=]\s*["']?(?<secret>[A-Za-z0-9/+=]{40})"#),
        SecretRule(id: "github-token", name: "GitHub tokens",
                   pattern: #"\b(?:gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{22,255})\b"#),
        SecretRule(id: "gitlab-token", name: "GitLab tokens", pattern: #"\bglpat-[A-Za-z0-9_-]{20,}"#),
        SecretRule(id: "anthropic-key", name: "Anthropic API keys", pattern: #"\bsk-ant-[A-Za-z0-9_-]{20,}"#),
        SecretRule(id: "openai-key", name: "OpenAI API keys", pattern: #"\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}"#),
        SecretRule(id: "google-api-key", name: "Google API keys", pattern: #"\bAIza[0-9A-Za-z_-]{35}"#),
        SecretRule(id: "slack-token", name: "Slack tokens and webhooks",
                   pattern: #"\bxox[abposr]-[A-Za-z0-9-]{10,}|https://hooks\.slack\.com/services/[A-Za-z0-9/_-]+"#),
        SecretRule(id: "stripe-key", name: "Stripe keys", pattern: #"\b(?:sk|rk)_(?:live|test)_[0-9A-Za-z]{16,}"#),
        SecretRule(id: "npm-token", name: "npm tokens", pattern: #"\bnpm_[A-Za-z0-9]{36}\b"#),
        SecretRule(id: "huggingface-token", name: "Hugging Face tokens", pattern: #"\bhf_[A-Za-z0-9]{30,}\b"#),
        SecretRule(id: "jwt", name: "JSON Web Tokens",
                   pattern: #"\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#),
        SecretRule(id: "bearer", name: "Bearer tokens in headers",
                   pattern: #"(?i)\bauthorization["']?\s*[:=]\s*["']?(?:bearer|token|basic)\s+(?<secret>[A-Za-z0-9._~+/=-]{12,})"#),
        SecretRule(id: "url-password", name: "Passwords in URLs",
                   pattern: #"\b[A-Za-z][A-Za-z0-9+.-]*://[^\s:/@]+:(?<secret>[^\s@/]{3,})@"#),
        SecretRule(id: "assignment", name: "Values of KEY, TOKEN, SECRET, PASSWORD variables",
                   pattern: #"(?i)\b[A-Z0-9_.-]*(?:api[_-]?key|secret|token|passw(?:or)?d|credential)s?["']?\s*[:=]\s*["']?(?<secret>[^\s"'`,;]{8,})"#),
    ]
}
