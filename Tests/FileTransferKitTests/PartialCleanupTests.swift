import Foundation
import Testing
import TetherCore
import SSHTransport
@testable import FileTransferKit

/// A cancelled or failed copy removes only what it made itself, never what was there before.
@MainActor @Suite struct PartialCleanupTests {
    let target = ConnectionTarget.adhoc(user: "user", host: "example.invalid", port: nil, jump: nil)

    @Test func downloadRemovesOnlyItsOwnFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-partial-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = TransferManager(options: { SSHOptions() })

        // A new name: what the copy wrote there goes.
        let fresh = dir.appendingPathComponent("log.txt")
        let cleanFresh = manager.partialCleanup(for: TransferItem(direction: .download, target: target, localURL: fresh, remotePath: "/var/log/log.txt"))
        try Data("partial".utf8).write(to: fresh)
        cleanFresh()
        #expect(!FileManager.default.fileExists(atPath: fresh.path))

        // A file that was there before the copy started is never touched.
        let existing = dir.appendingPathComponent("keep.txt")
        try Data("mine".utf8).write(to: existing)
        manager.partialCleanup(for: TransferItem(direction: .download, target: target, localURL: existing, remotePath: "/x/keep.txt"))()
        #expect(FileManager.default.fileExists(atPath: existing.path))

        // Into a folder: the file it would create inside it.
        let inside = dir.appendingPathComponent("data.bin")
        let cleanInside = manager.partialCleanup(for: TransferItem(direction: .download, target: target, localURL: dir, remotePath: "/srv/data.bin"))
        try Data("partial".utf8).write(to: inside)
        cleanInside()
        #expect(!FileManager.default.fileExists(atPath: inside.path))
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }
}
