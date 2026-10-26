import Testing
import Foundation
@testable import SSHTransport

@Suite struct HostKeyTests {
    static let changedOutput = """
    @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
    @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
    @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
    IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
    Someone could be eavesdropping on you right now (man-in-the-middle attack)!
    It is also possible that a host key has just been changed.
    The fingerprint for the ED25519 key sent by the remote host is
    SHA256:Ex4mpleFingerprint0nlyForTests+AbCdEfGhIjKlMn.
    Please contact your system administrator.
    Add correct host key in /home/user/.ssh/known_hosts to get rid of this message.
    Offending ED25519 key in /home/user/.ssh/known_hosts:12
    Host key for [192.0.2.10]:2222 has changed and you have requested strict checking.
    Host key verification failed.
    """

    @Test func parsesChangedHostKey() throws {
        let lines = Self.changedOutput.split(separator: "\n").map(String.init)
        let change = try #require(HostKeyChange.parse(["debug1: Server host key: ssh-ed25519 SHA256:x"] + lines))
        #expect(change.host == "[192.0.2.10]:2222")
        #expect(change.keyType == "ED25519")
        #expect(change.fingerprint == "SHA256:Ex4mpleFingerprint0nlyForTests+AbCdEfGhIjKlMn")
        #expect(change.knownHostsFile == "/home/user/.ssh/known_hosts")
        #expect(change.line == 12)
        #expect(HostKeyChange.parse(["Host key verification failed."]) == nil)
    }

