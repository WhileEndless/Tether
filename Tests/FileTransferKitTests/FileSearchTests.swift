import Foundation
import Testing
import TetherCore
import SSHTransport
@testable import FileTransferKit

/// The file manager's search, run with this Mac's shell (BSD find and stat): names, patterns and
/// contents, hidden folders left out unless asked, the limit, odd names, and stopping.
@Suite(.serialized) final class FileSearchTests {
    let root: URL
    let fs = RemoteFileSystem(executor: RemoteExecutor(target: .local, options: SSHOptions()))

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tether-search-\(UUID().uuidString.prefix(8))")
        for (path, text) in [("Reports/2024 report.pdf", "pdf"), ("Reports/old/report-2023.PDF", "old"),
                             ("notes.txt", "Remember the Milk"), ("src/main.swift", "print(\"needle\")"),
                             (".config/report.conf", "needle"), ("weird [x] * name?.txt", "w"),
                             ("src/.hidden-report.txt", "needle")] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Report folder"), withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func names(_ q: FileSearchQuery) async throws -> [String] {
        let r = try await fs.search(q, in: root.path)
        #expect(r.files.allSatisfy { $0.path.hasPrefix(r.directory + "/") })
        return r.files.map { String($0.path.dropFirst(r.directory.count + 1)) }.sorted()
    }

    @Test func nameContainsAnyCaseAndSkipsHidden() async throws {
        #expect(try await names(.init(text: "report")) == ["Report folder", "Reports", "Reports/2024 report.pdf", "Reports/old/report-2023.PDF"])
        #expect(try await names(.init(text: "report", includeHidden: true))
                == [".config/report.conf", "Report folder", "Reports", "Reports/2024 report.pdf", "Reports/old/report-2023.PDF", "src/.hidden-report.txt"])
    }

    @Test func nameTextIsTakenLiterally() async throws {
        #expect(try await names(.init(text: "[x] *")) == ["weird [x] * name?.txt"])
        #expect(try await names(.init(text: "*")) == ["weird [x] * name?.txt"])
        #expect(try await names(.init(text: "nothing like it")).isEmpty)
    }

    @Test func patterns() async throws {
        #expect(try await names(.init(text: "*.pdf", mode: .pattern)) == ["Reports/2024 report.pdf", "Reports/old/report-2023.PDF"])
        #expect(try await names(.init(text: "report-202?.pdf", mode: .pattern)) == ["Reports/old/report-2023.PDF"])
    }

    @Test func contents() async throws {
        #expect(try await names(.init(text: "needle", mode: .content)) == ["src/main.swift"])
        #expect(try await names(.init(text: "NEEDLE", mode: .content, includeHidden: true)) == [".config/report.conf", "src/.hidden-report.txt", "src/main.swift"])
        #expect(try await names(.init(text: "the milk", mode: .content)) == ["notes.txt"])
        #expect(try await names(.init(text: "-v", mode: .content)).isEmpty, "a text that looks like an option is still text")
    }

    @Test func detailsAndKinds() async throws {
        let r = try await fs.search(.init(text: "report"), in: root.path)
        let folder = try #require(r.files.first { $0.name == "Reports" })
        #expect(folder.isDirectory)
        let pdf = try #require(r.files.first { $0.name == "2024 report.pdf" })
        #expect(pdf.kind == .file && pdf.size == 3 && pdf.modified.timeIntervalSinceNow > -600)
    }

    @Test func limitAndTruncation() async throws {
        let many = root.appendingPathComponent("many")
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        for i in 0..<30 { try "x".write(to: many.appendingPathComponent("item\(i).log"), atomically: true, encoding: .utf8) }
        let r = try await fs.search(.init(text: "*.log", mode: .pattern), in: many.path, limit: 10)
        #expect(r.files.count == 10 && r.truncated)
        let all = try await fs.search(.init(text: "*.log", mode: .pattern), in: many.path, limit: 30)
        #expect(all.files.count == 30 && !all.truncated)
    }

    @Test func missingFolderFails() async {
        await #expect(throws: (any Error).self) { try await self.fs.search(.init(text: "x"), in: self.root.path + "/missing") }
    }

    /// Stopping a search ends its command (here one that would take half a minute).
    @Test func cancellingStopsTheCommand() async throws {
        let executor = RemoteExecutor(target: .local, options: SSHOptions())
        let started = Date()
        let task = Task { try await executor.output(RemoteScript("sleep 30"), timeout: 60, stopOnCancel: true) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func outputParsing() {
        let text = "/srv\nd\t755\tu\tg\t0\t0\t\t./a b\nf\t644\tu\tg\t5\t1700000000\t\ta b/c.txt\nregular file\t644\tu\tg\t1\t0\t\t./x/y\n"
        let r = RemoteFileSystem.parseSearch(text, limit: 2)
        #expect(r.directory == "/srv" && r.truncated)
        #expect(r.files.map(\.path) == ["/srv/a b", "/srv/a b/c.txt"])
        #expect(r.files.map(\.name) == ["a b", "c.txt"])
        #expect(RemoteFileSystem.parseSearch("/\nf\t644\tu\tg\t1\t0\t\tetc/hosts\n", limit: 5).files.map(\.path) == ["/etc/hosts"])
        #expect(FileSearchQuery(text: "a*b?[c]\\").posixPattern == "*a\\*b\\?\\[c]\\\\*")
        #expect(FileSearchQuery(text: "a*b`[c]").windowsPattern == "*a`*b```[c`]*")
    }
}
