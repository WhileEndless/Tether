import Foundation
import Testing
import TetherCore
import TestSupport
@testable import SSHTransport
@testable import FileTransferKit

/// Many files copied at once, either way, sign in to the server once: every copy waits for the
/// host's one shared connection and then runs through it (never a sign-in of its own).
@MainActor
@Suite(.serialized) final class TransferSignInTests {
    let dir: URL
    let ssh: URL
    let scp: URL

    init() throws {
        // Short: Unix socket paths are limited to 104 bytes.
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tts-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ssh = try FakeSharedSSH.install(in: dir)
        // scp: a client of the shared connection copies (locally); one that would sign in itself
        // (not a client) or finds no connection is noted and fails.
        scp = dir.appendingPathComponent("scp")
        try #"""
        #!/bin/sh
        D="\#(dir.path)"
        cp=""; master=""; prev=""
        for a in "$@"; do
          if [ "$prev" = "-o" ]; then case "$a" in ControlPath=*) cp="${a#ControlPath=}";; ControlMaster=no) master=no;; esac; fi
          prev="$a"
        done
        if [ "$master" != "no" ]; then echo "own" >> "$D/logins.log"; exit 255; fi
        if [ ! -e "$cp.alive" ]; then echo "no connection" >&2; exit 255; fi
        n=$#; i=0; src=""; dst=""
        for a in "$@"; do i=$((i+1)); [ $i -eq $((n-1)) ] && src="$a"; [ $i -eq $n ] && dst="$a"; done
        src="${src#*:}"; dst="${dst#*:}"
        exec /bin/cp -R "$src" "$dst"
        """#.write(to: scp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scp.path)
    }

    deinit {
        FakeSharedSSH.stopMasters(in: dir)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func manyFilesEitherWaySignInOnce() async throws {
        await SharedConnectionsTestLock.shared.acquire()
        await SharedConnections.shared.useSocketDirectory(dir)
        // Reset before the folder goes (in deinit), whatever happens in the test.
        let outcome: Result<Void, Error>
        do { try await signInOnce(); outcome = .success(()) } catch { outcome = .failure(error) }
        await SharedConnections.shared.reset()
        await SharedConnectionsTestLock.shared.release()
        try outcome.get()
    }

    private func signInOnce() async throws {
        let target = ConnectionTarget.alias("files-\(UUID().uuidString.prefix(4))")
        var options = SSHOptions(sshBinary: ssh.path, useControlMaster: true)
        options.scpBinary = scp.path
        let manager = TransferManager(options: { options }, policy: { TransferPolicy(parallel: 3, archiveMode: .never) })
        let src = dir.appendingPathComponent("src"), up = dir.appendingPathComponent("up"), down = dir.appendingPathComponent("down")
        for d in [src, up, down] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        for i in 0..<10 { try "file \(i)".write(to: src.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8) }

        var finished: [TransferItem] = []
        for i in 0..<10 {
            manager.upload(src.appendingPathComponent("f\(i).txt"), to: up.path, target: target) { finished.append($0) }
            manager.download(src.appendingPathComponent("f\(i).txt").path, to: down.appendingPathComponent("f\(i).txt"), target: target) {
                finished.append($0)
            }
        }
        for _ in 0..<1000 where finished.count < 20 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(finished.count == 20)
        #expect(finished.allSatisfy { $0.state == .completed }, "\(finished.map { "\($0.state)" })")
        let logins = FakeSharedSSH.logins(in: dir)
        #expect(logins.filter { $0 == "start" }.count == 1, "one sign-in for twenty copies (\(logins))")
        #expect(!logins.contains("own"), "no copy signed in on its own")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: up.path))?.count == 10)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: down.path))?.count == 10)
    }
}
