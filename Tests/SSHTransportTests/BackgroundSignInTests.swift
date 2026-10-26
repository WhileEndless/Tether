import Testing
import Foundation
import TetherCore
@testable import SSHTransport

/// Background work (monitoring, latency, the platform check) never asks for a password: it runs
/// with BatchMode, and a host found to need the user gets no more ssh attempts until a tab signs in.
@Suite struct BackgroundSignInTests {
    @Test func quietWorkUsesBatchMode() {
        let o = SSHOptions()
        let quiet = o.batchArguments(target: .alias("web"), remoteCommand: "true", quiet: true)
        let asked = o.batchArguments(target: .alias("web"), remoteCommand: "true")
        #expect(quiet.contains("BatchMode=yes"))
        #expect(!asked.contains("BatchMode=yes"))
        // BatchMode comes before the destination, which ends the options (`--`).
        if let b = quiet.firstIndex(of: "BatchMode=yes"), let d = quiet.firstIndex(of: "--") { #expect(b < d) }
        #expect(SSHOptions.isQuietPurpose("monitor") && SSHOptions.isQuietPurpose("latency"))
        #expect(!SSHOptions.isQuietPurpose("files") && !SSHOptions.isQuietPurpose("kill") && !SSHOptions.isQuietPurpose("connect"))
    }

    @Test func recognisesLoginsThatNeedSomeone() {
        #expect(BackgroundSignIn.reasonFor(stderr: "user@example.com: Permission denied (publickey,password).") == .password)
        #expect(BackgroundSignIn.reasonFor(stderr: "Host key verification failed.") == .hostKey)
        // Through a jump host, ssh names the hop.
        #expect(BackgroundSignIn.reasonFor(stderr: "user@jump.example.com: Permission denied (publickey).\nConnection closed by UNKNOWN port 65535") == .password)
        #expect(!BackgroundSignIn.needsInteraction("ssh: connect to host example.com port 22: Connection refused"))
        #expect(!BackgroundSignIn.needsInteraction("ssh: Could not resolve hostname example.com"))
        // A remote program's own complaints (reading /proc as another user) are not a sign-in problem.
        #expect(!BackgroundSignIn.needsInteraction("cat: /proc/1/environ: Permission denied\nss: Permission denied\nClient_loop: send disconnect: Broken pipe"))
        #expect(!BackgroundSignIn.needsInteraction("Enter passphrase for key"))
    }

    /// A fake ssh that counts its runs and refuses like a server that wants a password.
    @Test func hostThatNeedsAPasswordGetsNoMoreQuietAttempts() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-signin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let count = dir.appendingPathComponent("runs")
        let ssh = dir.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        echo run >> '\(count.path)'
        echo 'user@example.com: Permission denied (publickey,password).' >&2
        exit 255
        """.write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
        func runs() -> Int { ((try? String(contentsOf: count, encoding: .utf8)) ?? "").split(separator: "\n").count }

        let target = ConnectionTarget.alias("signin-\(UUID().uuidString)")
        defer { BackgroundSignIn.shared.clear(target.key) }
        let executor = RemoteExecutor(target: target, options: SSHOptions(sshBinary: ssh.path, useControlMaster: false))

        let first = await executor.run(script: ":", timeout: 10, purpose: "monitor")
        #expect(!first.succeeded)
        #expect(BackgroundSignIn.shared.isWaiting(target.key))
        let afterFirst = runs()
        #expect(afterFirst >= 1)

        // Quiet work now stops before starting ssh, and says why.
        let second = await executor.run(script: ":", timeout: 10, purpose: "latency")
        #expect(runs() == afterFirst)
        #expect(second.errorOutput.hasPrefix(BackgroundSignIn.marker))

        // Something the user asked for still tries (and may ask).
        _ = await executor.run(script: ":", timeout: 10, purpose: "files")
        #expect(runs() > afterFirst)

        // A tab signed in: background work may run again.
        BackgroundSignIn.shared.clear(target.key)
        #expect(await executor.backgroundWorkAllowed())
    }

    /// A prompt is withdrawn when the helper behind it goes away (its ssh ended).
    @Test func noticesAHelperThatHungUp() {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        // As the app's accepted sockets: not inherited by processes other tests start meanwhile.
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        defer { close(fds[0]) }
        #expect(!AskPassBridge.peerHungUp(fds[0]))
        close(fds[1])
        // A child started in the instant before FD_CLOEXEC was set may still hold the other end
        // until it exits: give it a moment.
        var hungUp = false
        for _ in 0..<40 where !hungUp {
            hungUp = AskPassBridge.peerHungUp(fds[0])
            if !hungUp { usleep(50_000) }
        }
        #expect(hungUp)
    }

    /// Only ssh's own password question may be remembered for a host's other logins — never a
    /// one-time code or a server's "New password:" (keyboard-interactive text the server writes).
    @Test func rememberableOnlyForSSHsOwnPasswordQuestion() {
        func r(_ prompt: String) -> AskPassRequest {
            AskPassRequest(token: "t", targetKey: "web", purpose: "connect", prompt: prompt, sequence: 1)
        }
        #expect(r("user@web.example.com's password: ").isPlainPasswordPrompt)
        #expect(r("(user@web.example.com) Password: ").isPlainPasswordPrompt)
        #expect(!r("(user@web.example.com) One-time password: ").isPlainPasswordPrompt)
        #expect(!r("(user@web.example.com) New password: ").isPlainPasswordPrompt)
        #expect(!r("(user@web.example.com) Verification code: ").isPlainPasswordPrompt)
        #expect(!r("Enter passphrase for key '/tmp/none': ").isPlainPasswordPrompt)
    }

    /// Ending a sign-in ends what it started (a ProxyJump ssh), children found through the parent chain.
    @Test func findsChildProcesses() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 5 & wait"]
        try p.run()
        defer { if p.isRunning { p.terminate() } }
        var found: [pid_t] = []
        for _ in 0..<40 where found.isEmpty {
            found = AskPassBridge.descendants(of: [p.processIdentifier])
            if found.isEmpty { usleep(50_000) }
        }
        #expect(!found.isEmpty)
        for pid in found { kill(pid, SIGTERM) }
    }
}
