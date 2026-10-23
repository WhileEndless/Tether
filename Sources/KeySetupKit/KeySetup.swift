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
        public var id: URL { privateKeyURL }
        public var name: String { privateKeyURL.lastPathComponent }
    }

    /// Public/private key pairs found in ~/.ssh.
    public static func existingKeys() -> [LocalKey] {
        let dir = AppPaths.userSSHDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension == "pub" }.compactMap { key(at: $0.deletingPathExtension()) }.sorted { $0.name < $1.name }
    }

    /// The key pair at `privateKeyURL` (with its `.pub` next to it).
    static func key(at priv: URL) -> LocalKey? {
        let pub = priv.appendingPathExtension("pub")
        guard FileManager.default.fileExists(atPath: priv.path),
              let text = try? String(contentsOf: pub, encoding: .utf8) else { return nil }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        return LocalKey(privateKeyURL: priv, publicKey: parts[0] + " " + parts[1],
                        type: parts[0], comment: parts.count > 2 ? parts[2] : "")
    }

    /// Suggests a non-existing key file name for a host alias.
    public static func suggestedKeyURL(for alias: String) -> URL {
        let safe = alias.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }
        var url = AppPaths.userSSHDirectory.appendingPathComponent("id_ed25519_" + String(safe))
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = AppPaths.userSSHDirectory.appendingPathComponent("id_ed25519_\(String(safe))_\(n)")
            n += 1
        }
        return url
    }

    /// Runs ssh-keygen to create an ed25519 key. An empty passphrase creates an unencrypted key.
    /// A passphrase reaches ssh-keygen (and ssh-add) through Tether's askpass helper, never as a
    /// command-line argument that other processes could read.
    public static func generate(at url: URL, comment: String, passphrase: String, addToKeychain: Bool = true) async throws -> LocalKey {
        if url.deletingLastPathComponent().standardizedFileURL == AppPaths.userSSHDirectory.standardizedFileURL {
            AppPaths.ensure(AppPaths.userSSHDirectory, permissions: 0o700)
        }
        var arguments = ["-q", "-t", "ed25519", "-a", "100", "-f", url.path, "-C", comment]
        var env = ProcessInfo.processInfo.environment
        var askpass: [String: String] = [:]
        if passphrase.isEmpty {
            arguments += ["-N", ""]
        } else {
            askpass = AskPassBridge.shared.environment(answering: passphrase, purpose: "key-generate")
            guard !askpass.isEmpty else { throw RemoteError("Tether's password helper is not available.") }
            env.merge(askpass) { $1 }
        }
        let r = await ProcessRunner.run("/usr/bin/ssh-keygen", arguments: arguments, environment: env, timeout: 60)
        AskPassBridge.shared.revoke(environment: askpass)
        guard r.succeeded else {
            throw RemoteError(r.errorOutput.isEmpty ? "ssh-keygen failed." : r.errorOutput)
        }
        guard let key = key(at: url) else {
            throw RemoteError("The key was created but could not be read back.")
        }
        if !passphrase.isEmpty && addToKeychain {
            // Store the passphrase in the macOS keychain so the agent can unlock it.
            let add = AskPassBridge.shared.environment(answering: passphrase, purpose: "key-add")
            _ = await ProcessRunner.run("/usr/bin/ssh-add", arguments: ["--apple-use-keychain", url.path],
                                        environment: ProcessInfo.processInfo.environment.merging(add) { $1 }, timeout: 20)
            AskPassBridge.shared.revoke(environment: add)
        }
        return key
    }

    /// Appends the public key to ~/.ssh/authorized_keys on the remote host (if not already there),
    /// fixing permissions on the way. Authentication uses whatever works today (e.g. a password).
    public static func install(_ key: LocalKey, executor: RemoteExecutor) async throws {
        let script = #"""
umask 077
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"
if grep -qF "$1" "$HOME/.ssh/authorized_keys" 2>/dev/null; then echo exists; else printf '%s\n' "$1 $2" >> "$HOME/.ssh/authorized_keys" && echo added; fi
"""#
        _ = try await executor.output(RemoteScript(script, windows: windowsInstallScript),
                                      arguments: [key.publicKey, key.comment], timeout: 60, purpose: "key-install")
    }

    /// Verifies that the key alone can log in (no multiplexing, no password).
    public static func verify(_ key: LocalKey, target: ConnectionTarget, options: SSHOptions) async -> Bool {
        var opts = options
        opts.useControlMaster = false
        let args = opts.commonOptions(multiplex: false)
            + ["-o", "BatchMode=yes", "-o", "PasswordAuthentication=no", "-o", "IdentitiesOnly=yes",
               "-i", key.privateKeyURL.path, "-o", "ConnectTimeout=15"]
            + SSHOptions.destinationArguments(for: target) + ["exit"]
        let r = await ProcessRunner.run(opts.sshBinary, arguments: args, timeout: 30)
        return r.status == 0
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
