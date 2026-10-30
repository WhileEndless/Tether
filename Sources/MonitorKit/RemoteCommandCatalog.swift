import Foundation
import TetherCore

/// Everything the host panel and the running-command features run on a host, described for the
/// user: when it runs, what it reads, what it changes, how it ends — and the script itself. The app
/// shows this list (Settings ▸ Monitoring ▸ What runs on hosts) and docs/remote-commands.md
/// describes the same entries (a test checks that every title is there), so neither can drift from
/// what really runs. Scripts are sent over the existing ssh connection on stdin; nothing is
/// installed or left on the host.
public struct RemoteCommand: Identifiable, Sendable {
    public var title: String
    /// When and how often it runs.
    public var when: String
    /// What it reads on the host.
    public var reads: String
    /// What it changes on the host ("Nothing." for every read-only script).
    public var changes: String
    /// How it ends (one-off scripts end by themselves; streams end when Tether stops reading).
    public var ends: String
    public var posix: String
    public var windows: String?
    public var id: String { title }
    /// The switches that stop it (Settings ▸ Monitoring, or the host's own); empty: only runs
    /// when you ask for it (an action you click).
    public var switchedBy: [HostFeature] { RemoteCommandCatalog.switches[title] ?? [] }
}

public enum RemoteCommandCatalog {
    static let switches: [String: [HostFeature]] = [
        "Host status stream": [.monitoring, .statusStrip, .overviewPanel],
        "Running command watcher": [.monitoring, .commandWatch],
        "Running command look": [.monitoring, .commandStats, .commandHistory, .tabActivity],
        "Traffic by process": [.monitoring, .processTraffic],
        "Processes": [.monitoring, .processesPanel],
        "Listening ports": [.monitoring, .portsPanel],
        "Connections and logins": [.monitoring, .networkPanel],
        "GPU processes": [.monitoring, .gpuPanel],
        "Services": [.monitoring, .servicesPanel],
        "Containers": [.monitoring, .containersPanel],
        "Server sessions": [.monitoring, .serverSessions, .sessionsPanel, .agentStatus],
        "Logs": [.monitoring, .logsPanel],
        "Kubernetes": [.monitoring, .kubernetesPanel],
    ]

    static let oneOff = "When done (a single command)."
    static let stream = "When Tether stops reading: the connection closes and the next write fails, within seconds (a heartbeat makes sure of it while nothing else is written)."
    static let nothing = "Nothing."