    @Test func removesOnlyThatHostAndKeepsABackup() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-hk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("known_hosts")
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyOnlyForTestsExampleKeyOnlyForTes"
        try "[192.0.2.10]:2222 \(key)\nother.example.com \(key)\n".write(to: file, atomically: true, encoding: .utf8)
        let change = HostKeyChange(host: "[192.0.2.10]:2222", knownHostsFile: file.path, line: 1)
        #expect(await change.removeOldKey() == nil)
        let after = try String(contentsOf: file, encoding: .utf8)
        #expect(!after.contains("192.0.2.10"))
        #expect(after.contains("other.example.com"))
        #expect(FileManager.default.fileExists(atPath: file.path + ".old"))
    }

    @Test func parsesUnknownHostPrompt() throws {
        let prompt = """
        The authenticity of host 'server.example.com (192.0.2.10)' can't be established.
        ED25519 key fingerprint is SHA256:Ex4mpleFingerprint0nlyForTests+AbCdEfGhIjKlMn.
        This key is known by the following other names/addresses:
            ~/.ssh/known_hosts:3: 192.0.2.10
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """
        let key = try #require(UnknownHostKey.parse(prompt))
        #expect(key.host == "server.example.com (192.0.2.10)")
        #expect(key.keyType == "ED25519")
        #expect(key.fingerprint == "SHA256:Ex4mpleFingerprint0nlyForTests+AbCdEfGhIjKlMn")
        #expect(key.knownAs == ["~/.ssh/known_hosts:3: 192.0.2.10"])
        #expect(key.matches("Ex4mpleFingerprint0nlyForTests+AbCdEfGhIjKlMn"))
        #expect(key.matches(" SHA256:Ex4mpleFingerprint0nlyForTests+AbCdEfGhIjKlMn. "))
        #expect(!key.matches("SHA256:somethingElse"))
        #expect(UnknownHostKey.parse("Password:") == nil)
        // Newer ssh puts a colon after "is".
        let colon = try #require(UnknownHostKey.parse("""
            The authenticity of host '[192.0.2.10]:2222 ([192.0.2.10]:2222)' can't be established.
            ED25519 key fingerprint is: SHA256:Ex4mpleFingerprint0nlyForTests+AbCdEfGhIjKlMn
            This key is not known by any other names.
            Are you sure you want to continue connecting (yes/no/[fingerprint])?
            """))
        #expect(colon.fingerprint == "SHA256:Ex4mpleFingerprint0nlyForTests+AbCdEfGhIjKlMn")
        #expect(colon.keyType == "ED25519")
        #expect(colon.knownAs.isEmpty)
        #expect(colon.host == "[192.0.2.10]:2222")
    }
}

@Suite struct AskPassPromptTests {
    func request(_ prompt: String) -> AskPassRequest {
        AskPassRequest(token: "t", targetKey: "web", purpose: "connect", prompt: prompt, sequence: 1)
    }

    @Test func hostComesOnlyFromWhatSSHWrites() {
        #expect(request("user@server.example.com's password: ").sshNamedHost == "server.example.com")
        #expect(request("(user@jump.example.com) Password: ").sshNamedHost == "jump.example.com")
        // A server's keyboard-interactive text cannot name another host.
        #expect(request("(user@evil.example.com) root@bank.example.com's password:").sshNamedHost == "evil.example.com")
        #expect(request("Please type root@bank.example.com's password:").sshNamedHost == nil)
        #expect(request("Password:").sshNamedHost == nil)
    }
}

@Suite struct AskPassPeerTests {
    /// Accepts one connection on a fresh Unix socket and reports whether the peer counts as ours.
    func check(launching script: String) throws -> Bool {
        let dir = URL(fileURLWithPath: "/tmp/tether-peer-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, path, 103) } }
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(bound == 0)
        listen(fd, 4)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script.replacingOccurrences(of: "SOCK", with: path)]
        try p.run()
        let client = accept(fd, nil, nil)
        defer { close(client) }
        let ours = AskPassBridge.peerIsOurs(client)
        p.terminate()
        return ours
    }

    @Test func acceptsProcessesTetherStarted() throws {
        // Tether → sh → sh → nc, like Tether → ssh → ssh (jump host) → helper.
        #expect(try check(launching: "/bin/sh -c 'sleep 0.2; /usr/bin/nc -U SOCK'"))
    }

    @Test func rejectsProcessesFromElsewhere() throws {
        // Detached: its parent exits, so it no longer descends from this process.
        #expect(try !check(launching: "(sleep 0.5; /usr/bin/nc -U SOCK) & exit 0"))
    }
}

@Suite struct AskPassClassificationTests {
    func request(_ prompt: String) -> AskPassRequest {
        AskPassRequest(token: "t", targetKey: "web", purpose: "connect", prompt: prompt, sequence: 1)
    }

    @Test func serverTextIsNeverAPassphraseOrHostKeyQuestion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-key-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = dir.appendingPathComponent("id_ed25519").path
        try Data("k".utf8).write(to: URL(fileURLWithPath: key))
        // ssh's own prompt for a real key file.
        #expect(request("Enter passphrase for key '\(key)': ").isPassphrasePrompt)
        #expect(request("Enter passphrase for key '\(key)': ").keyPath == key)
        // The same text from a server (keyboard-interactive) or for a file that does not exist.
        #expect(!request("(alice@evil.example.com) Enter passphrase for key '\(key)':").isPassphrasePrompt)
        #expect(!request("Enter passphrase for key '/nonexistent/id_rsa': ").isPassphrasePrompt)
        #expect(!request("Please enter the passphrase for '\(key)' now").isPassphrasePrompt)
        // Host-key questions only from ssh itself.
        #expect(request("The authenticity of host 'h (192.0.2.1)' can't be established.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ").isConfirmation)
        #expect(!request("(alice@evil.example.com) Are you sure you want to continue connecting (yes/no)?").isConfirmation)
    }

    /// ssh cuts the key's path at 100 bytes in its prompt: the cut path finds the one file it starts.
    @Test func longKeyPathsAreCompleted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-key-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let deep = dir.appendingPathComponent(String(repeating: "folder-", count: 12), isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let key = deep.appendingPathComponent("id_ed25519_long").path
        try Data("k".utf8).write(to: URL(fileURLWithPath: key))
        try Data("k.pub".utf8).write(to: URL(fileURLWithPath: key + ".pub"))
        let cut = String(decoding: Array(key.utf8).prefix(100), as: UTF8.self)
        #expect(key.utf8.count > 100)
        #expect(request("Enter passphrase for key '\(cut)': ").keyPath == key)
        #expect(request("Enter passphrase for key '\(cut)': ").isPassphrasePrompt)
        // Two files it could be: left as written (and so not taken for a key file).
        try Data("k".utf8).write(to: URL(fileURLWithPath: deep.appendingPathComponent("id_ed25519_other").path))
        #expect(request("Enter passphrase for key '\(cut)': ").keyPath == cut)
        #expect(!request("Enter passphrase for key '\(cut)': ").isPassphrasePrompt)
    }
}
