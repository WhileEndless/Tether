import Foundation
import Testing
import TetherCore
import TestSupport
import SSHTransport
@testable import FileTransferKit

/// Folders and files chosen together arrive whole, either way, packed or file by file: nested
/// folders, empty folders, names with spaces and accents, a folder beside a file of the same base
/// name. A transfer that moved nothing never reports success.
@MainActor
@Suite(.serialized) final class MixedItemsTests {
    let root: URL
    let ssh: URL
    let scp: URL
    let target: ConnectionTarget
    let names = ["My Folder", "empty dir", "ünïcode file.txt", "data", "data.txt"]

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tether-mixed-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        target = .adhoc(user: "user", host: "mixed-\(UUID().uuidString.prefix(6)).invalid", port: nil, jump: nil)
        ssh = root.appendingPathComponent("ssh")
        try "#!/bin/sh\nfor a; do last=$a; done\n/bin/sh -c \"$last\"\nexit $?\n".write(to: ssh, atomically: true, encoding: .utf8)
        scp = root.appendingPathComponent("scp")
        try #"""
        #!/bin/sh
        n=$#; i=0; src=""; dst=""
        for a; do i=$((i+1)); [ $i -eq $((n-1)) ] && src="$a"; [ $i -eq $n ] && dst="$a"; done
        exec /bin/cp -R "${src#*:}" "${dst#*:}"
        """#.write(to: scp, atomically: true, encoding: .utf8)
        for f in [ssh, scp] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path) }
    }

    deinit {
        _ = BoundedProcess.run("/usr/bin/pkill", ["-KILL", "-f", root.path], timeout: 5)
        try? FileManager.default.removeItem(at: root)
    }

    private func manager(mode: TransferArchiveMode, compression: TransferCompression = .off) -> TransferManager {
        var options = SSHOptions()
        options.sshBinary = ssh.path
        options.scpBinary = scp.path
        options.useControlMaster = false
        return TransferManager(options: { options }, policy: {
            TransferPolicy(parallel: 3, archiveMode: mode, archiveThreshold: 5, compression: compression, adaptToSlowHosts: false)
        })
    }

    private func put(_ path: String, _ text: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The tree as "relative path: content" lines (folders end with /).
    private func tree(_ dir: URL) -> [String] {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: dir.path) else { return [] }
        var lines: [String] = []
        while let rel = e.nextObject() as? String {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: dir.appendingPathComponent(rel).path, isDirectory: &isDir)
            lines.append(isDir.boolValue ? rel + "/" : rel + ": " + ((try? String(contentsOf: dir.appendingPathComponent(rel), encoding: .utf8)) ?? "?"))
        }
        return lines.sorted()
    }

    private func makeSource(_ dir: URL) throws {
        try put("My Folder/sub/deep/inner file.md", "deep", in: dir)
        try put("My Folder/top.txt", "top", in: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("My Folder/empty inside"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("empty dir"), withIntermediateDirectories: true)
        try put("ünïcode file.txt", "ü", in: dir)
        try put("data/one.csv", "1", in: dir)
        try put("data.txt", "d", in: dir)
    }

    private func wait(_ start: (@escaping ([TransferItem]) -> Void) -> Void) async -> [TransferItem] {
        await withCheckedContinuation { c in
            var done = false
            start { items in
                guard !done else { return }
                done = true
                c.resume(returning: items)
            }
        }
    }

    private func download(mode: TransferArchiveMode, compression: TransferCompression = .off) async throws {
        let remote = root.appendingPathComponent("remote-\(mode)-\(compression)"), local = root.appendingPathComponent("local-\(mode)-\(compression)")
        try makeSource(remote)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let m = manager(mode: mode, compression: compression)
        let items = await wait { done in
            m.downloadGroup(names, from: remote.path, to: local, as: names, target: target, fileCount: 6, totalBytes: nil, completion: done)
        }
        #expect(items.allSatisfy { $0.state == .completed }, "\(mode) \(compression): \(items.map { "\($0.state)" })")
        #expect(tree(local) == tree(remote), "\(mode) \(compression)")
    }

    private func upload(mode: TransferArchiveMode, compression: TransferCompression = .off) async throws {
        let src = root.appendingPathComponent("src-\(mode)-\(compression)"), dest = root.appendingPathComponent("dest-\(mode)-\(compression)")
        try makeSource(src)
        let m = manager(mode: mode, compression: compression)
        let files = names.map { src.appendingPathComponent($0) }
        let items = await wait { done in
            m.uploadGroup(files, names: names, to: dest.path, target: target, fileCount: 6, totalBytes: nil, completion: done)
        }
        #expect(items.allSatisfy { $0.state == .completed }, "\(mode) \(compression): \(items.map { "\($0.state)" })")
        #expect(tree(dest) == tree(src), "\(mode) \(compression)")
    }

    @Test func packedDownload() async throws { try await download(mode: .always) }
    @Test func packedCompressedDownload() async throws { try await download(mode: .always, compression: .gzip) }
    @Test func fileByFileDownload() async throws { try await download(mode: .never) }
    @Test func packedUpload() async throws { try await upload(mode: .always) }
    @Test func packedCompressedUpload() async throws { try await upload(mode: .always, compression: .gzip) }
    @Test func fileByFileUpload() async throws { try await upload(mode: .never) }

    /// Three items, as picked in the file manager: a folder with files, a file, an empty folder.
    @Test func threeMixedItemsArriveEitherWay() async throws {
        for mode in [TransferArchiveMode.always, .never] {
            let remote = root.appendingPathComponent("r3-\(mode)"), local = root.appendingPathComponent("l3-\(mode)")
            try put("photos/a b.jpg", "jpg", in: remote)
            try put("notes.txt", "n", in: remote)
            try FileManager.default.createDirectory(at: remote.appendingPathComponent("empty"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            let three = ["photos", "notes.txt", "empty"]
            let m = manager(mode: mode)
            let items = await wait { done in
                m.downloadGroup(three, from: remote.path, to: local, as: three, target: target, fileCount: 2, totalBytes: nil, completion: done)
            }
            #expect(items.allSatisfy { $0.state == .completed }, "\(mode): \(items.map { "\($0.state)" })")
            #expect(tree(local) == tree(remote), "\(mode)")
        }
    }

    /// The file manager's own path: the folder listed on the "server", the items picked from the
    /// listing, then `downloadItems` (counting, packing or not, free names) — every mode and with
    /// compression.
    @Test func fileManagerDownloadOfMixedItems() async throws {
        var options = SSHOptions()
        options.sshBinary = ssh.path
        options.scpBinary = scp.path
        options.useControlMaster = false
        let fs = RemoteFileSystem(executor: RemoteExecutor(target: target, options: options))
        for mode in [TransferArchiveMode.auto, .always, .never] {
            for compression in [TransferCompression.off, .auto] {
                let remote = root.appendingPathComponent("fm-r-\(mode)-\(compression)")
                let local = root.appendingPathComponent("fm-l-\(mode)-\(compression)")
                try makeSource(remote)
                for i in 0..<8 { try put("My Folder/many/f\(i).txt", "\(i)", in: remote) }
                let listing = try await fs.list(remote.path)
                let picked = listing.files.filter { names.contains($0.name) }
                #expect(picked.count == names.count, "\(listing.files.map(\.name))")
                let m = manager(mode: mode, compression: compression)
                let outcome: TransferManager.DownloadOutcome? = await withCheckedContinuation { c in
                    m.downloadItems(picked, from: target, to: local, fs: fs) { c.resume(returning: $0) }
                }
                let o = try #require(outcome)
                #expect(o.failed == 0, "\(mode) \(compression): \(o.message ?? "")")
                #expect(Set(o.arrived.keys) == Set(picked.map(\.path)), "\(mode) \(compression)")
                #expect(tree(local) == tree(remote), "\(mode) \(compression)")
                #expect(m.items.allSatisfy { $0.state == .completed }, "\(m.items.map { "\($0.state)" })")
            }
        }
    }

    /// Pasting files copied on one server into another's folder: what the file manager does —
    /// the picked items downloaded to this Mac (`downloadItems`), free names chosen on the other
    /// server, then uploaded (`uploadGroup`). Folders and files mixed, one folder with many files
    /// (packed when the policy says so); a name already taken there is kept, the copy gets the next.
    @Test func pasteIntoAnotherServerCarriesMixedItemsWhole() async throws {
        var options = SSHOptions()
        options.sshBinary = ssh.path
        options.scpBinary = scp.path
        options.useControlMaster = false
        let fs = RemoteFileSystem(executor: RemoteExecutor(target: target, options: options))
        for mode in [TransferArchiveMode.auto, .never] {
            let a = root.appendingPathComponent("paste-a-\(mode)"), mac = root.appendingPathComponent("paste-mac-\(mode)")
            let b = root.appendingPathComponent("paste-b-\(mode)")
            try makeSource(a)
            for i in 0..<120 { try put("data/many/f\(i).txt", "\(i)", in: a) }
            try put("data.txt", "already there", in: b)
            let picked = try await fs.list(a.path).files.filter { names.contains($0.name) }
            #expect(picked.count == names.count)
            let m = manager(mode: mode)
            let outcome: TransferManager.DownloadOutcome? = await withCheckedContinuation { c in
                m.downloadItems(picked, from: target, to: mac, fs: fs) { c.resume(returning: $0) }
            }
            let o = try #require(outcome)
            #expect(o.failed == 0, "\(mode): \(o.message ?? "")")
            let urls = picked.compactMap { o.arrived[$0.path] }
            #expect(urls.count == picked.count)
            let free = try await fs.uniqueNames(in: b.path, for: urls.map(\.lastPathComponent))
            #expect(free.contains("data-1.txt") && !free.contains("data.txt"), "\(free)")
            let items = await wait { done in
                m.uploadGroup(urls, names: free, to: b.path, target: target, fileCount: 126, totalBytes: nil, completion: done)
            }
            #expect(items.allSatisfy { $0.state == .completed }, "\(mode): \(items.map { "\($0.state)" })")
            if mode == .auto { #expect(items.contains { $0.method == .archive }, "many files travel as one stream") }
            #expect(try String(contentsOf: b.appendingPathComponent("data.txt"), encoding: .utf8) == "already there")
            let expected = tree(a).map { $0.hasPrefix("data.txt:") ? "data-1.txt: d" : $0 }.sorted()
            #expect(tree(b).filter { !$0.hasPrefix("data.txt:") } == expected, "\(mode)")
        }
    }

    /// A copy that ends without an error but leaves nothing never reports success.
    @Test func copyThatLeavesNothingFails() async throws {
        let empty = root.appendingPathComponent("empty-scp")
        try "#!/bin/sh\nexit 0\n".write(to: empty, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: empty.path)
        var options = SSHOptions()
        options.sshBinary = ssh.path
        options.scpBinary = empty.path
        options.useControlMaster = false
        let m = TransferManager(options: { options }, policy: { TransferPolicy(archiveMode: .never) })
        let local = root.appendingPathComponent("nothing")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let item: TransferItem = await withCheckedContinuation { c in
            m.download("/srv/report.pdf", to: local.appendingPathComponent("report.pdf"), target: target) { c.resume(returning: $0) }
        }
        guard case .failed(let why) = item.state else { Issue.record("\(item.state)"); return }
        #expect(why.contains("nothing arrived"))
    }
}
