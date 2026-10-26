import Foundation
import TetherCore

/// A remote script with variants per platform. `windows` is PowerShell; nil means the operation
/// is not available on Windows hosts.
public struct RemoteScript: Sendable {
    public var posix: String
    public var windows: String?

    public init(_ posix: String, windows: String? = nil) {
        self.posix = posix
        self.windows = windows
    }
}

/// Remembers which platform each host runs (detected once, then persisted by the app).
public final class PlatformCache: @unchecked Sendable {
    public static let shared = PlatformCache()
    private let lock = NSLock()
    private var platforms: [String: RemotePlatform] = [:]
    private var pending: [String: Task<RemotePlatform?, Never>] = [:]
    /// Called on the main queue after a platform was detected (to persist it).
    public var onDetected: (@Sendable (String, RemotePlatform) -> Void)?

    public func seed(_ values: [String: RemotePlatform]) {
        lock.lock(); platforms.merge(values) { a, _ in a }; lock.unlock()
    }

    public func cached(_ key: String) -> RemotePlatform? {
        lock.lock(); defer { lock.unlock() }
        return platforms[key]
    }

    public func forget(_ key: String) {
        lock.lock(); platforms[key] = nil; devices.remove(key); lock.unlock()
    }

    // MARK: Network devices and limited shells

    private var devices: Set<String> = []
    private var access: [String: ShellAccess] = [:]
    /// Called on the main queue when a host turned out to be a device or limited shell.
    public var onDeviceDetected: (@Sendable (String) -> Void)?

    public func seed(devices keys: Set<String>, access choices: [String: ShellAccess]) {
        lock.lock(); devices.formUnion(keys); access.merge(choices) { _, b in b }; lock.unlock()
    }

    /// The user's choice for a host (from the host editor).
    public func setAccess(_ choice: ShellAccess, for key: String) {
        lock.lock(); access[key] = choice; lock.unlock()
    }

    /// Whether Tether sends this host nothing but a plain login: chosen so, or detected and not
    /// overridden. Nothing is ever run on such a host (`RemoteExecutor.invocation` refuses).
    public func isDevice(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch access[key] ?? .automatic {
        case .device: return true
        case .scripts: return false
        case .automatic: return devices.contains(key)
        }
    }

    /// Whether the host's kind is known, or chosen (then the terminal does not wait for a probe).
    public func isKnown(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return platforms[key] != nil || devices.contains(key) || (access[key] ?? .automatic) != .automatic
    }

    func markDevice(_ key: String) {
        let isNew: Bool = lock.withLock { devices.insert(key).inserted }
        if isNew, let onDeviceDetected { DispatchQueue.main.async { onDeviceDetected(key) } }
    }

    /// - Parameter quiet: background work never shares a detection with a terminal or a user action:
    ///   a quiet one gives up where the other would ask, and a terminal that got its "don't know"
    ///   would treat a Windows host or a network device as a POSIX shell.
    func resolve(_ key: String, quiet: Bool = false, detect: @escaping @Sendable () async -> RemotePlatform?) async -> RemotePlatform {
        let slot = quiet ? key + "\u{0}quiet" : key
        let (known, task): (RemotePlatform?, Task<RemotePlatform?, Never>?) = lock.withLock {
            if let known = platforms[key] { return (known, nil) }
            if let running = pending[slot] { return (nil, running) }
            let task = Task<RemotePlatform?, Never> { await detect() }
            pending[slot] = task
            return (nil, task)
        }
        if let known { return known }
        guard let task else { return .posix }
        let value = await task.value
        let isNew: Bool = lock.withLock {
            pending[slot] = nil
            let isNew = value != nil && platforms[key] == nil
            // An unanswered probe (e.g. no connection) is not remembered, so it is tried again later.
            if let value { platforms[key] = value }
            return isNew
        }
        if isNew, let value, let onDetected { DispatchQueue.main.async { onDetected(key, value) } }
        return value ?? .posix
    }
}

/// Runs PowerShell scripts on Windows hosts, whatever the default shell (cmd or PowerShell).
///
/// The command line only carries a tiny fixed launcher (`-EncodedCommand`, plain base64, so neither
/// cmd nor PowerShell can mangle it). The launcher reads the real script — base64 on the first line
/// of stdin — and runs it; any further stdin stays available to the script. Arguments are embedded
/// as a PowerShell array `$A` with proper quoting.
public enum PowerShell {
    static let launcherSource = "$s=[Console]::In.ReadLine();iex ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s)))"

    public static var launcher: String {
        var utf16 = Data()
        for unit in launcherSource.utf16 { utf16.append(UInt8(unit & 0xff)); utf16.append(UInt8(unit >> 8)) }
        return "powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + utf16.base64EncodedString()
    }

