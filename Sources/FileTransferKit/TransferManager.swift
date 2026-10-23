import Foundation
import Observation
import SwiftTerm
import TetherCore
import SSHTransport

public enum TransferDirection: Sendable {
    case upload, download
}

/// One file or folder of a transfer: where it came from and where it went.
public struct TransferEntry: Hashable, Sendable {
    public var from: String
    public var to: String
    /// Set when the item was renamed to avoid overwriting something at the destination.
    public var renamed: Bool

    public init(from: String, to: String, renamed: Bool = false) {
        self.from = from
        self.to = to
        self.renamed = renamed
    }
}

/// How transfers are carried out. Read from the settings each time a transfer starts.
public struct TransferPolicy: Sendable {
    public var parallel: Int
    public var archiveMode: TransferArchiveMode
    public var archiveThreshold: Int
    public var compress: Bool

    public init(parallel: Int = 3, archiveMode: TransferArchiveMode = .auto, archiveThreshold: Int = 20, compress: Bool = true) {
        self.parallel = parallel
        self.archiveMode = archiveMode
        self.archiveThreshold = archiveThreshold
        self.compress = compress
    }

    /// Whether a transfer with this many files is packed into one stream.
    public func packs(fileCount: Int) -> Bool {
        switch archiveMode {
        case .always: fileCount > 1
        case .never: false
        case .auto: fileCount >= max(archiveThreshold, 2)
        }
    }
}

@MainActor
@Observable
public final class TransferItem: Identifiable {
    public enum State: Equatable {
        case queued, running, completed, failed(String), cancelled
    }

    /// `scp` copies one file or folder; `archive` streams many as one tar.
    public enum Method: Sendable { case scp, archive }

    public let id = UUID()
    public let direction: TransferDirection
    public let method: Method
    public let target: ConnectionTarget
    /// Single transfers: the local file. Packed downloads: the local folder they go into.
    public let localURL: URL
    /// Single transfers: the remote directory (upload) or file (download). Packed: the remote directory.
    public let remotePath: String
    /// For uploads: the file name on the server (nil = keep the local name).
    public let remoteName: String?
    /// What went where. One entry for single transfers.
    public internal(set) var entries: [TransferEntry]
    public internal(set) var state: State = .queued
    public internal(set) var progress: Double = 0
    public internal(set) var currentFile = ""
    public internal(set) var speed = ""
    public internal(set) var eta = ""
    /// Amount transferred of the current file, as printed by scp (e.g. "123MB").
    public internal(set) var transferred = ""
    /// Number of files finished so far (for recursive transfers).
    public internal(set) var filesDone = 0
    /// Files in the transfer (folders counted by their contents), when known.
    public internal(set) var fileCount: Int?
    /// Total bytes, when known.
    public internal(set) var totalBytes: Int64?
    /// Bytes moved so far (packed transfers).
    public internal(set) var bytesDone: Int64 = 0
    public internal(set) var startedAt: Date?
    public internal(set) var finishedAt: Date?
    public let createdAt = Date()
    /// Uploads: what to do after a packed upload has been unpacked (rename into place).
    @ObservationIgnored var renames: [(from: String, to: String)] = []
    /// Packed transfers: the local files (upload) or remote names (download).
    @ObservationIgnored var sources: [String] = []

    /// Called on completion (success or not).
    @ObservationIgnored public var completion: ((TransferItem) -> Void)?

    init(direction: TransferDirection, method: Method = .scp, target: ConnectionTarget, localURL: URL,
         remotePath: String, remoteName: String? = nil, entries: [TransferEntry] = []) {
        self.direction = direction
        self.method = method
        self.target = target
        self.localURL = localURL
        self.remotePath = remotePath
        self.remoteName = remoteName
        self.entries = entries
    }

    /// Full path of the uploaded file on the server.
    public var uploadedPath: String {
        Self.join(remotePath, remoteName ?? localURL.lastPathComponent)
    }

    public var name: String {
        if method == .archive { return "\(entries.count) items" }
        return direction == .upload ? localURL.lastPathComponent : (remotePath as NSString).lastPathComponent
    }

