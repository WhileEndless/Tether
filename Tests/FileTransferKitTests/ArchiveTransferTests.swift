import Foundation
import Testing
import TetherCore
import SSHTransport
@testable import FileTransferKit

/// Packed (tar stream) transfers with real tar on both ends. "ssh" is a tiny shim that runs the
/// remote command with the local shell, so no server is needed.
@MainActor
@Suite(.serialized) final class ArchiveTransferTests {
    let root: URL
    let shim: URL
    let target = ConnectionTarget.adhoc(user: "user", host: "example.invalid", port: nil, jump: nil)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tether-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        shim = root.appendingPathComponent("fake-ssh")
        // The remote command is the last argument; everything before it is ssh options.
        try "#!/bin/sh\nfor a; do last=$a; done\nexec /bin/sh -c \"$last\"\n".write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func manager(parallel: Int = 3, mode: TransferArchiveMode = .auto, compression: TransferCompression = .off) -> TransferManager {
        var options = SSHOptions()
        options.sshBinary = shim.path
        options.useControlMaster = false
        return TransferManager(options: { options }, policy: {
            TransferPolicy(parallel: parallel, archiveMode: mode, archiveThreshold: 5, compression: compression,
                           adaptToSlowHosts: false)
        })
    }

    private func write(_ path: String, _ text: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String, in dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
    }

    private func wait(_ start: (@escaping ([TransferItem]) -> Void) -> Void) async -> [TransferItem] {
        await withCheckedContinuation { c in start { c.resume(returning: $0) } }
    }

