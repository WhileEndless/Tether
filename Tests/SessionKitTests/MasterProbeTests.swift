import Foundation
import Testing
@testable import SessionKit

/// After a network outage only shared connections that no longer reach their server are closed:
/// the check runs `exit 0` over the existing link, and only ssh's own failure (255) counts as dead.
@Suite struct MasterProbeTests {
    func fakeSSH(_ body: String, in dir: URL) throws -> String {
        let url = dir.appendingPathComponent("ssh-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func judgesConnections() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Alive: the remote command ran.
        #expect(await SessionManager.probeMaster("/nonexistent", ssh: try fakeSSH("exit 0", in: dir), timeout: 5) == true)
        // A Windows server answering with its own exit status is alive too.
        #expect(await SessionManager.probeMaster("/nonexistent", ssh: try fakeSSH("exit 1", in: dir), timeout: 5) == true)
        // Full (sshd MaxSessions) but alive.
        #expect(await SessionManager.probeMaster("/nonexistent", ssh: try fakeSSH("echo 'channel 2: open failed: administratively prohibited: open failed' >&2; echo 'Session open refused by peer' >&2; exit 255", in: dir), timeout: 5) == true)
        // ssh itself failed: the link is gone.
        #expect(await SessionManager.probeMaster("/nonexistent", ssh: try fakeSSH("echo 'Connection to tether-master closed by remote host.' >&2; exit 255", in: dir), timeout: 5) == false)
        // No answer in time: undecided (checked again later instead of being closed).
        #expect(await SessionManager.probeMaster("/nonexistent", ssh: try fakeSSH("exec sleep 10", in: dir), timeout: 1) == nil)
    }

    @Test func onlySocketsAreProbed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("connect-1.log")
        try "x".write(to: log, atomically: true, encoding: .utf8)
        #expect(!SessionManager.isSocket(log.path))
        #expect(!SessionManager.isSocket(dir.path))
    }
}
