import Foundation
import Testing
import TetherCore
import TestSupport
@testable import SSHTransport
@testable import FileTransferKit

/// Mixed folders and files through the host's shared connection (as in the app): packed and file
/// by file, both ways, everything arrives.
@MainActor
@Suite(.serialized) final class SharedMixedTests {
    let dir: URL
    let ssh: URL
    let scp: URL

    init() throws {
        // Short: Unix socket paths are limited to 104 bytes.
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tsm-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ssh = try FakeSharedSSH.install(in: dir)
        scp = dir.appendingPathComponent("scp")
        try #"""
        #!/bin/sh
        n=$#; i=0; src=""; dst=""
        for a; do i=$((i+1)); [ $i -eq $((n-1)) ] && src="$a"; [ $i -eq $n ] && dst="$a"; done
        exec /bin/cp -R "${src#*:}" "${dst#*:}"
        """#.write(to: scp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scp.path)
    }

    deinit {
        FakeSharedSSH.stopMasters(in: dir)
        try? FileManager.default.removeItem(at: dir)
    }

    private func put(_ path: String, _ text: String, in base: URL) throws {
        let url = base.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func tree(_ base: URL) -> [String] {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: base.path) else { return [] }
        var lines: [String] = []
        while let rel = e.nextObject() as? String {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: base.appendingPathComponent(rel).path, isDirectory: &isDir)
            lines.append(isDir.boolValue ? rel + "/" : rel + ": " + ((try? String(contentsOf: base.appendingPathComponent(rel), encoding: .utf8)) ?? "?"))
        }
        return lines.sorted()
    }

    @Test func mixedItemsBothWaysThroughTheSharedConnection() async throws {
        await SharedConnectionsTestLock.shared.acquire()
        await SharedConnections.shared.useSocketDirectory(dir)
        let outcome: Result<Void, Error>
        do { try await run(); outcome = .success(()) } catch { outcome = .failure(error) }
        await SharedConnections.shared.reset()
        await SharedConnectionsTestLock.shared.release()
        try outcome.get()
    }

    private func run() async throws {
        let target = ConnectionTarget.alias("mixed-\(UUID().uuidString.prefix(4))")
        var options = SSHOptions(sshBinary: ssh.path, useControlMaster: true)
        options.scpBinary = scp.path
        let remote = dir.appendingPathComponent("remote")
        try put("Pics/a b/ç.jpg", "jpg", in: remote)
        for i in 0..<6 { try put("Pics/many/\(i).txt", "\(i)", in: remote) }
        try FileManager.default.createDirectory(at: remote.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        try put("notes.txt", "n", in: remote)
        let fs = RemoteFileSystem(executor: RemoteExecutor(target: target, options: options))
        for mode in [TransferArchiveMode.always, .never, .auto] {
            for compression in [TransferCompression.off, .auto] {
                let m = TransferManager(options: { options }, policy: {
                    TransferPolicy(parallel: 3, archiveMode: mode, archiveThreshold: 5, compression: compression, adaptToSlowHosts: false)
                })
                let picked = try await fs.list(remote.path).files.filter { ["Pics", "Empty", "notes.txt"].contains($0.name) }
                #expect(picked.count == 3)
                let local = dir.appendingPathComponent("l-\(mode)-\(compression)")
                let got: TransferManager.DownloadOutcome? = await withCheckedContinuation { c in
                    m.downloadItems(picked, from: target, to: local, fs: fs) { c.resume(returning: $0) }
                }
                #expect(got?.failed == 0, "\(mode) \(compression): \(got?.message ?? "nil")")
                #expect(tree(local) == tree(remote), "down \(mode) \(compression)")
                // And back up into a new folder.
                let up = dir.appendingPathComponent("u-\(mode)-\(compression)")
                let files = ["Pics", "Empty", "notes.txt"].map { remote.appendingPathComponent($0) }
                let names = try await fs.uniqueNames(in: up.path, for: files.map(\.lastPathComponent))
                let size = LocalFiles.measure(files)
                let sent: [TransferItem] = await withCheckedContinuation { c in
                    m.uploadGroup(files, names: names, to: up.path, target: target, fileCount: size.files, totalBytes: size.bytes) { c.resume(returning: $0) }
                }
                #expect(sent.allSatisfy { $0.state == .completed }, "up \(mode) \(compression): \(sent.map { "\($0.state)" })")
                #expect(tree(up) == tree(remote), "up \(mode) \(compression)")
            }
        }
    }
}
