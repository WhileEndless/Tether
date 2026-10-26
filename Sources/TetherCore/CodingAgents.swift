import Foundation

/// Coding agents Tether recognises in a terminal (by the program's name), with the symbol tabs show
/// for them. Symbols are system ones in each agent's colour, not the products' logos.
public enum AgentKind: String, CaseIterable, Codable, Sendable {
    case claude, codex, opencode, gemini, aider, cursor, other

    public var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "opencode"
        case .gemini: "Gemini CLI"
        case .aider: "Aider"
        case .cursor: "Cursor Agent"
        case .other: "Coding agent"
        }
    }

    /// SF Symbol for tabs and sidebar rows.
    public var symbol: String {
        switch self {
        case .claude: "staroflife.fill"
        case .codex: "hexagon.fill"
        case .opencode: "curlybraces"
        case .gemini: "sparkle"
        case .aider: "wand.and.stars"
        case .cursor: "cursorarrow.rays"
        case .other: "sparkles"
        }
    }

    /// The symbol's colour (sRGB), close to each agent's own.
    public var tint: (red: Double, green: Double, blue: Double) {
        switch self {
        case .claude: (0.85, 0.47, 0.34)
        case .codex: (0.45, 0.45, 0.50)
        case .opencode: (0.30, 0.55, 0.95)
        case .gemini: (0.35, 0.55, 0.98)
        case .aider: (0.20, 0.70, 0.45)
        case .cursor: (0.55, 0.55, 0.60)
        case .other: (0.60, 0.45, 0.90)
        }
    }

    /// The agent a program name belongs to (`claude`, `codex`, `opencode`, `gemini`, `aider`,
    /// `cursor-agent`), or nil. Agents started through node show their own name to tmux and ps.
    public init?(program: String) {
        let name = (program as NSString).lastPathComponent.lowercased()
        switch name {
        case "claude", "claude-code": self = .claude
        case "codex", "codex-cli": self = .codex
        case "opencode": self = .opencode
        case "gemini": self = .gemini
        case "aider": self = .aider
        case "cursor-agent": self = .cursor
        default: return nil
        }
    }
}

/// Where a coding agent in a terminal stands, from whichever signal said so last.
public enum AgentActivity: Equatable, Sendable {
    case working
    /// Waiting for the user: a permission, a question, plan approval, a login (what the agent said).
    case waiting(String)
    case idle
    case done

    public var isWaiting: Bool { if case .waiting = self { true } else { false } }
}

/// Shell names: a terminal whose foreground program is one of these sits at its prompt.
public enum ShellNames {
    public static let all: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "ash", "nu",
                                          "pwsh", "powershell", "cmd"]

    /// `-zsh` (a login shell) and `pwsh.exe` count too.
    public static func contains(_ program: String) -> Bool {
        var name = (program as NSString).lastPathComponent.lowercased()
        if name.hasPrefix("-") { name.removeFirst() }
        if name.hasSuffix(".exe") { name.removeLast(4) }
        return all.contains(name)
    }
}
