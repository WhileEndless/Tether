import Foundation
import Testing
import TetherCore
@testable import SessionKit

/// A tab running a coding agent is named after its session, unless the user named the tab.
@MainActor @Suite struct AgentTitleTests {
    @Test func agentNameUnlessRenamed() {
        var descriptor = SessionDescriptor(target: .alias("web"), persistence: .tmux)
        let session = TerminalSession(descriptor: descriptor) { SessionConfiguration(settings: AppSettings()) }
        let automatic = session.displayTitle
        session.agentTitle = "Claude Code: Fix login bug"
        #expect(session.displayTitle == "Claude Code: Fix login bug — web")
        session.agentTitle = nil                                     // the agent ended
        #expect(session.displayTitle == automatic)

        descriptor.title = "deploy"
        descriptor.customTitle = true
        let renamed = TerminalSession(descriptor: descriptor) { SessionConfiguration(settings: AppSettings()) }
        renamed.agentTitle = "Claude Code: Fix login bug"
        #expect(renamed.displayTitle == "deploy")                    // a name given by hand wins
    }
}
