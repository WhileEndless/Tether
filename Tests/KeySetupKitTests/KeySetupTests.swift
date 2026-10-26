import Foundation
import Testing
import TestSupport
@testable import KeySetupKit

/// Keys are made in temporary folders and the install script runs with a temporary HOME: the real
/// ~/.ssh, authorized_keys and keychain are never touched.
@Suite struct KeySetupTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-keys-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A key made with ssh-keygen itself (test only: the passphrase is an argument here).
    func keygen(_ url: URL, type: [String], passphrase: String) {
        BoundedProcess.run("/usr/bin/ssh-keygen", ["-q"] + type + ["-f", url.path, "-C", "test", "-N", passphrase], timeout: 60)
    }

    @Test func tellsKeysWithAPassphraseFromKeysWithout() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("plain"), locked = dir.appendingPathComponent("locked")
        let rsa = dir.appendingPathComponent("rsa"), pem = dir.appendingPathComponent("pem")
        keygen(plain, type: ["-t", "ed25519"], passphrase: "")
        keygen(locked, type: ["-t", "ed25519"], passphrase: "secret-123")
        keygen(rsa, type: ["-t", "rsa", "-b", "2048"], passphrase: "secret-123")
        BoundedProcess.run("/usr/bin/ssh-keygen", ["-q", "-t", "rsa", "-b", "2048", "-m", "PEM", "-f", pem.path, "-N", "secret-123"], timeout: 60)
        #expect(KeySetup.isEncrypted(plain) == false)
        #expect(KeySetup.isEncrypted(locked) == true)
        #expect(KeySetup.isEncrypted(rsa) == true)
        #expect(KeySetup.isEncrypted(pem) == true)
        #expect(KeySetup.isEncrypted(plain.appendingPathExtension("pub")) == nil)   // not a private key
        let keys = KeySetup.existingKeys(in: dir)
        #expect(Set(keys.map(\.name)) == ["locked", "pem", "plain", "rsa"])
        #expect(keys.first { $0.name == "locked" }?.isEncrypted == true)
    }

    @Test func createsKeysAndNeverReplacesOne() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let ed = dir.appendingPathComponent("id_ed25519_web")
        let key = try await KeySetup.generate(at: ed, comment: "tether-web", passphrase: "", type: .ed25519)
        #expect(key.type == "ssh-ed25519" && key.comment == "tether-web" && key.isEncrypted == false)
        let rsa = try await KeySetup.generate(at: dir.appendingPathComponent("id_rsa_web"), comment: "c", passphrase: "", type: .rsa)
        #expect(rsa.type == "ssh-rsa")
        let before = try Data(contentsOf: ed)
        await #expect(throws: (any Error).self) {
            _ = try await KeySetup.generate(at: ed, comment: "again", passphrase: "", type: .ed25519)
        }
        #expect(try Data(contentsOf: ed) == before)                                     // left as it was
        #expect(KeySetup.suggestedKeyURL(for: "web", in: dir).lastPathComponent == "id_ed25519_web_2")
        #expect(KeySetup.suggestedKeyURL(for: "web", type: .rsa, in: dir).lastPathComponent == "id_rsa_web_2")
        #expect(KeySetup.suggestedKeyURL(for: "db.example.com", in: dir).lastPathComponent == "id_ed25519_db_example_com")
    }

    /// The install script adds the key once and keeps ~/.ssh private.
    @Test func installScriptAddsTheKeyOnce() throws {
        let home = try tempDir(); defer { try? FileManager.default.removeItem(at: home) }
        let env = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let args = ["-c", KeySetup.installScript, "sh", "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITEST", "tether-web"]
        #expect(BoundedProcess.run("/bin/sh", args, environment: env, timeout: 20).output.trimmingCharacters(in: .whitespacesAndNewlines) == "added")
        #expect(BoundedProcess.run("/bin/sh", args, environment: env, timeout: 20).output.trimmingCharacters(in: .whitespacesAndNewlines) == "exists")
        let file = home.appendingPathComponent(".ssh/authorized_keys")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITEST tether-web\n")
        let dirMode = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(".ssh").path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700 && fileMode == 0o600)
    }
}
