import Foundation
import Testing
@testable import SSHConfigKit

/// A config file that could not be read (no descriptor left, no permission, not UTF-8) is neither
/// emptied in the host list nor written over.
@Suite struct SSHConfigLibraryTests {
    private static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private struct ReadFailed: Error {}

    @Test func aFailedReadKeepsTheHostsAndNeverWrites() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config")
        let original = "Host alpha\n  HostName alpha.example.com\n\nHost beta\n  HostName 192.0.2.10\n"
        try Data(original.utf8).write(to: url)

        var library = SSHConfigLibrary(mainURL: url)
        #expect(library.aliases == ["alpha", "beta"])

        // The next read fails: the hosts stay, and the file is marked as not to be written.
        library.reload(read: { _ in throw ReadFailed() })
        #expect(library.aliases == ["alpha", "beta"])
        #expect(library.unreadable == [url.standardizedFileURL.path])
        #expect(throws: SSHConfigLibrary.UnreadableFile.self) {
            try library.edit(alias: nil, backupDirectory: nil) { doc in doc = SSHConfigDocument(text: "Host gamma\n", sourceURL: url) }
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == original)

        // Readable again: edits work.
        library.reload()
        #expect(library.unreadable.isEmpty)
        try library.edit(alias: nil, backupDirectory: nil) { doc in doc = SSHConfigDocument(text: original + "\nHost gamma\n", sourceURL: url) }
        #expect(SSHConfigLibrary(mainURL: url).aliases == ["alpha", "beta", "gamma"])
    }

    /// The kept copy's Include lines are still followed: the hosts of the files it includes stay too.
    @Test func aFailedReadKeepsTheIncludedHosts() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config")
        let extra = dir.appendingPathComponent("extra")
        try Data("Host gamma\n  HostName gamma.example.com\n".utf8).write(to: extra)
        try Data("Include \(extra.path)\n\nHost alpha\n  HostName 192.0.2.11\n".utf8).write(to: url)

        var library = SSHConfigLibrary(mainURL: url)
        #expect(Set(library.aliases) == ["alpha", "gamma"])
        let main = url.standardizedFileURL.path
        library.reload(read: { u in
            if u.standardizedFileURL.path == main { throw ReadFailed() }
            return try String(contentsOf: u, encoding: .utf8)
        })
        #expect(Set(library.aliases) == ["alpha", "gamma"])
        #expect(library.unreadable == [main])
    }

    @Test func aFailedFirstReadShowsNothingAndWritesNothing() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config")
        // Not UTF-8: unreadable as text.
        try Data([0x48, 0x6f, 0x73, 0x74, 0x20, 0xff, 0xfe, 0x0a]).write(to: url)
        var library = SSHConfigLibrary(mainURL: url)
        #expect(!library.unreadable.isEmpty)
        #expect(throws: SSHConfigLibrary.UnreadableFile.self) {
            try library.edit(alias: nil, backupDirectory: nil) { doc in doc = SSHConfigDocument(text: "Host gamma\n", sourceURL: url) }
        }
        #expect(try Data(contentsOf: url) == Data([0x48, 0x6f, 0x73, 0x74, 0x20, 0xff, 0xfe, 0x0a]))
    }

    @Test func aMissingFileIsSimplyEmpty() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config")
        var library = SSHConfigLibrary(mainURL: url)
        #expect(library.unreadable.isEmpty && library.aliases.isEmpty)
        try library.edit(alias: nil, backupDirectory: nil) { doc in doc = SSHConfigDocument(text: "Host alpha\n", sourceURL: url) }
        #expect(SSHConfigLibrary(mainURL: url).aliases == ["alpha"])
    }
}
