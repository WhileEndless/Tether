import Testing
@testable import SessionKit

/// The terminal's process reports `waitpid`'s raw status: ssh losing its connection (255) must not
/// look like a shell that exited by itself.
@Suite struct ExitStatusTests {
    @Test func rawWaitStatusIsDecoded() {
        #expect(TerminalSession.exitStatus(fromWaitStatus: 255 << 8) == 255)
        #expect(TerminalSession.exitStatus(fromWaitStatus: 1 << 8) == 1)
        #expect(TerminalSession.exitStatus(fromWaitStatus: 0) == 0)
        #expect(TerminalSession.exitStatus(fromWaitStatus: 15) == 255, "ended by a signal: lost, not exited")
        #expect(TerminalSession.exitStatus(fromWaitStatus: nil) == nil)
    }
}
