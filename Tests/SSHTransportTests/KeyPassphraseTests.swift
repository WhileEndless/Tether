import Foundation
import Testing
@testable import SSHTransport

/// Key passphrases: what ssh's questions are taken for, how a passphrase is remembered for a run,
/// and when a terminal on this Mac is reading a secret.
@Suite struct KeyPassphraseTests {
    let key = SealedPasswordCache.passphrasePrefix + "/home/user/.ssh/id_example"

    func cache() -> SealedPasswordCache {
        let c = SealedPasswordCache(sealer: SealedPasswordCacheTests.FakeSealer())
        c.sshNamesItsQuestions = true
        return c
    }

    func lookup(_ c: SealedPasswordCache, connection: String, login: String) -> String? {
        let token = UUID().uuidString
        c.bind(token: token, connection: connection)
        return c.password(token: token, login: login)?.password
    }

    func request(_ prompt: String, kind: String? = nil) -> AskPassRequest {
        var r = AskPassRequest(token: "t", targetKey: "web", purpose: "connect", prompt: prompt, sequence: 1)
        r.askpassKind = kind
        r.askerNamesItsQuestions = true
        return r
    }

    // MARK: Remembered for the run

    /// One sign-in can open a key and then give the server's password (or open a jump host's key
    /// and the target's): everything it was given is kept once it worked.
    @Test func everythingOneSignInWasGivenIsKept() {
        let c = cache()
        c.bind(token: "t1", connection: "/s/abc")
        c.offer("example-passphrase", login: key, token: "t1", source: .typed)
        c.offer("example-password", login: "user@example.com", token: "t1", source: .typed)
        c.commit(token: "t1")
        #expect(lookup(c, connection: "/s/other", login: key) == "example-passphrase")
        #expect(lookup(c, connection: "/s/abc", login: "user@example.com") == "example-password")
    }

    /// The server refused the sign-in: the password it was answered with goes, the key's
    /// passphrase stays (the key opened with it; the server refused something else).
    @Test func aRefusedSignInKeepsTheKeysPassphrase() {
        let c = cache()
        for (secret, login) in [("example-passphrase", key), ("example-password", "user@example.com")] {
            c.bind(token: "first", connection: "/s/abc")
            c.offer(secret, login: login, token: "first", source: .typed)
            c.commit(token: "first")
        }
        c.bind(token: "t2", connection: "/s/abc")
        #expect(c.password(token: "t2", login: key)?.password == "example-passphrase")
        #expect(c.password(token: "t2", login: "user@example.com")?.password == "example-password")
        c.discard(token: "t2")
        #expect(lookup(c, connection: "/s/abc", login: key) == "example-passphrase")
        #expect(lookup(c, connection: "/s/abc", login: "user@example.com") == nil)
    }

    /// ssh asked for the key again after it was given the remembered passphrase: gone, and only it.
    @Test func aWrongPassphraseIsRejectedAlone() {
        let c = cache()
        c.bind(token: "t1", connection: "/s/abc")
        c.offer("example-passphrase", login: key, token: "t1", source: .typed)
        c.offer("example-password", login: "user@example.com", token: "t1", source: .typed)
        c.reject(token: "t1", login: key)
        c.commit(token: "t1")
        #expect(lookup(c, connection: "/s/abc", login: key) == nil)
        #expect(lookup(c, connection: "/s/abc", login: "user@example.com") == "example-password")
    }

    /// The passphrase was changed in Settings ▸ Keys: the old one is forgotten.
    @Test func forgettingALogin() {
        let c = cache()
        c.bind(token: "t1", connection: "/s/abc")
        c.offer("old-passphrase", login: key, token: "t1", source: .typed)
        c.commit(token: "t1")
        c.forget(login: key)
        #expect(lookup(c, connection: "/s/abc", login: key) == nil)
        #expect(c.count == 0)
    }

    // MARK: ssh's questions

    @Test func passphraseQuestionsNameAnExistingKeyFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-passphrase-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("id_example")
        try Data("not a real key".utf8).write(to: file)

        let real = request("Enter passphrase for key '\(file.path)': ")
        #expect(real.isPassphrasePrompt)
        #expect(real.keyPath == file.path)
        #expect(!request("Enter passphrase for key '\(dir.path)/missing': ").isPassphrasePrompt, "no such file here")
        #expect(!request("(user@example.com) Enter passphrase for key '\(file.path)': ").isPassphrasePrompt, "a server's text")
        #expect(!request("Enter passphrase for key '\(file.path)': ", kind: "confirm").isPassphrasePrompt)