    /// A single-quoted PowerShell string literal.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// The full script with UTF-8 output and the arguments as `$A`.
    public static func prepare(_ script: String, arguments: [String]) -> String {
        let args = arguments.map(quote).joined(separator: ",")
        return "$ErrorActionPreference='Continue';$ProgressPreference='SilentlyContinue';"
            + "[Console]::OutputEncoding=[Text.Encoding]::UTF8;$OutputEncoding=[Text.Encoding]::UTF8;"
            + "$A=@(\(args));\n" + script
    }

    /// CRLF → LF (and stray CRs at line ends removed).
    public static func normalize(_ data: Data) -> Data {
        guard data.contains(0x0d) else { return data }
        var out = Data(capacity: data.count)
        var previousCR = false
        for b in data {
            if previousCR && b != 0x0a { out.append(0x0d) }
            previousCR = b == 0x0d
            if !previousCR { out.append(b) }
        }
        if previousCR { out.append(0x0d) }
        return out
    }

    /// stdin for the launcher: the base64 script on one line.
    public static func input(_ script: String, arguments: [String]) -> Data {
        var d = Data(Data(prepare(script, arguments: arguments).utf8).base64EncodedString().utf8)
        d.append(0x0a)
        return d
    }
}

extension RemoteExecutor {
    /// The host's platform: cached, or detected with one short command over the shared connection.
    /// - Parameter quiet: background work: never asks for a password to find out (see
    ///   `SSHOptions.isQuietPurpose`); an unanswered question is asked again later.
    public func resolvedPlatform(quiet: Bool = false) async -> RemotePlatform {
        if target.isLocal { return .posix }
        let me = self
        return await PlatformCache.shared.resolve(target.key, quiet: quiet) { await me.detectPlatform(quiet: quiet) }
    }

    /// Asks the host's default shell a question only it can answer (see `RemotePlatform.probeCommand`).
    /// No shell's answer: a second, plainer question (`ShellAccess.shellProbeCommand`) tells a shell
    /// that disliked the first (csh: "Undefined variable") from a device or limited shell, which is
    /// then remembered as one — Tether sends it nothing but the terminal's login from then on.
    public func detectPlatform(quiet: Bool = false) async -> RemotePlatform? {
        if target.isLocal { return .posix }
        // Wait for a login to this host in progress, shared connection or not: its host-key
        // question is answered once, and known_hosts has the key when this ssh starts.
        await ConnectionGate.shared.waitForTurn(target.key)
        if quiet, !(await backgroundWorkAllowed()) { return nil }
        guard let first = await ask(RemotePlatform.probeCommand, quiet: quiet) else { return nil }
        if let platform = RemotePlatform.parse(probeOutput: first) { return platform }
        guard let second = await ask(ShellAccess.shellProbeCommand, quiet: quiet) else { return nil }
        if ShellAccess.answersShell(second) { return .posix }
        PlatformCache.shared.markDevice(target.key)
        return .posix
    }

    /// One short command; nil when the host could not be reached (asked again later).
    private func ask(_ command: String, quiet: Bool) async -> String? {
        let args = options.batchArguments(target: target, remoteCommand: command, quiet: quiet)
        let env = AskPassBridge.shared.environment(for: target.key, purpose: quiet ? "platform" : "connect")
        defer { AskPassBridge.shared.revoke(environment: env) }
        let r = await ProcessRunner.run(options.sshBinary, arguments: args, environment: env, input: Data(), timeout: 20)
        if quiet { BackgroundSignIn.shared.noteQuietResult(target.key, status: r.status, stderr: r.errorOutput) }
        guard !r.timedOut, r.status != 255 else { return nil }
        return r.output + "\n" + r.errorOutput
    }

    /// The message for features a device or limited shell cannot have.
    public static let deviceMessage = "Not available on this host: it is a network device or limited shell, so Tether runs nothing on it (Host ▸ Edit ▸ Shell)."

    /// The remote command line and stdin that run `script` with the host's shell.
    func invocation(_ script: RemoteScript, arguments: [String], platform: RemotePlatform, extra: Data?) throws -> (command: String, input: Data) {
        // A device CLI could take script lines as its own commands: nothing is sent to it.
        if !target.isLocal, PlatformCache.shared.isDevice(target.key) { throw RemoteError(Self.deviceMessage) }
        if platform.isWindows {
            guard let ps = script.windows else { throw RemoteError("This is not available on Windows hosts yet.") }
            var input = PowerShell.input(ps, arguments: arguments)
            if let extra { input.append(extra) }
            return (PowerShell.launcher, input)
        }
        var input = Data(script.posix.utf8)
        if !script.posix.hasSuffix("\n") { input.append(0x0a) }
        if let extra { input.append(extra) }
        return ((["sh", "-s", "--"] + arguments.map(\.shellQuoted)).joined(separator: " "), input)
    }
}
