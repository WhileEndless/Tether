import Foundation
import Testing
import TetherCore
import TestSupport
@testable import SSHTransport
@testable import FileTransferKit

/// A server that does not answer (its connection died unnoticed, a firewall drops everything) holds
/// up only its own transfers: copies waiting for it must not keep every other server's copies queued.
@MainActor
@Suite(.serialized) final class TransferFairnessTests {
    let dir: URL
    let scp: URL

    init() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ttf-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // scp: a copy from a host named "stuck-…" hears nothing, ever (like a server that does not
        // answer); any other host copies locally.
        scp = dir.appendingPathComponent("scp")
        try #"""
        #!/bin/sh
        n=$#; i=0; src=""; dst=""
        for a in "$@"; do i=$((i+1)); [ $i -eq $((n-1)) ] && src="$a"; [ $i -eq $n ] && dst="$a"; done
        case "$src" in stuck-*) exec sleep 60;; esac
        exec /bin/cp -R "${src#*:}" "${dst#*:}"
        """#.write(to: scp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scp.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func aServerThatDoesNotAnswerDoesNotHoldUpOthers() async throws {
        var options = SSHOptions(useControlMaster: false)
        options.scpBinary = scp.path
        let manager = TransferManager(options: { options }, policy: { TransferPolicy(parallel: 2, archiveMode: .never) })
        manager.timeouts.unanswered = 0.5
        defer { manager.cancelAll() }
        let src = dir.appendingPathComponent("src"), down = dir.appendingPathComponent("down")
        for d in [src, down] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try "data".write(to: src.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)

        let stuck = ConnectionTarget.alias("stuck-\(UUID().uuidString.prefix(4))")
        let other = ConnectionTarget.alias("other-\(UUID().uuidString.prefix(4))")
        let waiting = (0..<4).map { i in
            manager.download(src.appendingPathComponent("f.txt").path, to: down.appendingPathComponent("s\(i).txt"), target: stuck)
        }
        var done: TransferItem?
        let start = Date()
        manager.download(src.appendingPathComponent("f.txt").path, to: down.appendingPathComponent("o.txt"), target: other) { done = $0 }
        for _ in 0..<3000 where done == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(done?.state == .completed, "the other server's copy ran (\(done.map { "\($0.state)" } ?? "still queued"))")
        // Without this, it waited for the silent server's copies to fail as stalled (ten minutes).
        #expect(Date().timeIntervalSince(start) < 30)
        #expect(waiting.filter { $0.state == .running }.count == 2, "the silent server keeps its places, and gets no more")
        #expect(waiting.filter { $0.state == .queued }.count == 2)

        manager.cancelAll()
        for _ in 0..<500 where !waiting.allSatisfy(\.isFinished) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(waiting.allSatisfy { $0.state == .cancelled })
    }
}
