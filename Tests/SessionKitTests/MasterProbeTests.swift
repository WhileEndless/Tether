import Foundation
import Testing
@testable import SessionKit
@testable import SSHTransport

/// After a network outage only shared connections that no longer reach their server are closed.
/// The check asks the server, over the existing link, to forward to a closed port on itself:
/// nothing runs there, and its refusal — at once — means alive; only silence means dead. (The
/// answers below are those of OpenSSH 10 through a real shared connection.)
@Suite struct MasterProbeTests {
    func fakeSSH(_ body: String, in dir: URL) throws -> String {
        let url = dir.appendingPathComponent("ssh-\(UUID().uuidString)")
        try "#!/bin/sh\necho \"$*\" > \"$0.args\"\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    @Test func judgesConnections() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Alive: the server refused the forward (also where forwarding is forbidden).
        let refused = try fakeSSH("echo 'Stdio forwarding request failed: Session open refused by peer' >&2; exit 255", in: dir)
        #expect(await SessionManager.probeMaster("/nonexistent", ssh: refused, timeout: 5) == true)
        let args = (try? String(contentsOfFile: refused + ".args", encoding: .utf8)) ?? ""
        #expect(args.contains("-W 127.0.0.1:9") && !args.contains("exit 0"), "nothing is run on the server")
        // An older answer for the same: the channel could not be opened.
        #expect(await SessionManager.probeMaster("/nonexistent", ssh: try fakeSSH("echo 'channel 0: open failed: connect failed: Connection refused' >&2; exit 255", in: dir), timeout: 5) == true)
        // The socket is gone: dead.
        #expect(await SessionManager.probeMaster("/nonexistent", ssh: try fakeSSH("echo 'Connection closed by UNKNOWN port 65535' >&2; exit 255", in: dir), timeout: 5) == false)
        // ssh itself failed otherwise: the link is gone.
        #expect(await SessionManager.probeMaster("/nonexistent", ssh: try fakeSSH("echo 'Connection to tether-master closed by remote host.' >&2; exit 255", in: dir), timeout: 5) == false)
        // No answer in time (a link that went silent): undecided, checked again until the limit.
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
