import Foundation
import Testing
import TetherCore
@testable import SessionKit

/// Coding agents waiting for the user are noticed (OSC 7501, the agent's status file), tmux
/// passthrough reaches the notification handlers, and a tab is marked "working" only while its
/// command really does something.
@MainActor
@Suite struct AgentStatusTests {
    func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    @Test func programStatusParses() {
        #expect(ProgramStatus.parse(Array("?".utf8)) == .query)
        let blocked = ProgramStatus.parse(Array("state=blocked:kind=question:app=claude-code:msg=\(b64("Pick one"))".utf8))
        #expect(blocked == .update(state: "blocked", kind: "question", message: "Pick one", app: "claude-code"))
        #expect(blocked?.activity == .waiting("Pick one"))
        #expect(ProgramStatus.parse(Array("state=blocked:kind=permission".utf8))?.activity == .waiting("needs your permission"))
        #expect(ProgramStatus.parse(Array("state=working".utf8))?.activity == .working)
        #expect(ProgramStatus.parse(Array("state=working:id=sub/task".utf8)) == nil)      // sub-records are not the tab's
        #expect(ProgramStatus.parse(Array("nonsense".utf8)) == nil)
        #expect(String(decoding: ProgramStatus.reply, as: UTF8.self).hasPrefix("\u{1b}]7501;?:states="))
    }

    @Test func sessionFollowsTheNewestReportAndNotifiesOnce() {
        let s = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) { SessionConfiguration(settings: AppSettings()) }
        var raised = 0
        s.onAttention = { _, _ in raised += 1 }
        let t0 = Date()
        s.agentReported(kind: .claude, activity: .working, at: t0)
        s.agentReported(kind: .claude, activity: .waiting("is waiting: permission prompt"), at: t0.addingTimeInterval(2))
        #expect(s.agent?.activity.isWaiting == true)
        #expect(raised == 1)
        // The same report again (the next poll): no second notification.
        s.agentReported(kind: .claude, activity: .waiting("is waiting: permission prompt"), at: t0.addingTimeInterval(2))
        #expect(raised == 1)
        // An older report (OSC stuck at "working" from before) does not hide the waiting state.
        s.agentReported(kind: .claude, activity: .working, at: t0.addingTimeInterval(1))
        #expect(s.agent?.activity.isWaiting == true)
        s.agentReported(kind: .claude, activity: .working, at: t0.addingTimeInterval(3))
        #expect(s.agent?.activity == .working)
        s.notifyAgentWaiting = false
        s.agentReported(kind: .claude, activity: .waiting("has a question"), at: t0.addingTimeInterval(4))
        #expect(raised == 1)
        s.agentEnded()
        #expect(s.agent == nil)
    }

    @Test func statusQueryIsAnsweredThroughTheTerminal() {
        let s = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) { SessionConfiguration(settings: AppSettings()) }
        s.terminalOSC(code: 7501, payload: Array("state=blocked:kind=question".utf8))
        #expect(s.agent?.activity == .waiting("has a question"))
        #expect(s.attention != nil)
    }

    @Test func tmuxPassthroughIsUnwrapped() {
        var p = TmuxPassthrough()
        let inner = "\u{1b}]9;Claude is done\u{07}"
        let wrapped = "a\u{1b}Ptmux;" + inner.replacingOccurrences(of: "\u{1b}", with: "\u{1b}\u{1b}") + "\u{1b}\\b"
        #expect(String(decoding: p.filter(Array(wrapped.utf8)), as: UTF8.self) == "a" + inner + "b")
        // Cut in three pieces, even inside the start marker.
        let bytes = Array(wrapped.utf8)
        var q = TmuxPassthrough()
        let out = q.filter(Array(bytes[0..<3])) + q.filter(Array(bytes[3..<12])) + q.filter(Array(bytes[12...]))
        #expect(String(decoding: out, as: UTF8.self) == "a" + inner + "b")
        // Plain output and other escape sequences pass unchanged.
        var r = TmuxPassthrough()
        let plain = Array("ls\r\n\u{1b}[31mred\u{1b}[0m\u{1b}P1$r0m\u{1b}\\".utf8)
        #expect(r.filter(plain) == plain)
    }

    @Test func tabIsWorkingOnlyWhileItsCommandDoesSomething() {
        #expect(TabActivity.decide(running: false, foreground: nil, outputActive: true, cpu: nil, io: nil) == .idle)
        #expect(TabActivity.decide(running: true, foreground: nil, outputActive: true, cpu: nil, io: nil) == .working("output"))
        #expect(TabActivity.decide(running: true, foreground: nil, outputActive: false, cpu: 85, io: nil) == .working("85 % CPU"))
        #expect(TabActivity.decide(running: true, foreground: nil, outputActive: false, cpu: 0.3, io: 500) == .quiet)   // vim
        #expect(TabActivity.decide(running: true, foreground: nil, outputActive: false, cpu: 1, io: 2_000_000) == .working("network or disk"))
        // No watcher: the foreground program's name decides whether something runs.
        #expect(TabActivity.decide(running: nil, foreground: "-zsh", outputActive: true, cpu: nil, io: nil) == .idle)
        #expect(TabActivity.decide(running: nil, foreground: "make", outputActive: true, cpu: nil, io: nil) == .working("output"))
    }

    @Test func agentsAndShellsAreRecognised() {
        #expect(AgentKind(program: "claude") == .claude)
        #expect(AgentKind(program: "/usr/local/bin/codex") == .codex)
        #expect(AgentKind(program: "vim") == nil)
        #expect(ShellNames.contains("-zsh") && ShellNames.contains("pwsh.exe") && !ShellNames.contains("python3"))
        #expect(TerminalSession.isShell("bash"))
    }
}
