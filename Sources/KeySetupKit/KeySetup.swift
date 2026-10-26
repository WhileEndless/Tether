import Foundation
import TetherCore
import SSHTransport

/// Generates SSH keys and installs public keys on remote hosts.
public enum KeySetup {
    public struct LocalKey: Identifiable, Hashable, Sendable {
        public var privateKeyURL: URL
        public var publicKey: String
        public var type: String
        public var comment: String
        /// The private key is protected with a passphrase (nil: the file's format is not known).
        public var isEncrypted: Bool?
        public var id: URL { privateKeyURL }
        public var name: String { privateKeyURL.lastPathComponent }
    }

    /// Kinds of key Tether creates.
    public enum KeyType: String, CaseIterable, Identifiable, Sendable {
        /// Small and fast; every current server accepts it.
        case ed25519
        /// For servers too old for Ed25519 (OpenSSH before 6.5).
        case rsa
        public var id: String { rawValue }
        public var title: String { self == .ed25519 ? "Ed25519 (recommended)" : "RSA 4096 (for older servers)" }
        var filePrefix: String { self == .ed25519 ? "id_ed25519" : "id_rsa" }
        var keygenArguments: [String] {
            self == .ed25519 ? ["-t", "ed25519", "-a", "100"] : ["-t", "rsa", "-b", "4096", "-a", "100"]
        }
    }