    /// Where the data came from, for display ("~/Desktop/a.png", "host:/var/log").
    public var sourceDescription: String {
        let host = target.displayName
        switch (direction, method) {
        case (.upload, .scp): return Self.abbreviate(localURL.path)
        case (.upload, .archive): return Self.commonParent(entries.map(\.from)).map(Self.abbreviate) ?? "several folders"
        case (.download, .scp): return "\(host):\(remotePath)"
        case (.download, .archive): return "\(host):\(remotePath)"
        }
    }

    /// Where the data went.
    public var destinationDescription: String {
        let host = target.displayName
        switch (direction, method) {
        case (.upload, .scp): return "\(host):\(uploadedPath)"
        case (.upload, .archive): return "\(host):\(remotePath)"
        case (.download, .scp): return Self.abbreviate(localURL.path)
        case (.download, .archive): return Self.abbreviate(localURL.path)
        }
    }

    public var isFinished: Bool {
        switch state {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }

    static func join(_ dir: String, _ name: String) -> String {
        (dir.hasSuffix("/") ? String(dir.dropLast()) : dir) + "/" + name
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func commonParent(_ paths: [String]) -> String? {
        let parents = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
        return parents.count == 1 ? parents.first : nil
    }
}

/// A running transfer that can be stopped.
@MainActor
protocol TransferJob: AnyObject {
    func cancel()
}

/// Queues transfers and runs several at once. Single files go through scp; many files are packed
/// into one tar stream (packed here, unpacked on the other side, no temporary archive on disk),
/// which avoids a round trip per file.
@MainActor
@Observable
public final class TransferManager {
    public private(set) var items: [TransferItem] = []
    @ObservationIgnored private var jobs: [UUID: TransferJob] = [:]
    @ObservationIgnored private let optionsProvider: () -> SSHOptions
    @ObservationIgnored private let policyProvider: () -> TransferPolicy

    public init(options: @escaping () -> SSHOptions, policy: @escaping () -> TransferPolicy = { TransferPolicy() }) {
        optionsProvider = options
        policyProvider = policy
    }

    public var policy: TransferPolicy { policyProvider() }

    public var activeCount: Int { items.filter { $0.state == .running || $0.state == .queued }.count }

    /// Transfers currently moving data.
    public var running: [TransferItem] { items.filter { $0.state == .running } }

    // MARK: Single items

    @discardableResult
    public func upload(_ local: URL, to remoteDirectory: String, as name: String? = nil, target: ConnectionTarget,
                       completion: ((TransferItem) -> Void)? = nil) -> TransferItem {
        let item = TransferItem(direction: .upload, target: target, localURL: local, remotePath: remoteDirectory, remoteName: name)
        item.entries = [TransferEntry(from: local.path, to: item.uploadedPath,
                                      renamed: name.map { $0 != local.lastPathComponent } ?? false)]
        if let size = (try? local.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])), size.isDirectory != true {
            item.totalBytes = Int64(size.fileSize ?? 0)
            item.fileCount = 1
        }
        item.completion = completion
        enqueue(item)
        return item
    }

    /// Downloads `remotePath` into the local directory (or to an exact file URL).
    @discardableResult
    public func download(_ remotePath: String, to local: URL, target: ConnectionTarget,
                         completion: ((TransferItem) -> Void)? = nil) -> TransferItem {
        let item = TransferItem(direction: .download, target: target, localURL: local, remotePath: remotePath)
        item.entries = [TransferEntry(from: remotePath, to: local.path,
                                      renamed: local.lastPathComponent != (remotePath as NSString).lastPathComponent)]
        item.completion = completion
        enqueue(item)
        return item
    }

    // MARK: Groups

