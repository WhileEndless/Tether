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
        lock.lock(); platforms[key] = nil; lock.unlock()
    }

    func resolve(_ key: String, detect: @escaping @Sendable () async -> RemotePlatform?) async -> RemotePlatform {
        let (known, task): (RemotePlatform?, Task<RemotePlatform?, Never>?) = lock.withLock {
            if let known = platforms[key] { return (known, nil) }
            if let running = pending[key] { return (nil, running) }
            let task = Task<RemotePlatform?, Never> { await detect() }
            pending[key] = task
            return (nil, task)
        }
        if let known { return known }
        guard let task else { return .posix }
        let value = await task.value
        let isNew: Bool = lock.withLock {
            pending[key] = nil
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
    public func resolvedPlatform() async -> RemotePlatform {
        if target.isLocal { return .posix }
        let me = self
        return await PlatformCache.shared.resolve(target.key) { await me.detectPlatform() }
    }

    /// Asks the host's default shell a question only it can answer (see `RemotePlatform.probeCommand`).
    public func detectPlatform() async -> RemotePlatform? {
        if target.isLocal { return .posix }
        let args = options.batchArguments(target: target, remoteCommand: RemotePlatform.probeCommand)
        let env = AskPassBridge.shared.environment(targetKey: target.key, purpose: "connect")
        defer { AskPassBridge.shared.revoke(environment: env) }
        let r = await ProcessRunner.run(options.sshBinary, arguments: args, environment: env, input: Data(), timeout: 20)
        guard !r.timedOut, r.status != 255 else { return nil }
        return RemotePlatform.parse(probeOutput: r.output)
    }

    /// The remote command line and stdin that run `script` with the host's shell.
    func invocation(_ script: RemoteScript, arguments: [String], platform: RemotePlatform, extra: Data?) throws -> (command: String, input: Data) {
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