    /// Public/private key pairs found in ~/.ssh (or `directory`).
    public static func existingKeys(in directory: URL = AppPaths.userSSHDirectory) -> [LocalKey] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension == "pub" }.compactMap { key(at: $0.deletingPathExtension()) }.sorted { $0.name < $1.name }
    }

    /// The key pair at `privateKeyURL` (with its `.pub` next to it).
    public static func key(at priv: URL) -> LocalKey? {
        let pub = priv.appendingPathExtension("pub")
        guard FileManager.default.fileExists(atPath: priv.path),
              let text = try? String(contentsOf: pub, encoding: .utf8) else { return nil }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        return LocalKey(privateKeyURL: priv, publicKey: parts[0] + " " + parts[1],
                        type: parts[0], comment: parts.count > 2 ? parts[2] : "", isEncrypted: isEncrypted(priv))
    }

    /// Whether the private key file is protected with a passphrase, read from the file itself (the
    /// passphrase is neither needed nor asked for). Nil when the format is not one ssh writes.
    public static func isEncrypted(_ url: URL) -> Bool? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Marker lines are matched by their ends ("… OPENSSH PRIVATE KEY-----").
        if text.contains("OPENSSH PRIVATE KEY-----") {
            // openssh-key-v1: magic, then the cipher name as a length-prefixed string.
            let body = text.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
            guard let data = Data(base64Encoded: body) else { return nil }
            let magic = Data("openssh-key-v1\0".utf8)
            guard data.count > magic.count + 4, data.prefix(magic.count) == magic else { return nil }
            let at = data.startIndex + magic.count
            let length = Int(data[at]) << 24 | Int(data[at + 1]) << 16 | Int(data[at + 2]) << 8 | Int(data[at + 3])
            guard length > 0, at + 4 + length <= data.endIndex else { return nil }
            return String(decoding: data[(at + 4)..<(at + 4 + length)], as: UTF8.self) != "none"
        }
        if text.contains("ENCRYPTED PRIVATE KEY-----") || text.contains("Proc-Type: 4,ENCRYPTED") { return true }
        if text.contains("PRIVATE KEY-----") { return false }
        return nil
    }

    /// A key file name not in use yet (neither the key nor its `.pub`).
    public static func isTaken(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: url.path + ".pub")
    }

    /// Suggests a non-existing key file name for a host alias.
    public static func suggestedKeyURL(for alias: String, type: KeyType = .ed25519,
                                       in directory: URL = AppPaths.userSSHDirectory) -> URL {
        let safe = String(alias.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        var url = directory.appendingPathComponent("\(type.filePrefix)_\(safe)")
        var n = 2
        while isTaken(url) {
            url = directory.appendingPathComponent("\(type.filePrefix)_\(safe)_\(n)")
            n += 1
        }
        return url
    }

    /// Runs ssh-keygen to create a key. An empty passphrase creates an unencrypted key. A
    /// passphrase reaches ssh-keygen through Tether's askpass helper, never as a command-line
    /// argument that other processes could read. An existing file is never replaced.
    public static func generate(at url: URL, comment: String, passphrase: String, type: KeyType = .ed25519) async throws -> LocalKey {
        guard !isTaken(url) else {
            throw RemoteError("A key named \(url.lastPathComponent) already exists. Choose another name.")
        }
        if url.deletingLastPathComponent().standardizedFileURL == AppPaths.userSSHDirectory.standardizedFileURL {
            AppPaths.ensure(AppPaths.userSSHDirectory, permissions: 0o700)
        }
        var arguments = ["-q"] + type.keygenArguments + ["-f", url.path, "-C", comment]
        var askpass: [String: String] = [:]
        if passphrase.isEmpty {
            arguments += ["-N", ""]
        } else {
            askpass = AskPassBridge.shared.environment(answering: passphrase, purpose: "key-generate")
            guard !askpass.isEmpty else { throw RemoteError("Tether's password helper is not available.") }
        }
        let r = await ProcessRunner.run("/usr/bin/ssh-keygen", arguments: arguments,
                                        environment: ProcessInfo.processInfo.environment.merging(askpass) { $1 }, timeout: 120)
        AskPassBridge.shared.revoke(environment: askpass)
        guard r.succeeded else {
            throw RemoteError(r.errorOutput.isEmpty ? "ssh-keygen failed." : r.errorOutput)
        }
        guard let key = key(at: url) else {
            throw RemoteError("The key was created but could not be read back.")
        }
        return key
    }

    /// Adds a key to the macOS ssh-agent, its passphrase to the macOS keychain, so programs other
    /// than Tether (Terminal, git) can use it too. The passphrase goes through askpass.
    public static func addToAgent(_ key: LocalKey, passphrase: String) async throws {
        let env = passphrase.isEmpty ? [:] : AskPassBridge.shared.environment(answering: passphrase, purpose: "key-add")
        let r = await ProcessRunner.run("/usr/bin/ssh-add", arguments: ["--apple-use-keychain", key.privateKeyURL.path],
                                        environment: ProcessInfo.processInfo.environment.merging(env) { $1 }, timeout: 20)
        AskPassBridge.shared.revoke(environment: env)
        guard r.succeeded else {
            throw RemoteError(r.errorOutput.isEmpty ? "ssh-add could not add the key." : r.errorOutput)
        }
    }

    /// Adds, changes or removes a key's passphrase (`ssh-keygen -p`; an empty `new` removes it).
    /// The passphrases go through askpass. The key file is copied first and put back if anything
    /// fails, so a key is never left half-changed.
    public static func changePassphrase(_ key: LocalKey, old: String, new: String) async throws -> LocalKey {
        let fm = FileManager.default
        let url = key.privateKeyURL
        let backup = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tether-backup-\(UUID().uuidString.prefix(8))")
        try fm.copyItem(at: url, to: backup)
        defer { try? fm.removeItem(at: backup) }
        let env = AskPassBridge.shared.environment(answers: { prompt in
            prompt.lowercased().contains("old") ? old : new
        }, purpose: "key-passphrase")
        guard !env.isEmpty else { throw RemoteError("Tether's password helper is not available.") }
        let r = await ProcessRunner.run("/usr/bin/ssh-keygen", arguments: ["-p", "-q", "-f", url.path],
                                        environment: ProcessInfo.processInfo.environment.merging(env) { $1 }, timeout: 120)
        AskPassBridge.shared.revoke(environment: env)
        guard r.succeeded, let changed = Self.key(at: url), changed.isEncrypted == !new.isEmpty || changed.isEncrypted == nil else {
            _ = try? fm.replaceItemAt(url, withItemAt: backup, backupItemName: nil, options: [])
            let reason = r.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteError(reason.isEmpty ? "The passphrase could not be changed (is the old one right?)." : reason)
        }
        return changed
    }

    /// Appends the public key to ~/.ssh/authorized_keys on the remote host (if not already there),
    /// fixing permissions on the way. Authentication uses whatever works today (e.g. a password).
    public static func install(_ key: LocalKey, executor: RemoteExecutor) async throws {
        _ = try await executor.output(RemoteScript(installScript, windows: windowsInstallScript),
                                      arguments: [key.publicKey, key.comment], timeout: 60, purpose: "key-install")
    }

    /// Arguments: the public key (type and data), its comment. Prints `added` or `exists`.
    static let installScript = #"""
umask 077
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"
if grep -qF "$1" "$HOME/.ssh/authorized_keys" 2>/dev/null; then echo exists; else printf '%s\n' "$1 $2" >> "$HOME/.ssh/authorized_keys" && echo added; fi
"""#

    /// Verifies that the key alone can log in: no multiplexing, no password, only this key. A
    /// passphrase is answered with `passphrase` when given, else asked as at any login (askpass), so
    /// keys with a passphrase are verified too. Returns nil when it works, else what ssh said.
    public static func verify(_ key: LocalKey, target: ConnectionTarget, options: SSHOptions, passphrase: String? = nil) async -> String? {
        var opts = options
        opts.useControlMaster = false
        let args = opts.commonOptions(multiplex: false)
            + ["-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no",
               "-o", "KbdInteractiveAuthentication=no", "-o", "IdentitiesOnly=yes", "-o", "NumberOfPasswordPrompts=1",
               "-i", key.privateKeyURL.path, "-o", "ConnectTimeout=15"]
            + SSHOptions.destinationArguments(for: target) + ["exit"]
        let env = passphrase.map { AskPassBridge.shared.environment(answering: $0, purpose: "key-verify") }
            ?? AskPassBridge.shared.environment(targetKey: target.key, purpose: "key-verify")
        let r = await ProcessRunner.run(opts.sshBinary, arguments: args, environment: env, timeout: 60)
        AskPassBridge.shared.revoke(environment: env)
        if r.status == 0 { return nil }
        let said = r.errorOutput.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return said.isEmpty ? "Key login failed (the server may not allow public keys)." : said
    }

    /// Windows OpenSSH: the user's `~/.ssh/authorized_keys`, and for administrators also
    /// `%ProgramData%/ssh/administrators_authorized_keys` (which sshd uses for them by default,
    /// and which must only be accessible to Administrators and SYSTEM).
    static let windowsInstallScript = #"""
$line = "$($A[0]) $($A[1])"
function AddKey($file) {
  $dir = Split-Path -Parent $file
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  if (-not (Test-Path -LiteralPath $file) -or -not (Select-String -LiteralPath $file -SimpleMatch $A[0] -Quiet)) {
    Add-Content -LiteralPath $file -Value $line -Encoding ascii
  }
}
AddKey (Join-Path $HOME '.ssh\authorized_keys')
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  $admin = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
  AddKey $admin
  icacls $admin /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
}
'added'
"""#
}