    /// Uploads files into `remoteDirectory` under the given (already conflict-free) names.
    /// Many files are packed into one stream unless `pack` says otherwise; `completion` runs once
    /// for the whole group.
    @discardableResult
    public func uploadGroup(_ files: [URL], names: [String], to remoteDirectory: String, target: ConnectionTarget,
                            fileCount: Int, totalBytes: Int64?, pack: Bool? = nil,
                            completion: (([TransferItem]) -> Void)? = nil) -> [TransferItem] {
        // Packed streams need a POSIX shell and tar on the host; Windows hosts copy file by file.
        let shouldPack = (pack ?? policy.packs(fileCount: fileCount)) && files.count >= 1 && fileCount > 1
            && PlatformCache.shared.cached(target.key)?.isWindows != true
        if shouldPack {
            let item = TransferItem(direction: .upload, method: .archive, target: target,
                                    localURL: files[0].deletingLastPathComponent(), remotePath: remoteDirectory)
            item.entries = zip(files, names).map {
                TransferEntry(from: $0.path, to: TransferItem.join(remoteDirectory, $1), renamed: $0.lastPathComponent != $1)
            }
            item.sources = files.map(\.path)
            item.renames = zip(files, names).map { ($0.lastPathComponent, $1) }
            item.fileCount = fileCount
            item.totalBytes = totalBytes
            item.completion = { completion?([$0]) }
            enqueue(item)
            return [item]
        }
        var remaining = files.count
        var made: [TransferItem] = []
        for (file, name) in zip(files, names) {
            let item = upload(file, to: remoteDirectory, as: name, target: target) { _ in
                remaining -= 1
                if remaining == 0 { completion?(made) }
            }
            made.append(item)
        }
        return made
    }

    /// Downloads remote items (all in `remoteDirectory`) into a local folder under the given local
    /// names (already conflict-free).
    @discardableResult
    public func downloadGroup(_ remoteNames: [String], from remoteDirectory: String, to localDirectory: URL,
                              as localNames: [String], target: ConnectionTarget, fileCount: Int, totalBytes: Int64?,
                              pack: Bool? = nil, completion: (([TransferItem]) -> Void)? = nil) -> [TransferItem] {
        let shouldPack = (pack ?? policy.packs(fileCount: fileCount)) && fileCount > 1 && !target.isLocal
            && PlatformCache.shared.cached(target.key)?.isWindows != true
        if shouldPack {
            let item = TransferItem(direction: .download, method: .archive, target: target,
                                    localURL: localDirectory, remotePath: remoteDirectory)
            item.entries = zip(remoteNames, localNames).map {
                TransferEntry(from: TransferItem.join(remoteDirectory, $0), to: localDirectory.appendingPathComponent($1).path,
                              renamed: $0 != $1)
            }
            item.sources = remoteNames
            item.renames = Array(zip(remoteNames, localNames))
            item.fileCount = fileCount
            item.totalBytes = totalBytes
            item.completion = { completion?([$0]) }
            enqueue(item)
            return [item]
        }
        var remaining = remoteNames.count
        var made: [TransferItem] = []
        for (remote, local) in zip(remoteNames, localNames) {
            let item = download(TransferItem.join(remoteDirectory, remote), to: localDirectory.appendingPathComponent(local),
                                target: target) { _ in
                remaining -= 1
                if remaining == 0 { completion?(made) }
            }
            made.append(item)
        }
        return made
    }

    public func cancel(_ item: TransferItem) {
        if let job = jobs[item.id] {
            job.cancel()
        } else if item.state == .queued {
            item.state = .cancelled
            item.finishedAt = Date()
            item.completion?(item)
        }
    }

    public func cancelAll() {
        for item in items where !item.isFinished { cancel(item) }
    }

    public func clearFinished() {
        items.removeAll { $0.isFinished }
    }

    public func remove(_ item: TransferItem) {
        guard item.isFinished else { return }
        items.removeAll { $0.id == item.id }
    }

    // MARK: Scheduling

    private func enqueue(_ item: TransferItem) {
        items.insert(item, at: 0)
        pump()
    }

    /// Starts queued transfers in the order they were added, up to the parallel limit.
    private func pump() {
        let limit = min(max(policy.parallel, 1), 16)
        while jobs.count < limit, let next = items.last(where: { $0.state == .queued }) {
            start(next)
        }
    }

    private func finished(_ item: TransferItem) {
        jobs[item.id] = nil
        item.completion?(item)
        pump()
    }