    private func contents(of dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    @Test func packedUploadKeepsTreeAndNeverOverwrites() async throws {
        let src = root.appendingPathComponent("src"), dest = root.appendingPathComponent("dest dir")
        for i in 0..<30 { try write("project/sub \(i % 3)/file-\(i).txt", "content \(i)", in: src) }
        try write("project/ünïcode name.md", "u", in: src)
        try write("-dash.txt", "dash", in: src)
        try write("report.pdf", "new", in: src)
        try write("report.pdf", "old", in: dest)
        let files = ["project", "-dash.txt", "report.pdf"].map { src.appendingPathComponent($0) }

        let fs = RemoteFileSystem(executor: RemoteExecutor(target: .local, options: SSHOptions()))
        let names = try await fs.uniqueNames(in: dest.path, for: files.map(\.lastPathComponent))
        #expect(names == ["project", "-dash.txt", "report-1.pdf"])
        let size = LocalFiles.measure(files)
        #expect(size.files == 33)

        let m = manager()
        let items = await wait { done in
            m.uploadGroup(files, names: names, to: dest.path, target: target, fileCount: size.files,
                          totalBytes: size.bytes, completion: done)
        }
        #expect(items.count == 1)
        #expect(items[0].method == .archive)
        #expect(items[0].state == .completed)
        #expect(items[0].progress == 1)
        #expect(items[0].bytesDone > 0)
        #expect(read("project/sub 2/file-29.txt", in: dest) == "content 29")
        #expect(read("project/ünïcode name.md", in: dest) == "u")
        #expect(read("-dash.txt", in: dest) == "dash")
        #expect(read("report.pdf", in: dest) == "old")
        #expect(read("report-1.pdf", in: dest) == "new")
        #expect(items[0].entries.map(\.to).contains(dest.appendingPathComponent("report-1.pdf").path))
        #expect(items[0].entries.filter(\.renamed).count == 1)
        // No staging folder or macOS metadata files are left behind.
        #expect(contents(of: dest) == ["-dash.txt", "project", "report-1.pdf", "report.pdf"])
        #expect(!contents(of: dest.appendingPathComponent("project")).contains { $0.hasPrefix("._") })
    }

    @Test func packedUploadWithCompressionWorks() async throws {
        let src = root.appendingPathComponent("csrc"), dest = root.appendingPathComponent("cdest")
        for i in 0..<10 { try write("f\(i).log", String(repeating: "line \(i)\n", count: 500), in: src) }
        let files = (0..<10).map { src.appendingPathComponent("f\($0).log") }
        let m = manager(mode: .always, compression: .auto)
        let items = await wait { done in
            m.uploadGroup(files, names: files.map(\.lastPathComponent), to: dest.path, target: target,
                          fileCount: 10, totalBytes: nil, completion: done)
        }
        #expect(items.first?.state == .completed)
        #expect(contents(of: dest).count == 10)
    }

    /// Every way of compressing the stream this Mac has works both ways, byte for byte, and progress
    /// counts the files' own bytes (not the compressed ones).
    @Test func everyCompressionWorksBothWays() async throws {
        let methods = TransferCompression.methods.filter { m in m.program.flatMap { ArchiveJob.localPath($0) } != nil }
        #expect(methods.contains(.gzip), "gzip comes with macOS")
        for method in methods {
            let src = root.appendingPathComponent("z-\(method)"), up = root.appendingPathComponent("up-\(method)")
            let back = root.appendingPathComponent("back-\(method)")
            let text = (0..<4_000).map { "log line \($0) for \(method)" }.joined(separator: "\n")
            try write("data/big.log", text, in: src)
            for i in 0..<6 { try write("data/small-\(i).txt", "small \(i)", in: src) }
            let files = [src.appendingPathComponent("data")]
            let bytes = Int64(text.utf8.count + 6 * 7)
            let m = manager(mode: .always, compression: method)
            let sent = await wait { done in
                m.uploadGroup(files, names: ["data"], to: up.path, target: target, fileCount: 7, totalBytes: bytes, completion: done)
            }
            #expect(sent.first?.state == .completed, "\(method) up: \(String(describing: sent.first?.state))")
            #expect(sent.first?.compression == method)
            #expect(read("data/big.log", in: up) == text, "\(method) up")
            #expect((sent.first?.bytesDone ?? 0) > Int64(text.utf8.count), "counted before compression")
            try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
            let got = await wait { done in
                m.downloadGroup(["data"], from: up.path, to: back, as: ["data"], target: target, fileCount: 7, totalBytes: bytes, completion: done)
            }
            #expect(got.first?.state == .completed, "\(method) down: \(String(describing: got.first?.state))")
            #expect(got.first?.compression == method)
            #expect(read("data/big.log", in: back) == text, "\(method) down")
            #expect(read("data/small-5.txt", in: back) == "small 5")
        }
    }

    @Test func compressionIsOneBothEndsHave() {
        let both: Set<String> = ["gzip", "xz"]
        #expect(TransferCompression.auto.resolved(local: ["zstd", "gzip", "xz"], remote: both) == .gzip)
        #expect(TransferCompression.auto.resolved(local: ["zstd", "lz4", "gzip"], remote: ["zstd", "gzip"]) == .zstd)
        #expect(TransferCompression.xz.resolved(local: both, remote: both) == .xz)
        #expect(TransferCompression.zstd.resolved(local: ["zstd", "gzip"], remote: ["gzip"]) == .gzip, "falls back to one both have")
        #expect(TransferCompression.auto.resolved(local: ["gzip"], remote: []) == nil)
        #expect(TransferCompression.off.resolved(local: both, remote: both) == nil)
    }

    @Test func failedUploadLeavesNothingBehind() async throws {
        let src = root.appendingPathComponent("fsrc")
        for i in 0..<6 { try write("x\(i)", "x", in: src) }
        let files = (0..<6).map { src.appendingPathComponent("x\($0)") }
        // A file where the destination folder should be: mkdir fails on the "server".
        let blocker = root.appendingPathComponent("blocker")
        try "".write(to: blocker, atomically: true, encoding: .utf8)
        let m = manager()
        let items = await wait { done in
            m.uploadGroup(files, names: files.map(\.lastPathComponent), to: blocker.appendingPathComponent("d").path,
                          target: target, fileCount: 6, totalBytes: nil, completion: done)
        }
        guard case .failed = items.first?.state else {
            Issue.record("expected failure, got \(String(describing: items.first?.state))")
            return
        }
        #expect(contents(of: root).allSatisfy { !$0.hasPrefix(".tether-transfer-") })
    }

    @Test func packedDownloadUsesFinderStyleNames() async throws {
        let remote = root.appendingPathComponent("remote"), local = root.appendingPathComponent("local")
        for i in 0..<12 { try write("logs/app-\(i).log", "log \(i)", in: remote) }
        try write("notes.txt", "remote notes", in: remote)
        try write("notes.txt", "local notes", in: local)
        let remoteNames = ["logs", "notes.txt"]
        let localNames = LocalFiles.uniqueNames(in: local, for: remoteNames)
        #expect(localNames == ["logs", "notes 2.txt"])
        let fs = RemoteFileSystem(executor: RemoteExecutor(target: .local, options: SSHOptions()))
        let size = try await fs.measure(remoteNames.map { remote.appendingPathComponent($0).path })
        #expect(size.files == 13)

        let m = manager()
        let items = await wait { done in
            m.downloadGroup(remoteNames, from: remote.path, to: local, as: localNames, target: target,
                            fileCount: size.files, totalBytes: size.bytes, completion: done)
        }
        #expect(items.first?.method == .archive)
        #expect(items.first?.state == .completed)
        #expect(read("logs/app-11.log", in: local) == "log 11")
        #expect(read("notes.txt", in: local) == "local notes")
        #expect(read("notes 2.txt", in: local) == "remote notes")
        #expect(contents(of: local) == ["logs", "notes 2.txt", "notes.txt"])
    }

    @Test func unpackedFilesRunInParallelAndAllFinish() async throws {
        let src = root.appendingPathComponent("psrc"), dest = root.appendingPathComponent("pdest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for i in 0..<7 { try write("p\(i).bin", "p\(i)", in: src) }
        let files = (0..<7).map { src.appendingPathComponent("p\($0).bin") }
        let m = manager(parallel: 3, mode: .never)
        var peak = 0
        let items = await wait { done in
            let made = m.uploadGroup(files, names: files.map(\.lastPathComponent), to: dest.path, target: .local,
                                     fileCount: 7, totalBytes: nil, completion: done)
            peak = m.running.count
            #expect(made.count == 7)
        }
        #expect(peak == 3)
        #expect(items.allSatisfy { $0.state == .completed })
        #expect(contents(of: dest).count == 7)
        #expect(items.allSatisfy { $0.method == .scp })
    }

    @Test func policyDecidesWhenToPack() {
        #expect(TransferPolicy(archiveMode: .auto, archiveThreshold: 20).packs(fileCount: 19) == false)
        #expect(TransferPolicy(archiveMode: .auto, archiveThreshold: 20).packs(fileCount: 20) == true)
        #expect(TransferPolicy(archiveMode: .always).packs(fileCount: 2) == true)
        #expect(TransferPolicy(archiveMode: .always).packs(fileCount: 1), "always: one file too (sent compressed)")
        #expect(TransferPolicy(archiveMode: .never).packs(fileCount: 5_000) == false)
    }

    @Test func localNamesAreFinderStyle() throws {
        let dir = root.appendingPathComponent("names")
        for n in ["a.txt", "a 2.txt", "folder", ".env"] { try write(n, "", in: dir) }
        #expect(LocalFiles.uniqueNames(in: dir, for: ["a.txt", "a.txt", "folder", ".env", "b.tar.gz", "new"])
                == ["a 3.txt", "a 4.txt", "folder 2", ".env 2", "b.tar.gz", "new"])
    }
}
