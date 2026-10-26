import SwiftUI
import TetherCore
import SessionKit
import MonitorKit

/// What a tab (and its sidebar row) shows in front of its title, most important first:
///
/// 0. a login that needs your password (shown when you show the tab);
/// 1. a coding agent waiting for you (plan approval, a question, a permission);
/// 2. a program asking for attention (notification, bell);
/// 3. a coding agent: its symbol, moving while it works;
/// 4. a command that is working (output, CPU, network or disk): a moving mark;
/// 5. a command that is only open (vim, less, a quiet `tail -f`): nothing, or a faint dot;
/// 6. otherwise the connection's state.
///
/// Only tabs that are actually working animate; nothing runs for the others.
struct TabStatusIcon: View {
    @Environment(AppModel.self) private var model
    let session: TerminalSession
    var size: CGFloat = 10
    /// Shown instead of the state dot when there is nothing else (the sidebar's terminal symbol).
    var restingSymbol: String?
    /// Symbols move while something works (the tab bar). The sidebar shows them still: a looping
    /// animation in every list row costs CPU for as long as an agent works, and the tab shows it.
    var animates = true

    enum Shown: Equatable {
        case signIn
        case waiting(AgentKind, String)
        case attention(String)
        case agent(AgentKind, working: Bool)
        case working(String)
        case quiet(String)
        case phase
    }

    var shown: Shown {
        if model.waitsForSignIn(session) { return .signIn }
        if let agent = session.agent, case .waiting(let why) = agent.activity {
            return .waiting(agent.kind, why)
        }
        if session.attention != nil { return .attention(attentionHelp) }
        let activity = commandActivity
        if let kind = model.agentKind(of: session) {
            let working = session.agent.map { $0.activity == .working } ?? (activity.isWorking)
            return .agent(kind, working: working)
        }
        switch activity {
        case .working(let why): return .working(why)
        case .quiet: return model.settings.markIdlePrograms ? .quiet(commandName) : .phase
        case .idle: return .phase
        }
    }

    var body: some View {
        Group {
            switch shown {
            case .signIn:
                Image(systemName: "key.fill")
                    .font(.system(size: size))
                    .foregroundStyle(.orange)
                    .help("Needs your password — show this tab to sign in")
            case .waiting(let kind, let why):
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: size))
                    .foregroundStyle(.orange)
                    .symbolEffect(.bounce, value: why)
                    .help("\(kind.title) \(why)")
            case .attention(let help):
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: size))
                    .foregroundStyle(.orange)
                    .help(help)
            case .agent(let kind, let working):
                Image(systemName: kind.symbol)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(Color(red: kind.tint.red, green: kind.tint.green, blue: kind.tint.blue))
                    .symbolEffect(.pulse, isActive: working && animates)
                    .help(working ? "\(kind.title) is working" : kind.title)
            case .working(let why):
                Image(systemName: "circle.dotted")
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.variableColor.iterative, isActive: animates)
                    .help("\(commandName) is working — \(why)")
            case .quiet(let name):
                Circle().fill(Color.secondary.opacity(0.45)).frame(width: 5, height: 5)
                    .help("\(name) is open, not doing anything")
            case .phase:
                if let restingSymbol {
                    Image(systemName: restingSymbol).font(.system(size: size)).foregroundStyle(session.phase.tint)
                } else {
                    StatusDot(phase: session.phase, size: 6)
                        .help(session.phase.label)
                }
            }
        }
        .frame(width: size + 6, height: size + 6)
    }

    /// Whether the terminal's command works, is only open, or the shell is at its prompt.
    private var commandActivity: TabActivity {
        let target = session.descriptor.target
        guard session.phase.isOnline, model.isEnabled(.tabActivity, for: target) else { return .idle }
        let sampler = model.commandSamplers[session.id]
        let running: Bool? = switch sampler?.status {
        case .running?: true
        case .idle?: false
        default: nil
        }
        let latest = sampler?.latest
        let io = [latest?.received, latest?.sent, latest?.read, latest?.written].compactMap { $0 }.reduce(0, +)
        return TabActivity.decide(running: running, foreground: session.foregroundName, outputActive: session.outputActive,
                                  cpu: latest?.cpu, io: latest == nil ? nil : io,
                                  cpuThreshold: model.settings.workingCPUThreshold)
    }

    private var commandName: String {
        model.commandSamplers[session.id]?.frame?.leader?.name ?? session.foregroundName ?? "The command"
    }

    private var attentionHelp: String {
        switch session.attention {
        case .message(let n)?: [n.title, n.body].compactMap { $0 }.joined(separator: ": ")
        case .bell?: "The bell rang"
        case nil: ""
        }
    }
}

extension TabActivity {
    var isWorking: Bool { if case .working = self { true } else { false } }
}
