import Foundation
import TetherCore

/// Everything needed to build ssh/scp command lines. A plain value so it can cross threads.
public struct SSHOptions: Sendable, Equatable {
    public var sshBinary: String
    public var scpBinary: String
    public var configFile: URL?
    public var useControlMaster: Bool
    public var controlPersistSeconds: Int
    public var serverAliveInterval: Int
    public var serverAliveCountMax: Int
    public var hostKeyPolicy: HostKeyPolicy
    /// Seconds a sign-in waits for the server to answer before it counts as failed (Settings ▸
    /// Sessions ▸ Reconnecting): the shared connection's own, or each tab's without sharing.
    public var connectTimeout = 20
    /// Which shared connection to use. Servers allow only so many sessions per connection
    /// (sshd `MaxSessions`, 10 by default), so many terminals to one host are spread over
    /// several shared connections: slot 0 (also used by monitoring and transfers), 1, 2, …
    public var controlSlot = 0
    /// The shared connection's socket, resolved by `SharedConnections` (`ssh -G`). Set, every ssh
    /// built from these options is a client of that connection only: it can never sign in on its
    /// own (a second login — and a second password question — for work that should share the
    /// first). nil: the old template with `ControlMaster=auto` (only before anything was prepared).
    public var controlPath: String?

    public init(sshBinary: String = "/usr/bin/ssh", scpBinary: String = "/usr/bin/scp", configFile: URL? = nil,
                useControlMaster: Bool = true, controlPersistSeconds: Int = 600,
                serverAliveInterval: Int = 0, serverAliveCountMax: Int = 3, hostKeyPolicy: HostKeyPolicy = .ask) {
        self.sshBinary = sshBinary
        self.scpBinary = scpBinary
        self.configFile = configFile
        self.useControlMaster = useControlMaster
        self.controlPersistSeconds = controlPersistSeconds
        self.serverAliveInterval = serverAliveInterval
        self.serverAliveCountMax = serverAliveCountMax
        self.hostKeyPolicy = hostKeyPolicy
    }

    public init(settings: AppSettings) {
        let custom = settings.sshConfigPath.isEmpty ? nil : settings.resolvedSSHConfigURL
        self.init(sshBinary: settings.sshBinary, scpBinary: settings.scpBinary, configFile: custom,
                  useControlMaster: settings.useControlMaster, controlPersistSeconds: settings.controlPersistSeconds,
                  serverAliveInterval: settings.serverAliveInterval, serverAliveCountMax: settings.serverAliveCountMax,
                  hostKeyPolicy: settings.hostKeyPolicy)
        connectTimeout = min(max(settings.connectTimeout, 5), 300)
    }

    public var controlPathTemplate: String {
        AppPaths.controlSocketDirectory.appendingPathComponent(controlSlot == 0 ? "%C" : "%C-\(controlSlot)").path
    }

    /// Whether ssh built from these options rides on a prepared shared connection (see `controlPath`).
    public var usesSharedConnection: Bool { useControlMaster && controlPath != nil }

    /// Keep-alive options: none unless the user asked for them (Settings ▸ Connection), like plain
    /// `ssh`. Forced keep-alives end a connection after a short silence — a Wi-Fi hand-over, a VPN
    /// reconnecting, the Mac waking from sleep — that plain ssh survives; the user's ssh_config
    /// still applies when Tether sends none.
    func keepAliveOptions() -> [String] {
        guard serverAliveInterval > 0 else { return [] }
        return ["-o", "ServerAliveInterval=\(serverAliveInterval)", "-o", "ServerAliveCountMax=\(max(serverAliveCountMax, 1))"]
    }

    /// Options shared by ssh and scp (`-o` style, valid for both).
    ///
    /// With a prepared shared connection (`controlPath`): `ControlMaster=no` and a ProxyCommand that
    /// fails at once, so a missing connection makes ssh fail instead of signing in by itself; the
    /// caller prepares the connection again (one sign-in for the host) and retries.
    public func commonOptions(multiplex: Bool = true) -> [String] {
        var args: [String] = []
        if let configFile { args += ["-F", configFile.path] }
        if useControlMaster && multiplex, let controlPath {
            args += ["-o", "ControlMaster=no", "-o", "ControlPath=\(controlPath)", "-o", "ProxyCommand=/usr/bin/false"]
        } else if useControlMaster && multiplex {
            args += ["-o", "ControlMaster=auto",
                     "-o", "ControlPath=\(controlPathTemplate)",
                     "-o", "ControlPersist=\(controlPersistSeconds)"]
            args += keepAliveOptions()
        } else {
            args += ["-o", "ControlMaster=no", "-o", "ControlPath=none"]
            args += keepAliveOptions()
        }
        if hostKeyPolicy == .acceptNew { args += ["-o", "StrictHostKeyChecking=accept-new"] }
        return args
    }

