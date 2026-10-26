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
    /// Which shared connection to use. Servers allow only so many sessions per connection
    /// (sshd `MaxSessions`, 10 by default), so many terminals to one host are spread over
    /// several shared connections: slot 0 (also used by monitoring and transfers), 1, 2, …
    public var controlSlot = 0

    public init(sshBinary: String = "/usr/bin/ssh", scpBinary: String = "/usr/bin/scp", configFile: URL? = nil,
                useControlMaster: Bool = true, controlPersistSeconds: Int = 600,
                serverAliveInterval: Int = 15, serverAliveCountMax: Int = 3, hostKeyPolicy: HostKeyPolicy = .ask) {
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
    }

    public var controlPathTemplate: String {
        AppPaths.controlSocketDirectory.appendingPathComponent(controlSlot == 0 ? "%C" : "%C-\(controlSlot)").path
    }

    /// Options shared by ssh and scp (`-o` style, valid for both).
    public func commonOptions(multiplex: Bool = true) -> [String] {
        var args: [String] = []
        if let configFile { args += ["-F", configFile.path] }
        if useControlMaster && multiplex {
            args += ["-o", "ControlMaster=auto",
                     "-o", "ControlPath=\(controlPathTemplate)",
                     "-o", "ControlPersist=\(controlPersistSeconds)"]
        } else {
            args += ["-o", "ControlMaster=no", "-o", "ControlPath=none"]
        }
        args += ["-o", "ServerAliveInterval=\(serverAliveInterval)",
                 "-o", "ServerAliveCountMax=\(serverAliveCountMax)"]
        if hostKeyPolicy == .acceptNew { args += ["-o", "StrictHostKeyChecking=accept-new"] }
        return args
    }

    /// Destination arguments for ssh (port via -p, jump via -J, user via -l).
    public static func destinationArguments(for target: ConnectionTarget) -> [String] {
        switch target {
        case .local:
            return []
        case .alias(let alias):
            return ["--", alias]
        case .adhoc(let user, let host, let port, let jump, let identity):
            var a: [String] = []
            if let port { a += ["-p", String(port)] }
            if let jump, !jump.isEmpty { a += ["-J", jump] }
            if let user, !user.isEmpty { a += ["-l", user] }
            if let identity, !identity.isEmpty {
                a += ["-i", (identity as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
            }
            return a + ["--", host]
        }
    }

    /// Arguments for scp: port uses -P, and the host is returned separately for `host:path`.
    public static func scpArguments(for target: ConnectionTarget) -> (options: [String], host: String) {
        switch target {
        case .local:
            return ([], "")
        case .alias(let alias):
            return ([], alias)
        case .adhoc(let user, let host, let port, let jump, let identity):
            var a: [String] = []
            if let port { a += ["-P", String(port)] }
            if let jump, !jump.isEmpty { a += ["-J", jump] }
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
        args += Self.destinationArguments(for: target)
        if let remoteCommand { args.append(remoteCommand) }
        return args
    }

    /// Argument list for a non-interactive command that reads a script from stdin.
    public func batchArguments(target: ConnectionTarget, remoteCommand: String, connectTimeout: Int = 15,
                               quiet: Bool = false) -> [String] {
        commonOptions() + ["-T", "-o", "ConnectTimeout=\(connectTimeout)"]
            + (quiet ? ["-o", "BatchMode=yes"] : [])
            + Self.destinationArguments(for: target) + [remoteCommand]
    }

    /// Work Tether does on its own in the background (monitoring, latency, finding the platform):
    /// it uses a tab's shared connection, keys or the agent, but never asks for a password or a
    /// passphrase — only a tab the user opens does (BatchMode). Several pop-ups after waking the Mac,
    /// for jobs the user never asked for, were the alternative.
    public static func isQuietPurpose(_ purpose: String) -> Bool {
        ["monitor", "latency", "platform", "forward-keepalive"].contains(purpose)
    }

    /// Arguments for `ssh -O <command>` (check, exit) against the multiplex master.
    public func controlArguments(target: ConnectionTarget, command: String) -> [String] {
        commonOptions() + ["-O", command] + Self.destinationArguments(for: target)
    }
}
