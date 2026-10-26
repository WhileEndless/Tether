import Foundation
import Testing
import TetherCore
@testable import SSHTransport

/// Network devices and limited shells (Cisco, Junos, FortiOS, RouterOS, menus, git-shell) are told
/// apart from shells — also unusual ones such as csh — and once known, Tether sends them nothing.
@Suite(.serialized) struct DeviceShellTests {
    /// A fake `ssh` that answers every remote command as `body` (POSIX sh) says, and notes each
    /// command line it got in `calls`.
    func fakeSSH(_ body: String) throws -> (ssh: URL, calls: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-device-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ssh = dir.appendingPathComponent("ssh"), calls = dir.appendingPathComponent("calls")
        let script = """
        #!/bin/sh
        for last in "$@"; do :; done
        printf '%s\\n' "$last" >> '\(calls.path)'
        cmd="$last"
        \(body)
        """
        try script.write(to: ssh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh.path)
        return (ssh, calls, dir)
    }

    func executor(_ ssh: URL) -> RemoteExecutor {
        var o = SSHOptions()
        o.sshBinary = ssh.path
        o.useControlMaster = false
        return RemoteExecutor(target: .alias("device-\(UUID().uuidString.prefix(8))"), options: o)
    }

    @Test func probeAnswersAreReadSafely() {
        // A CLI that shows the command it rejected is not a shell that answered.
        #expect(RemotePlatform.parse(probeOutput: #"echo "TETHER:%OS%:$PSHOME:""# + "\n% Invalid input\n") == nil)
        #expect(ShellAccess.answersShell("Welcome\nTETHER-SHELL\n"))
        #expect(!ShellAccess.answersShell("echo TETHER-SHELL\n% Unknown command"))
        #expect(!ShellAccess.answersShell("bad command name echo (line 1 column 1)"))
        // A future choice an older build does not know is read as "automatic", never as an error.
        let decoded = try? JSONDecoder().decode([ShellAccess].self, from: Data(#"["device","something-new"]"#.utf8))
        #expect(decoded == [.device, .automatic])
    }

    @Test func deviceCLIIsRecognisedAndGetsNothing() async throws {
        let (ssh, calls, dir) = try fakeSSH(#"printf '%s\n' "$cmd" "% Invalid input detected at '^' marker."; exit 1"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ex = executor(ssh)
        _ = await ex.resolvedPlatform()
        #expect(PlatformCache.shared.isDevice(ex.target.key))
        let before = try String(contentsOf: calls, encoding: .utf8)
        // A script is refused before anything is sent.
        let r = await ex.run(script: "echo hi", timeout: 10)
        #expect(r.status == 127 && r.errorOutput.contains("network device"))
        #expect(try String(contentsOf: calls, encoding: .utf8) == before)
        // The user can say otherwise.
        PlatformCache.shared.setAccess(.scripts, for: ex.target.key)
        #expect(!PlatformCache.shared.isDevice(ex.target.key))
        PlatformCache.shared.forget(ex.target.key)
    }

    @Test func cshIsAShellNotADevice() async throws {
        // csh rejects `$PSHOME` ("Undefined variable") but answers the plain question.
        let (ssh, _, dir) = try fakeSSH(#"case "$cmd" in *PSHOME*) echo "PSHOME: Undefined variable." >&2; exit 1;; *) echo TETHER-SHELL;; esac"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ex = executor(ssh)
        #expect(await ex.resolvedPlatform() == .posix)
        #expect(!PlatformCache.shared.isDevice(ex.target.key))
        PlatformCache.shared.forget(ex.target.key)
    }

    @Test func unreachableHostIsNotCalledADevice() async throws {
        let (ssh, _, dir) = try fakeSSH(#"echo "ssh: connect to host: Connection refused" >&2; exit 255"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ex = executor(ssh)
        _ = await ex.resolvedPlatform()
        #expect(!PlatformCache.shared.isDevice(ex.target.key))
        #expect(PlatformCache.shared.cached(ex.target.key) == nil)      // asked again later
    }
}