    public static let all: [RemoteCommand] = [
        RemoteCommand(title: "Host status stream",
                      when: "While the host status bar or the host panel is shown; every few seconds (Settings ▸ Monitoring ▸ Refresh).",
                      reads: "CPU, memory, load and network counters; disks every 30 s and the GPU (nvidia-smi, rocm-smi or sysfs when present) every 10 s; OS details once.",
                      changes: nothing, ends: stream,
                      posix: ProbeScripts.systemStream, windows: WindowsProbeScripts.systemStream),
        RemoteCommand(title: "Running command watcher",
                      when: "While terminals to the host are online (one for all of them); checks every 0.5 s by default (Settings ▸ Monitoring). Can be turned off.",
                      reads: "Each terminal shell's foreground process group (/proc/<pid>/stat with shell built-ins on Linux; one ps for all terminals elsewhere; one CIM query on Windows) and, when it changes, the command line of the program in front.",
                      changes: nothing, ends: stream,
                      posix: ProbeScripts.commandWatch, windows: WindowsProbeScripts.commandWatch),
        RemoteCommand(title: "Running command look",
                      when: "While a command runs in a terminal (or its details are shown): every 3 s by default, one look for all terminals of the host. Without the watcher (turned off, or not working on the host), terminals whose shell state is unknown are looked at every 5 s.",
                      reads: "The process tree below each shell (/proc or ps), command lines, users, CPU time, memory, disk I/O counters, the processes' sockets (ss/netstat, lsof) with TCP byte counters (ss -ti) or nettop on macOS, ICMP sockets (/proc/net/icmp).",
                      changes: nothing, ends: oneOff,
                      posix: ProbeScripts.command, windows: WindowsProbeScripts.command),
        RemoteCommand(title: "Traffic by process",
                      when: "While the Network tab of the host panel is shown; every 2 s by default.",
                      reads: "nettop (macOS), nethogs (Linux, only when it may run as root or with passwordless sudo for nethogs), else the kernel's TCP counters (ss -tinp), else connections (netstat; Get-NetTCPConnection on Windows).",
                      changes: "Nothing. nethogs is only used when already installed; it and the helpers started with it are stopped when Tether stops reading.",
                      ends: stream,
                      posix: ProbeScripts.processTraffic, windows: WindowsProbeScripts.processTraffic),
        RemoteCommand(title: "Stop a running command",
                      when: "Only when you click Terminate or Kill in the Command tab (after confirming).",
                      reads: "Whether the processes are still running afterwards.",
                      changes: "Sends the signal (TERM or KILL) to the command's process group and its processes — never to the shell, its group, group 1 or the script's own group. On Windows: taskkill /T (/F for Kill).",
                      ends: oneOff,
                      posix: ProbeScripts.stopCommand, windows: WindowsProbeScripts.stopCommand),
        RemoteCommand(title: "Host name of a connection",
                      when: "Only when you open the details of a connection.",
                      reads: "The host's own name resolution for the remote address (getent, host, dscacheutil; .NET DNS on Windows).",
                      changes: nothing, ends: oneOff,
                      posix: ProbeScripts.reverseLookup, windows: WindowsProbeScripts.reverseLookup),
        RemoteCommand(title: "Processes",
                      when: "While the Processes tab is shown.",
                      reads: "ps (Get-Process on Windows).", changes: nothing, ends: oneOff,
                      posix: ProbeScripts.processes, windows: WindowsProbeScripts.processes),
        RemoteCommand(title: "Send a signal to a process",
                      when: "Only when you choose Terminate, Kill, Hang Up or Interrupt in the Processes tab.",
                      reads: nothing, changes: "Sends that signal to the selected process.", ends: oneOff,
                      posix: ProbeScripts.kill, windows: WindowsProbeScripts.kill),
        RemoteCommand(title: "Listening ports",
                      when: "While the Ports or Network tab is shown.",
                      reads: "ss, netstat or lsof listening sockets.", changes: nothing, ends: oneOff,
                      posix: ProbeScripts.listening, windows: WindowsProbeScripts.listening),
        RemoteCommand(title: "Connections and logins",
                      when: "While the Network tab is shown; every 10 s.",
                      reads: "who, established TCP connections (ss or netstat), sshd's ports.", changes: nothing, ends: oneOff,
                      posix: ProbeScripts.connections, windows: WindowsProbeScripts.connections),
        RemoteCommand(title: "GPU processes",
                      when: "While the GPU tab is shown (hosts with GPUs).",
                      reads: "nvidia-smi or rocm-smi process lists.", changes: nothing, ends: oneOff,
                      posix: ProbeScripts.gpuProcesses, windows: WindowsProbeScripts.gpuProcesses),
        RemoteCommand(title: "Services",
                      when: "While the Services tab is shown.",
                      reads: "systemctl, launchctl or rc.d service lists.", changes: nothing, ends: oneOff,
                      posix: ProbeScripts.services, windows: WindowsProbeScripts.services),
        RemoteCommand(title: "Start, stop or restart a service",
                      when: "Only when you choose it in the Services tab.",
                      reads: nothing, changes: "Runs that action for the service (with passwordless sudo when needed).", ends: oneOff,
                      posix: ProbeScripts.serviceAction, windows: WindowsProbeScripts.serviceAction),
        RemoteCommand(title: "Containers",
                      when: "While the Containers tab is shown.",
                      reads: "docker or podman ps.", changes: nothing, ends: oneOff,
                      posix: ProbeScripts.containers, windows: WindowsProbeScripts.containers),
        RemoteCommand(title: "Container actions",
                      when: "Only when you choose start, stop, restart or logs for a container.",
                      reads: "Its logs (for logs).", changes: "Starts, stops or restarts that container.", ends: oneOff,
                      posix: ProbeScripts.containerAction, windows: WindowsProbeScripts.containerAction),
        RemoteCommand(title: "Server sessions",
                      when: "When terminals to the host connect, then every 15 s while a window is visible; every 4 s for a host with a tab running a coding agent (Settings ▸ Monitoring).",
                      reads: "tmux and screen session lists, the foreground program of each pane (ps of the panes' terminals only), coding agents' session names.",
                      changes: nothing, ends: oneOff,
                      posix: ProbeScripts.remoteSessions, windows: WindowsProbeScripts.remoteSessions),
        RemoteCommand(title: "Logs",
                      when: "While the Logs tab is shown, when you load a log.",
                      reads: "journalctl, /var/log files, log show or the Windows event log, as chosen.", changes: nothing, ends: oneOff,
                      posix: ProbeScripts.logs(.system, lines: 300).script, windows: WindowsProbeScripts.logs),
        RemoteCommand(title: "Kubernetes",
                      when: "While the Kubernetes tab is shown (hosts with kubectl, k3s, microk8s or oc).",
                      reads: "Pods of the current context.", changes: "Only on request: deletes a pod you chose.", ends: oneOff,
                      posix: KubeScripts.list, windows: KubeScripts.listWindows),
    ]
}
