import Foundation
import Testing
import TestSupport

/// A test's tmux server is ended by its own socket only: never the user's server, also when the
/// test's folder is already gone (tmux would then use the user's default server).
@Suite struct PrivateTmuxTests {
    @Test func nothingRunsWithoutTheTestsOwnSocket() throws {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("tether-pt-\(UUID().uuidString.prefix(6))")
        #expect(!FileManager.default.fileExists(atPath: gone.path))
        #expect(PrivateTmux.socket(in: gone).hasPrefix(gone.path + "/tmux-"))
        // No folder, no socket: returns without running tmux at all (it would reach the default server).
        PrivateTmux.killServer(in: gone)
        // The default server's folder is refused whatever is there.
        PrivateTmux.killServer(in: URL(fileURLWithPath: "/tmp"))
        PrivateTmux.killServer(in: URL(fileURLWithPath: "/private/tmp"))
        // A folder with a plain file where the socket would be: not a socket, nothing runs.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-pt-\(UUID().uuidString.prefix(6))")
        let sub = dir.appendingPathComponent("tmux-\(getuid())")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: sub.appendingPathComponent("default"))
        PrivateTmux.killServer(in: dir)
        #expect(FileManager.default.fileExists(atPath: sub.appendingPathComponent("default").path))
    }
}
