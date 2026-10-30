import Foundation
import TetherCore
import SSHTransport

/// How busy a machine's processors are: enough to tell whether compressing a stream there would
/// slow it down rather than speed it up.
public struct HostCPU: Equatable, Sendable {
    public var cores: Int?
    public var load: Double?

    public init(cores: Int?, load: Double?) {
        self.cores = cores
        self.load = load
    }

    /// Few cores (a small board, a tiny VM), or every core already busy.
    public var isWeak: Bool {
        guard let cores, cores > 0 else { return false }
        return cores <= 2 || (load ?? 0) / Double(cores) >= 1.5
    }

    /// "2 cores, load 3.4"
    public var summary: String {
        var parts: [String] = []
        if let cores { parts.append("\(cores) core\(cores == 1 ? "" : "s")") }
        if let load { parts.append(String(format: "load %.1f", load)) }
        return parts.joined(separator: ", ")
    }
}

/// What one end of a packed transfer can do: which compressors really compress and uncompress
/// there, whether it has tar, and how busy it is.
public struct HostProbe: Equatable, Sendable {
    public var programs: Set<String>
    public var hasTar: Bool
    public var cpu: HostCPU

    public init(programs: Set<String>, hasTar: Bool, cpu: HostCPU) {
        self.programs = programs
        self.hasTar = hasTar
        self.cpu = cpu
    }

    /// Asked over the existing connection (POSIX hosts only: packed transfers never go to Windows,
    /// whose hosts are sent file by file before this is asked). Each compressor is tried with one
    /// byte through it and back (BusyBox's xz only uncompresses, an old gzip may refuse -1);
    /// processors from getconf, nproc or sysctl, the load from /proc/loadavg or sysctl.
    static let script: String = {
        let names = TransferCompression.methods.compactMap(\.program).joined(separator: " ")
        return #"""
        for t in NAMES; do
          command -v "$t" >/dev/null 2>&1 || continue
          [ "$(printf x | "$t" -1 -c 2>/dev/null | "$t" -d -c 2>/dev/null)" = x ] && echo "z $t"
        done
        command -v tar >/dev/null 2>&1 && echo "tar yes"
        c=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)
        l=$(cut -d ' ' -f 1 /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{ print $1 }')
        echo "cpu ${c:-?} ${l:-?}"
        true
        """#.replacingOccurrences(of: "NAMES", with: names)
    }()

    static func parse(_ text: String) -> HostProbe {
        let known = Set(TransferCompression.methods.compactMap(\.program))
        var probe = HostProbe(programs: [], hasTar: false, cpu: HostCPU(cores: nil, load: nil))
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: " ").map(String.init)
            switch f.first {
            case "z" where f.count == 2 && known.contains(f[1]): probe.programs.insert(f[1])
            case "tar": probe.hasTar = true
            case "cpu" where f.count == 3:
                probe.cpu = HostCPU(cores: Int(f[1]), load: Double(f[2]))
            default: break
            }
        }
        return probe
    }

    /// Kept for a few minutes per server (the load changes); a question that failed counts as
    /// "tar there, nothing to compress with" (the transfer then says what is wrong itself).
    @MainActor private static var cache: [String: (date: Date, probe: HostProbe)] = [:]

    @MainActor
    static func probe(_ target: ConnectionTarget, options: SSHOptions) async -> HostProbe {
        if let known = cache[target.key], Date().timeIntervalSince(known.date) < 300 { return known.probe }
        let r = await RemoteExecutor(target: target, options: options)
            .run(RemoteScript(script, windows: nil), timeout: 15, purpose: "transfer")
        let probe = r.status == 0 ? parse(r.output) : HostProbe(programs: [], hasTar: true, cpu: HostCPU(cores: nil, load: nil))
        cache[target.key] = (Date(), probe)
        return probe
    }

    /// Asked again next time (after a compressed transfer failed).
    @MainActor static func forget(_ target: ConnectionTarget) {
        cache[target.key] = nil
    }

    /// This Mac: its compressors checked the same way, once per run (off the main thread).
    @MainActor private static var localPrograms: Set<String>?

    @MainActor
    static func local() async -> HostProbe {
        let programs: Set<String>
        if let known = localPrograms {
            programs = known
        } else {
            programs = await Task.detached(priority: .userInitiated) { verifiedLocalPrograms() }.value
            localPrograms = programs
        }
        var load = [Double](repeating: 0, count: 3)
        let loaded = getloadavg(&load, 3) > 0
        return HostProbe(programs: programs, hasTar: FileManager.default.isExecutableFile(atPath: "/usr/bin/tar"),
                         cpu: HostCPU(cores: ProcessInfo.processInfo.activeProcessorCount, load: loaded ? load[0] : nil))
    }

    nonisolated static func verifiedLocalPrograms() -> Set<String> {
        var found = Set<String>()
        for program in TransferCompression.methods.compactMap(\.program) {
            guard let path = ArchiveJob.localPath(program) else { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", #"[ "$(printf x | "$1" -1 -c 2>/dev/null | "$1" -d -c 2>/dev/null)" = x ]"#, "sh", path]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let deadline = Date().addingTimeInterval(5)
            while p.isRunning, Date() < deadline { usleep(10_000) }
            if p.isRunning { p.terminate(); continue }
            if p.terminationStatus == 0 { found.insert(program) }
        }
        return found
    }
}

/// A question before a packed transfer: the end that compresses is slow, and compressing there
/// would cost more than it saves.
public struct CompressionQuestion: Equatable, Sendable {
    /// "example.com is slow to compress (2 cores, load 3.4)."
    public var text: String
    /// The method compressing anyway would use.
    public var method: TransferCompression
}

/// Whether to compress a packed stream, given what both ends have and how busy the compressing
/// end is.
enum CompressionAdvice: Equatable {
    case use(TransferCompression?)
    case ask(CompressionQuestion)

    /// Large enough that a slow compressor costs more than it saves.
    static let largeTransfer: Int64 = 256 << 20
    /// Small enough never to hold up with a question.
    static let smallTransfer: Int64 = 16 << 20

    /// - Parameters:
    ///   - chosen: the setting; `resolved`: what both ends have of it.
    ///   - both: compressors both ends have; `side`: the compressing end's name and processors.
    static func decide(chosen: TransferCompression, resolved: TransferCompression?, both: Set<String>,
                       side: String, cpu: HostCPU, bytes: Int64?, adapt: Bool) -> CompressionAdvice {
        guard adapt, let method = resolved, cpu.isWeak else { return .use(resolved) }
        if chosen == .auto {
            // Something light, or nothing: compressing on a busy, small machine only slows it down.
            return .use(method == .lz4 || both.contains("lz4") ? .lz4 : nil)
        }
        if let bytes, bytes < smallTransfer { return .use(method) }
        let heavy = method == .xz || method == .bzip2
        guard heavy || (bytes ?? 0) >= largeTransfer else { return .use(method) }
        let detail = cpu.summary.isEmpty ? "" : " (\(cpu.summary))"
        return .ask(CompressionQuestion(text: "\(side) is slow to compress\(detail).", method: method))
    }
}