    /// The shared connection itself: signs in (asking through askpass if needed), then ssh moves it
    /// to the background (`-N` + ControlPersist) and exits 0. `-N` runs nothing on the server, so it
    /// also suits Windows and network devices. `proxyCommand` replaces the jump-host hop with one
    /// through the jump host's own shared connection (one sign-in there for every host behind it).
    public func masterArguments(target: ConnectionTarget, controlPath: String, logFile: String?, proxyCommand: String?) -> [String] {
        var args: [String] = []
        if let configFile { args += ["-F", configFile.path] }
        args += ["-o", "ControlMaster=yes", "-o", "ControlPath=\(controlPath)",
                 "-o", "ControlPersist=\(max(controlPersistSeconds, 30))", "-o", "ConnectTimeout=\(connectTimeout)"]
        args += keepAliveOptions()
        if hostKeyPolicy == .acceptNew { args += ["-o", "StrictHostKeyChecking=accept-new"] }
        if let proxyCommand { args += ["-o", "ProxyCommand=\(proxyCommand)"] }
        if let logFile { args += ["-v", "-E", logFile] }
        return args + ["-N"] + Self.destinationArguments(for: target, jump: proxyCommand == nil)
    }

    /// `ssh -G` for the target: what ssh would use (host name, user, port, jump host and the shared
    /// connection's socket with `%C` worked out). Nothing goes over the network.
    public func resolveArguments(target: ConnectionTarget, directory: URL = AppPaths.controlSocketDirectory) -> [String] {
        var args: [String] = []
        if let configFile { args += ["-F", configFile.path] }
        let base = directory.appendingPathComponent("%C").path
        return args + ["-o", "ControlPath=\(base)", "-G"] + Self.destinationArguments(for: target)
    }

    /// Destination arguments for this ssh: the jump host is left out when the shared connection
    /// carries it (`-J` cannot be combined with the client's ProxyCommand).
    public func destination(_ target: ConnectionTarget) -> [String] {
        Self.destinationArguments(for: target, jump: !usesSharedConnection)
    }

    /// Destination arguments for ssh (port via -p, jump via -J, user via -l).
    public static func destinationArguments(for target: ConnectionTarget, jump includeJump: Bool = true) -> [String] {
        switch target {
        case .local:
            return []
        case .alias(let alias):
            return ["--", alias]
        case .adhoc(let user, let host, let port, let jump, let identity):
            var a: [String] = []
            if let port { a += ["-p", String(port)] }
            if includeJump, let jump, !jump.isEmpty { a += ["-J", jump] }
            if let user, !user.isEmpty { a += ["-l", user] }
            if let identity, !identity.isEmpty {
                a += ["-i", (identity as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
            }
            return a + ["--", host]
        }
    }

    /// Arguments for scp: port uses -P, and the host is returned separately for `host:path`.
    public static func scpArguments(for target: ConnectionTarget, jump includeJump: Bool = true) -> (options: [String], host: String) {
        switch target {
        case .local:
            return ([], "")
        case .alias(let alias):
            return ([], alias)
        case .adhoc(let user, let host, let port, let jump, let identity):
            var a: [String] = []
            if let port { a += ["-P", String(port)] }
            if includeJump, let jump, !jump.isEmpty { a += ["-J", jump] }
            if let identity, !identity.isEmpty {
                a += ["-i", (identity as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
            }
            let h = host.contains(":") ? "[\(host)]" : host
            return (a, (user.map { "\($0)@" } ?? "") + h)
        }
    }

    /// Full argument list for an interactive terminal session running `remoteCommand`.
    public func interactiveArguments(target: ConnectionTarget, remoteCommand: String?) -> [String] {
        var args = commonOptions() + ["-tt"]
        // Its own sign-in (no prepared shared connection): an unreachable server fails after the
        // same time as a shared connection's, instead of whenever the system gives up.
        if !usesSharedConnection { args += ["-o", "ConnectTimeout=\(connectTimeout)"] }
        args += destination(target)
        if let remoteCommand { args.append(remoteCommand) }
        return args
    }

    /// Argument list for a non-interactive command that reads a script from stdin.
    public func batchArguments(target: ConnectionTarget, remoteCommand: String, connectTimeout: Int = 15,
                               quiet: Bool = false) -> [String] {
        commonOptions() + ["-T", "-o", "ConnectTimeout=\(connectTimeout)"]
            + (quiet ? ["-o", "BatchMode=yes"] : [])
            + destination(target) + [remoteCommand]
    }

    /// Work Tether does on its own in the background (monitoring, latency, finding the platform):
    /// it uses a tab's shared connection, keys or the agent, but never asks for a password or a
    /// passphrase — only a tab the user opens does (BatchMode). Several pop-ups after waking the Mac,
    /// for jobs the user never asked for, were the alternative.
    public static func isQuietPurpose(_ purpose: String) -> Bool {
        ["monitor", "latency", "platform", "forward-keepalive", "sentinel"].contains(purpose)
    }

    /// Arguments for `ssh -O <command>` (check, exit) against the multiplex master.
    public func controlArguments(target: ConnectionTarget, command: String) -> [String] {
        commonOptions() + ["-O", command] + destination(target)
    }
}