    private func start(_ item: TransferItem) {
        item.state = .running
        item.startedAt = Date()
        let options = optionsProvider()
        let env = AskPassBridge.shared.environment(targetKey: item.target.key, purpose: "transfer", mode: "force")
        let done: @MainActor () -> Void = { [weak self] in
            AskPassBridge.shared.revoke(environment: env)
            self?.finished(item)
        }
        if item.method == .archive {
            let job = ArchiveJob(item: item, options: options, compress: policy.compress, environment: env, onFinish: done)
            jobs[item.id] = job
            job.start()
            return
        }
        var executable = options.scpBinary
        var args: [String]
        if item.target.isLocal {
            // "Remote" is this Mac: a plain recursive copy.
            executable = "/bin/cp"
            args = ["-Rp", "--"] + (item.direction == .upload ? [item.localURL.path, item.remoteName == nil ? item.remotePath : item.uploadedPath]
                                                              : [item.remotePath, item.localURL.path])
        } else {
            let (destOpts, host) = SSHOptions.scpArguments(for: item.target)
            args = options.commonOptions() + destOpts + ["-r", "-p"]
            switch item.direction {
            case .upload:
                args += ["--", item.localURL.path, "\(host):\(item.remoteName == nil ? item.remotePath : item.uploadedPath)"]
            case .download:
                args += ["--", "\(host):\(item.remotePath)", item.localURL.path]
            }
        }
        let job = ScpJob(item: item) { _ in done() }
        jobs[item.id] = job
        job.start(executable: executable, arguments: args, environment: env)
    }
}

/// One scp process running on a pseudo terminal so it prints its progress meter.
@MainActor
final class ScpJob: TransferJob {
    private let item: TransferItem
    private var process: LocalProcess?
    private var bridge: ScpBridge?
    private var output = ""
    private var cancelled = false
    private let onFinish: (ScpJob) -> Void

    init(item: TransferItem, onFinish: @escaping (ScpJob) -> Void) {
        self.item = item
        self.onFinish = onFinish
    }

    func start(executable: String, arguments: [String], environment: [String: String]) {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        for (k, v) in environment { env[k] = v }
        let bridge = ScpBridge(job: self)
        self.bridge = bridge
        let p = LocalProcess(delegate: bridge, dispatchQueue: .main)
        process = p
        p.startProcess(executable: executable, args: arguments, environment: env.map { "\($0.key)=\($0.value)" })
    }

    func cancel() {
        cancelled = true
        process?.terminate()
    }

    fileprivate func received(_ bytes: ArraySlice<UInt8>) {
        let text = String(decoding: bytes, as: UTF8.self)
        output += text
        if output.count > 8192 { output = String(output.suffix(4096)) }
        // Progress lines are separated by carriage returns.
        guard let line = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).last(where: { $0.contains("%") }) else { return }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        if let pctIndex = fields.firstIndex(where: { $0.hasSuffix("%") }), let pct = Double(fields[pctIndex].dropLast()) {
            let file = fields[..<pctIndex].joined(separator: " ")
            if file != item.currentFile, !item.currentFile.isEmpty { item.filesDone += 1 }
            item.progress = pct / 100
            item.currentFile = file
            if fields.count > pctIndex + 1 { item.transferred = String(fields[pctIndex + 1]) }
            if fields.count > pctIndex + 2 { item.speed = String(fields[pctIndex + 2]) }
            if fields.count > pctIndex + 3 { item.eta = String(fields[pctIndex + 3]) }
        }
    }

    fileprivate func terminated(_ code: Int32?) {
        process = nil
        item.finishedAt = Date()
        if cancelled {
            item.state = .cancelled
        } else if code == 0 {
            item.progress = 1
            item.state = .completed
        } else {
            let lines = output.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.contains("%") }
            item.state = .failed(lines.suffix(2).joined(separator: "\n").isEmpty
                                 ? "scp exited with code \(code ?? -1)" : lines.suffix(2).joined(separator: "\n"))
        }
        onFinish(self)
    }
}

final class ScpBridge: LocalProcessDelegate {
    weak var job: ScpJob?
    init(job: ScpJob) { self.job = job }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        MainActor.assumeIsolated { job?.terminated(exitCode) }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { job?.received(slice) }
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: 24, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)
    }
}