        // An ssh that does not mark a server's questions (older than 8.4, or not checked): the
        // server may have written it — never taken for the key's own question.
        var old = AskPassRequest(token: "t", targetKey: "web", purpose: "connect", prompt: "Enter passphrase for key '\(file.path)': ", sequence: 1)
        #expect(!old.isPassphrasePrompt && old.isUnverifiedPassphrasePrompt)
        old.askerNamesItsQuestions = true
        #expect(old.isPassphrasePrompt && !old.isUnverifiedPassphrasePrompt)
    }

    // MARK: Which ssh asks

    /// Each ssh program is asked its version once, and again when the file changes.
    /// A password question from an ssh that does not mark a server's questions (older than 8.4,
    /// perhaps a ProxyCommand's) is flagged: nothing is filled in for it by itself.
    @Test func passwordQuestionsFromAnUncheckedSSHAreFlagged() {
        var r = AskPassRequest(token: "t", targetKey: "web", purpose: "connect", prompt: "user@web.example.com's password: ", sequence: 1)
        #expect(r.isPlainPasswordPrompt && r.isUnverifiedPasswordPrompt)
        r.askerNamesItsQuestions = true
        #expect(r.isPlainPasswordPrompt && !r.isUnverifiedPasswordPrompt)
        let code = AskPassRequest(token: "t", targetKey: "web", purpose: "connect", prompt: "Verification code: ", sequence: 1)
        #expect(!code.isUnverifiedPasswordPrompt)
    }

    @Test func sshVersionIsCheckedPerProgramFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-ssh-version-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ssh = dir.appendingPathComponent("ssh")
        func write(_ version: String) throws {
            try Data("#!/bin/sh\necho '\(version), LibreSSL 3.3.6' >&2\n".utf8).write(to: ssh)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh.path)
        }
        let check = SSHVersionCheck()
        try write("OpenSSH_8.3p1")
        #expect(await check.namesItsQuestions(path: ssh.path) == false)
        try write("OpenSSH_9.6p1 (updated)")
        #expect(await check.namesItsQuestions(path: ssh.path) == true, "the file changed: asked again")
        #expect(await check.namesItsQuestions(path: dir.appendingPathComponent("missing").path) == false)
    }

    /// Only a program named ssh is asked; this test process is none.
    @Test func onlyAnSSHProgramIsTrusted() async {
        #expect(AskingProcess.executablePath(getpid()) != nil)
        #expect(await AskingProcess.namesItsQuestions(pid: getpid()) == false)
        #expect(await AskingProcess.namesItsQuestions(pid: 0) == false)
        #expect(AskingProcess.group(getpgrp()).contains(getpid()))
    }

    /// A security key's PIN is a secret but never a passphrase (never remembered); its touch
    /// notice and ssh's yes/no questions are neither.
    @Test func securityKeyAndAgentQuestions() {
        let pin = request("Enter PIN for ED25519-SK key /home/user/.ssh/id_example_sk: ")
        #expect(pin.isSecret && !pin.isPassphrasePrompt && !pin.isPasswordPrompt)

        let touch = request("Confirm user presence for key ED25519-SK SHA256:abc", kind: "none")
        #expect(touch.isNotice && !touch.isSecret && !touch.isConfirmation && !touch.isPermissionQuestion)

        let add = request("Add key /home/user/.ssh/id_example (user@example.com) to agent?", kind: "confirm")
        #expect(add.isPermissionQuestion && !add.isNotice && !add.isSecret && !add.isConfirmation)
        #expect(!request("(user@example.com) Allow?", kind: "confirm").isPermissionQuestion, "a server's text")

        let hostKey = request("Are you sure you want to continue connecting (yes/no/[fingerprint])? ")
        #expect(hostKey.isConfirmation && !hostKey.isPermissionQuestion && !hostKey.isNotice)
    }

    // MARK: A terminal on this Mac

    /// Line-by-line input with echo off is a program on this Mac reading a secret; raw mode (an
    /// ssh connected to a server) and normal echo are not.
    @Test func readingASecretOnlyInCanonicalModeWithoutEcho() async throws {
        var controller: Int32 = -1, terminal: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        try #require(openpty(&controller, &terminal, &name, nil, nil) == 0)
        defer { close(controller); close(terminal) }
        let path = String(cString: name)

        var t = termios()
        try #require(tcgetattr(terminal, &t) == 0)
        t.c_lflag |= tcflag_t(ICANON | ECHO)
        tcsetattr(terminal, TCSANOW, &t)
        #expect(LocalTTY.isReadingSecret(path: path) == false, "echo on: not a secret")

        t.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(terminal, TCSANOW, &t)
        #expect(LocalTTY.isReadingSecret(path: path) == true, "readpassphrase's state")

        cfmakeraw(&t)
        tcsetattr(terminal, TCSANOW, &t)
        #expect(LocalTTY.isReadingSecret(path: path) == false, "raw: a connected ssh")

        // Waiting for a secret, but no program in its foreground can be named: refused.
        t.c_lflag |= tcflag_t(ICANON)
        t.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(terminal, TCSANOW, &t)
        #expect(LocalTTY.isReadingSecret(path: path) == true)
        #expect(await LocalTTY.refusalToTypeKeyPassphrase(path: path) != nil)

        #expect(LocalTTY.isReadingSecret(path: "/dev/tether-no-such-terminal") == nil)
        #expect(await LocalTTY.refusalToTypeKeyPassphrase(path: "/dev/tether-no-such-terminal") != nil)
        #expect(LocalTTY.path(ofProcess: -1) == nil)
    }
}
