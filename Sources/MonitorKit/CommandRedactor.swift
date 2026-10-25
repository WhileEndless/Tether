import Foundation

/// Hides secrets that commonly appear in command lines before they are kept in the command
/// history: password and token options, `NAME=secret` assignments, credentials in URLs,
/// Authorization headers and mysql-style `-pSECRET`.
public enum CommandRedactor {
    public static let mask = "••••"

    private static let rules: [(NSRegularExpression, String)] = {
        let secretWord = "(?:pass(?:word|wd|phrase)?|pwd|token|secret|api[-_]?key|access[-_]?key|private[-_]?key|auth(?:-token)?|credentials?)"
        let patterns: [(String, String)] = [
            // --password=x, --token x, -password x
            (#"(?i)(--?(?:[a-z0-9]+[-_])*"# + secretWord + #"(?:[-_][a-z0-9]+)*(?:=|\s+))(?:"[^"]*"|'[^']*'|\S+)"#, "$1" + mask),
            // MYSQL_PWD=x, GITHUB_TOKEN=x, PGPASSWORD=x, password=x
            (#"(?i)(\b[a-z0-9_]*"# + secretWord + #"[a-z0-9_]*=)(?:"[^"]*"|'[^']*'|\S+)"#, "$1" + mask),
            // curl -u user:secret, --user user:secret
            (#"((?:^|\s)(?:-u|--user)\s+[^:\s]+:)\S+"#, "$1" + mask),
            // openssl -pass pass:secret
            (#"(-pass(?:in|out)?\s+pass:)\S+"#, "$1" + mask),
            // X-Api-Key: x, X-Auth-Token: x, Private-Token: x
            (#"(?i)((?:x-)?[a-z-]*(?:api[-_]?key|token|secret)[a-z-]*:\s*)[^\s'"]+"#, "$1" + mask),
            // scheme://user:secret@host
            (#"(://[^/\s:@]+:)[^@\s/]+@"#, "$1" + mask + "@"),
            // Authorization: Bearer x
            (#"(?i)(authorization:\s*(?:bearer|basic|token)?\s*)[^\s'"]+"#, "$1" + mask),
            // sshpass -p x
            (#"(\bsshpass\s+(?:-\w+\s+)*-p\s*)\S+"#, "$1" + mask),
        ]
        return patterns.compactMap { p in (try? NSRegularExpression(pattern: p.0)).map { ($0, p.1) } }
    }()

    /// mysql, mariadb and their tools take the password glued to `-p`.
    private static let mysqlPassword = try? NSRegularExpression(pattern: #"(\s-p)(?!\s)(\S+)"#)
    private static let mysqlTools: Set<String> = ["mysql", "mysqldump", "mysqladmin", "mysqlimport", "mysqlshow", "mysqlcheck",
                                                  "mariadb", "mariadb-dump", "mariadb-admin"]

    /// Tools whose short option takes a secret as the next word.
    private static let secretOptions: [(tools: Set<String>, option: String)] = [
        (["redis-cli", "keydb-cli"], "-a"),
        (["docker", "podman", "nerdctl", "buildah", "skopeo", "helm"], "-p"),   // `… login -p secret`
        (["openssl"], "-k"),
    ]

    public static func redact(_ commandLine: String) -> String {
        var s = commandLine
        for (regex, template) in rules {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        // The program may follow sudo, env or assignments: any word of the line names it.
        let words = Set(s.split(separator: " ").map { ($0 as NSString).lastPathComponent })
        if !words.isDisjoint(with: mysqlTools), let mysqlPassword {
            s = mysqlPassword.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1" + mask)
        }
        for (tools, option) in secretOptions where !words.isDisjoint(with: tools) {
            // docker & co. only in `login`, where -p is the password (elsewhere it publishes ports).
            if tools.contains("docker") && !words.contains("login") { continue }
            if let regex = try? NSRegularExpression(pattern: #"(\s"# + NSRegularExpression.escapedPattern(for: option) + #"\s+)\S+"#) {
                s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1" + mask)
            }
        }
        return s
    }
}
