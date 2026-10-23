import Foundation
import Testing
import TetherCore
import SSHTransport
@testable import FileTransferKit

/// The conflict-free naming script, run with the local shell (a "local" target needs no ssh).
@Suite struct UniqueNameTests {
    @Test func neverOverwritesAndKeepsExtensions() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-names-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for existing in ["a.txt", "a-1.txt", ".bashrc", "noext"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(existing).path, contents: Data())
        }
        let fs = RemoteFileSystem(executor: RemoteExecutor(target: .local, options: SSHOptions()))
        let names = try await fs.uniqueNames(in: dir.path, for: ["a.txt", "a.txt", "noext", ".bashrc", "new file.pdf", "x.tar.gz"])
        #expect(names == ["a-2.txt", "a-3.txt", "noext-1", ".bashrc-1", "new file.pdf", "x.tar.gz"])
    }

    @Test func createsMissingDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-names-\(UUID())/sub")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let fs = RemoteFileSystem(executor: RemoteExecutor(target: .local, options: SSHOptions()))
        #expect(try await fs.uniqueNames(in: dir.path, for: ["f"]) == ["f"])
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }
}

@Suite struct BulkOperationTests {
    @Test func moveCopyCompressNeverOverwrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tether-bulk-\(UUID())")
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one".utf8).write(to: src.appendingPathComponent("a.txt"))
        try Data("two".utf8).write(to: src.appendingPathComponent("b.txt"))
        try Data("keep".utf8).write(to: dst.appendingPathComponent("b.txt"))
        let fs = RemoteFileSystem(executor: RemoteExecutor(target: .local, options: SSHOptions()))

        let skipped = try await fs.copy([src.appendingPathComponent("a.txt").path, src.appendingPathComponent("b.txt").path], to: dst.path)
        #expect(skipped == ["b.txt"])
        #expect(try String(contentsOf: dst.appendingPathComponent("b.txt"), encoding: .utf8) == "keep")
        #expect(FileManager.default.fileExists(atPath: dst.appendingPathComponent("a.txt").path))

        let archive = try await fs.compress(["a.txt", "b.txt"], in: src.path, archiveName: "src.tar.gz")
        #expect(FileManager.default.fileExists(atPath: archive))
        let again = try await fs.compress(["a.txt"], in: src.path, archiveName: "src.tar.gz")
        #expect(again.hasSuffix("src.tar-1.gz"), "a second archive must not overwrite the first")

        try await fs.setPermissions([src.appendingPathComponent("a.txt").path], mode: "600", recursive: false)
        let perms = try FileManager.default.attributesOfItem(atPath: src.appendingPathComponent("a.txt").path)[.posixPermissions] as? Int
        #expect(perms == 0o600)

        let moveSkipped = try await fs.move([src.appendingPathComponent("a.txt").path], to: dst.path)
        #expect(moveSkipped == ["a.txt"], "a.txt already exists in dst, so it stays in src")
        #expect(FileManager.default.fileExists(atPath: src.appendingPathComponent("a.txt").path))
    }
}
