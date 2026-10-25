import Foundation

/// Where a terminal's shell runs on its host, so the command running in it can be found there
/// (see `TerminalSession.shellAnchor` and MonitorKit's `CommandSampler`).
public enum ShellAnchor: Hashable, Sendable {
    /// A POSIX shell with this process id (a tmux pane's shell, or a plain shell).
    case posix(pid: Int)
    /// The shell inside this GNU screen session (found through the screen server).
    case screen(session: String)
    /// The PowerShell on a Windows host whose command line contains this tag (Windows has no
    /// marker channel through its console host, so the shell is found by what started it).
    case windows(commandTag: String)
}
