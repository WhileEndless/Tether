import Foundation
import Testing
import TetherCore
import SSHTransport
@testable import FileTransferKit

/// A folder that is not there (any more) — deleted on the server, or remembered from the last run —
/// is told apart from one that cannot be opened, and the nearest folder that is there is found.
/// The POSIX scripts run with the local shell; the PowerShell ones are checked for what they say.
@Suite final class MissingFolderTests {
    let root: URL
    let fs = RemoteFileSystem(executor: RemoteExecutor(target: .local, options: SSHOptions()))

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tether-missing-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
    }

    deinit {
        let locked = root.appendingPathComponent("locked")
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try? FileManager.default.removeItem(at: root)
    }

    /// The real path (`/var` is `/private/var` on macOS), as the scripts' `pwd` reports it.
    private func real(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    @Test func aFolderThatIsGoneIsToldApart() async throws {
        let gone = root.appendingPathComponent("a/b/c/d").path
        do {
            _ = try await fs.list(gone)
            Issue.record("listed a folder that is not there")
        } catch let missing as RemoteFileSystem.MissingDirectory {
            #expect(missing.path == gone)
            #expect(missing.localizedDescription.contains("no longer exists"))
        }
    }

    /// One that is there but cannot be opened is not "gone" (the nearest folder must not replace it).
    @Test func aFolderThatCannotBeOpenedIsNotGone() async throws {
        guard getuid() != 0 else { return }       // root opens everything
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        for path in [locked.path, locked.appendingPathComponent("inside").path] {
            do {
                _ = try await fs.list(path)
                Issue.record("listed a folder it may not open: \(path)")
            } catch is RemoteFileSystem.MissingDirectory {
                Issue.record("taken for a folder that is gone: \(path)")
            } catch {
                #expect(error.localizedDescription.contains("Cannot open directory"))
            }
        }
    }

    @Test func theNearestFolderThatIsThereIsFound() async throws {
        #expect(try await fs.nearestExisting(root.appendingPathComponent("a/b/c/d").path) == real(root.appendingPathComponent("a/b")))
        #expect(try await fs.nearestExisting(root.appendingPathComponent("a").path) == real(root.appendingPathComponent("a")))
        // A file where a folder was: its folder.
        try Data("x".utf8).write(to: root.appendingPathComponent("a/file"))
        #expect(try await fs.nearestExisting(root.appendingPathComponent("a/file/sub").path) == real(root.appendingPathComponent("a")))
        // Nothing of it left (a path from another server): somewhere that exists, never an error.
        let far = try await fs.nearestExisting("/tether-no-such-root-\(UUID().uuidString)/x/y")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: far, isDirectory: &isDir) && isDir.boolValue, "\(far)")
    }

    @Test func windowsSaysTheSame() {
        #expect(WindowsFileScripts.list.contains("Directory not found: $($A[0])"))
        #expect(WindowsFileScripts.list.contains("Cannot open directory: $($A[0])"))
        #expect(WindowsFileScripts.nearest.contains("Split-Path -Parent"))
        #expect(WindowsFileScripts.nearest.contains("$HOME"))
    }
}
