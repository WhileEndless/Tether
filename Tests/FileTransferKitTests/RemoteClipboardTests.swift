import AppKit
import Foundation
import Testing
import TetherCore
import SSHTransport
@testable import FileTransferKit

/// Copy and paste of remote files: what goes on a pasteboard (a private one, never the user's),
/// what pasting decides, and the server-side paste with free names (run with this Mac's shell).
@MainActor
@Suite(.serialized) final class RemoteClipboardTests {
    let root: URL
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("tether-test-\(UUID().uuidString)"))
    let server = ConnectionTarget.adhoc(user: "user", host: "example.com", port: nil, jump: nil)
    let other = ConnectionTarget.adhoc(user: "user", host: "jump.example.com", port: nil, jump: nil)

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tether-clip-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
    }

    private func clip(_ target: ConnectionTarget, _ paths: [String]) -> RemoteClip {
        RemoteClip(target: target, items: paths.map { RemoteClip.Item(path: $0, name: ($0 as NSString).lastPathComponent, isDirectory: false) })
    }

    private func contents(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func clipTravelsWithItsPathsAsText() {
        let c = clip(server, ["/srv/logs/app.log", "/srv/logs/old dir"])
        let count = RemoteClipboard.write(c, to: pasteboard)
        #expect(count == pasteboard.changeCount)
        #expect(RemoteClipboard.read(from: pasteboard) == c)
        #expect(pasteboard.string(forType: .string) == "/srv/logs/app.log\n/srv/logs/old dir")
        #expect(RemoteClipboard.fileURLs(on: pasteboard).isEmpty, "no files until they are downloaded")
        #expect(c.parent == "/srv/logs")
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        #expect(RemoteClipboard.read(from: pasteboard) == nil)
    }

    @Test func localCopiesAreAddedAsFiles() throws {
        try write("copies/a.txt", "a")
        try write("copies/b dir/x", "x")
        let urls = [root.appendingPathComponent("copies/a.txt"), root.appendingPathComponent("copies/b dir")]
        let c = clip(server, ["/srv/a.txt", "/srv/b dir"])
        RemoteClipboard.write(c, localCopies: urls, to: pasteboard)
        #expect(RemoteClipboard.read(from: pasteboard) == c)
        #expect(RemoteClipboard.fileURLs(on: pasteboard).map(\.lastPathComponent) == ["a.txt", "b dir"])
        #expect(pasteboard.string(forType: .string) == "/srv/a.txt\n/srv/b dir")
    }

    @Test func pasteDecidesByWhereTheFilesCameFrom() {
        let c = clip(server, ["/srv/a"])
        let mac = [URL(fileURLWithPath: "/tmp/x.png")]
        #expect(FilePaste.decide(clip: c, localFiles: mac, into: server) == .onServer(["/srv/a"]), "the server copies; never uploaded back")
        #expect(FilePaste.decide(clip: c, localFiles: [], into: other) == .fromOtherServer(c))
        #expect(FilePaste.decide(clip: nil, localFiles: mac, into: server) == .upload(mac))
        guard case .nothing = FilePaste.decide(clip: nil, localFiles: [], into: server) else {
            Issue.record("expected nothing"); return
        }
        guard case .nothing = FilePaste.decide(clip: clip(server, []), localFiles: [], into: server) else {
            Issue.record("an empty clip pastes nothing"); return
        }
    }

    /// A drag puts one clip on each dragged row: read back as one, each path once, never mixing
    /// servers. A drop back into the folder the rows came from does nothing.
    @Test func dragClipsMergeAndADropWhereTheyCameFromDoesNothing() throws {
        let a = clip(server, ["/srv/a", "/srv/b dir"])
        let b = clip(server, ["/srv/b dir", "/srv/c"])
        #expect(RemoteClipboard.merge([a, b])?.paths == ["/srv/a", "/srv/b dir", "/srv/c"])
        #expect(RemoteClipboard.merge([a, clip(other, ["/x"])])?.paths == a.paths, "another server's clip is left out")
        #expect(RemoteClipboard.merge([clip(server, [])]) == nil)

        pasteboard.clearContents()
        let items = [a, b].map { c -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setData(try! #require(RemoteClipboard.encode(c)), forType: RemoteClipboard.type)
            return item
        }
        pasteboard.writeObjects(items)
        #expect(RemoteClipboard.read(from: pasteboard)?.paths == ["/srv/a", "/srv/b dir", "/srv/c"])

        guard case .nothing = FilePaste.decideDrop(a, into: server, directory: "/srv/") else {
            Issue.record("dropped where they came from: nothing happens"); return
        }
        #expect(FilePaste.decideDrop(a, into: server, directory: "/srv/sub") == .onServer(a.paths))
        #expect(FilePaste.decideDrop(clip(server, ["/srv/a", "/home/x"]), into: server, directory: "/srv") == .onServer(["/srv/a", "/home/x"]),
                "only some from here: the others are copied (the server's free names keep the rest)")
        #expect(FilePaste.decideDrop(a, into: other, directory: "/srv") == .fromOtherServer(a), "same folder on another server is another folder")
    }

    @Test func serverPasteUsesFreeNamesAndNeverReplaces() async throws {
        try write("src/report.pdf", "new")
        try write("src/proj/a.txt", "a")
        try write("dest/report.pdf", "old")
        let src = root.appendingPathComponent("src").path, dest = root.appendingPathComponent("dest").path
        let fs = RemoteFileSystem(executor: RemoteExecutor(target: .local, options: SSHOptions()))

        // Into another folder: the taken name gets the next free one.
        var names = try await fs.copyWithFreeNames([src + "/report.pdf", src + "/proj"], to: dest)
        #expect(names == ["report-1.pdf", "proj"])
        #expect(try String(contentsOfFile: dest + "/report.pdf", encoding: .utf8) == "old")
        #expect(try String(contentsOfFile: dest + "/report-1.pdf", encoding: .utf8) == "new")
        #expect(contents(root.appendingPathComponent("dest/proj")) == ["a.txt"])

        // Into the folder it came from: a copy beside it.
        names = try await fs.copyWithFreeNames([src + "/proj"], to: src)
        #expect(names == ["proj-1"])
        #expect(contents(root.appendingPathComponent("src")) == ["proj", "proj-1", "report.pdf"])

        // Never into itself.
        await #expect(throws: (any Error).self) { try await fs.copyWithFreeNames([src + "/proj"], to: src + "/proj") }
        #expect(contents(root.appendingPathComponent("src/proj")) == ["a.txt"])

        // A move within its folder does nothing; to another folder it moves, under a free name.
        names = try await fs.copyWithFreeNames([src + "/report.pdf"], to: src, move: true)
        #expect(names == ["report.pdf"])
        names = try await fs.copyWithFreeNames([src + "/report.pdf"], to: dest, move: true)
        #expect(names == ["report-2.pdf"])
        #expect(!LocalFiles.exists(src + "/report.pdf"))
        #expect(contents(root.appendingPathComponent("dest")) == ["proj", "report-1.pdf", "report-2.pdf", "report.pdf"])

        // Something gone meanwhile: said so.
        await #expect(throws: (any Error).self) { try await fs.copyWithFreeNames([src + "/missing"], to: dest) }
    }
}
