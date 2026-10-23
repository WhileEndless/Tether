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
    SHA256:LYQhmhu+7Yq30NinqEHgUdW2W+a/pA5nErYBwRVDQJw.
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
        #expect(change.fingerprint == "SHA256:LYQhmhu+7Yq30NinqEHgUdW2W+a/pA5nErYBwRVDQJw")
        #expect(change.knownHostsFile == "/home/user/.ssh/known_hosts")
        #expect(change.line == 12)
        #expect(HostKeyChange.parse(["Host key verification failed."]) == nil)
    }

    @Test func removesOnlyThatHostAndKeepsABackup() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-hk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("known_hosts")
        let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
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
        ED25519 key fingerprint is SHA256:LYQhmhu+7Yq30NinqEHgUdW2W+a/pA5nErYBwRVDQJw.
        This key is known by the following other names/addresses:
            ~/.ssh/known_hosts:3: 192.0.2.10
        Are you sure you want to continue connecting (yes/no/[fingerprint])?
        """
        let key = try #require(UnknownHostKey.parse(prompt))
        #expect(key.host == "server.example.com (192.0.2.10)")
        #expect(key.keyType == "ED25519")
        #expect(key.fingerprint == "SHA256:LYQhmhu+7Yq30NinqEHgUdW2W+a/pA5nErYBwRVDQJw")
        #expect(key.knownAs == ["~/.ssh/known_hosts:3: 192.0.2.10"])
        #expect(key.matches("LYQhmhu+7Yq30NinqEHgUdW2W+a/pA5nErYBwRVDQJw"))
        #expect(key.matches(" SHA256:LYQhmhu+7Yq30NinqEHgUdW2W+a/pA5nErYBwRVDQJw. "))
        #expect(!key.matches("SHA256:somethingElse"))
        #expect(UnknownHostKey.parse("Password:") == nil)
        // Newer ssh puts a colon after "is".
        let colon = try #require(UnknownHostKey.parse("""
            The authenticity of host '[192.0.2.10]:2222 ([192.0.2.10]:2222)' can't be established.
            ED25519 key fingerprint is: SHA256:LYQhmhu+7Yq30NinqEHgUdW2W+a/pA5nErYBwRVDQJw
            This key is not known by any other names.
            Are you sure you want to continue connecting (yes/no/[fingerprint])?
            """))
        #expect(colon.fingerprint == "SHA256:LYQhmhu+7Yq30NinqEHgUdW2W+a/pA5nErYBwRVDQJw")
        #expect(colon.keyType == "ED25519")
        #expect(colon.knownAs.isEmpty)
        #expect(colon.host == "[192.0.2.10]:2222")
    }
}
