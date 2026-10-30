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

    /// Both ways the same rule: the number goes before an extension that reads as one (`go.mod` →
    /// `go-1.mod` on a server, `go 2.mod` on the Mac), at the end otherwise (`v1.2`, `app.log.1`,
    /// `.env`, `a.b-c`), as Finder does — never a name like `v1-1.2`.
    @Test func numbersGoWhereFinderPutsThem() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-names-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = ["go.mod", "go.sum", "v1.2", "app.log.1", ".env", ".env.local", "a.b-c", "Makefile",
                     "x.tar.gz", "photo.JPEG", "archive.longextension1", "café.txt"]
        for n in names { FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data()) }
        let fs = RemoteFileSystem(executor: RemoteExecutor(target: .local, options: SSHOptions()))
        let server = try await fs.uniqueNames(in: dir.path, for: names)
        #expect(server == ["go-1.mod", "go-1.sum", "v1.2-1", "app.log.1-1", ".env-1", ".env-1.local", "a.b-c-1", "Makefile-1",
                           "x.tar-1.gz", "photo-1.JPEG", "archive.longextension1-1", "café-1.txt"])
        let mac = LocalFiles.uniqueNames(in: dir, for: names)
        #expect(mac == ["go 2.mod", "go 2.sum", "v1.2 2", "app.log.1 2", ".env 2", ".env 2.local", "a.b-c 2", "Makefile 2",
                        "x.tar 2.gz", "photo 2.JPEG", "archive.longextension1 2", "café 2.txt"])
    }

    /// Names at the disk's limit (255 bytes), in several scripts: the free name still fits — the
    /// part before the extension is shortened at whole characters — and the disk takes it.
    @Test func longNamesStayWithinTheLimit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-names-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = [String(repeating: "a", count: 251) + ".txt",          // 255 bytes
                     String(repeating: "ç", count: 125) + ".md",           // 253 bytes, two each
                     String(repeating: "😀", count: 63),                    // 252 bytes, no extension
                     "x." + String(repeating: "e", count: 200)]             // a long "extension": part of the name
        for n in names {
            #expect(n.utf8.count <= 255)
            #expect(FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data()), "the disk takes \(n.utf8.count) bytes")
        }
        let fs = RemoteFileSystem(executor: RemoteExecutor(target: .local, options: SSHOptions()))
        let server = try await fs.uniqueNames(in: dir.path, for: names)
        let mac = LocalFiles.uniqueNames(in: dir, for: names)
        for (k, free) in (server + mac).enumerated() {
            let original = names[k % names.count]
            #expect(free != original)
            #expect(free.decomposedStringWithCanonicalMapping.utf8.count <= 255, "\(k < names.count ? "server" : "mac") #\(k % names.count): \(free.utf8.count) bytes")
            #expect(String(decoding: Array(free.utf8), as: UTF8.self) == free, "whole characters")
            let ext = (original as NSString).pathExtension
            if k % names.count < 2 { #expect(free.hasSuffix("." + ext), "the extension stays: \(free.suffix(8))") }
            #expect(FileManager.default.createFile(atPath: dir.appendingPathComponent(free).path, contents: Data()), "the disk takes \(free)")
        }
        #expect(server[0].hasSuffix("-1.txt") && mac[0].hasSuffix(" 2.txt"))
        #expect(server[2].hasSuffix("-1") && mac[2].hasSuffix(" 2"))
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
