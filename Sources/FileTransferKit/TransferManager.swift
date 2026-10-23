import Foundation
import Observation
import SwiftTerm
import TetherCore
import SSHTransport

public enum TransferDirection: Sendable {
    case upload, download
}

@MainActor
@Observable
public final class TransferItem: Identifiable {
    public enum State: Equatable {
        case queued, running, completed, failed(String), cancelled
    }

    public let id = UUID()
    public let direction: TransferDirection
    public let target: ConnectionTarget
    public let localURL: URL
    public let remotePath: String
    /// For uploads: the file name on the server (nil = keep the local name).
    public let remoteName: String?
    public internal(set) var state: State = .queued
    public internal(set) var progress: Double = 0
    public internal(set) var currentFile = ""
    public internal(set) var speed = ""
    public internal(set) var eta = ""
    /// Amount transferred of the current file, as printed by scp (e.g. "123MB").
    public internal(set) var transferred = ""
    /// Number of files finished so far (for recursive transfers).
    public internal(set) var filesDone = 0
    public internal(set) var startedAt: Date?
    public internal(set) var finishedAt: Date?
    public let createdAt = Date()

    /// Called on completion (success or not).
    @ObservationIgnored public var completion: ((TransferItem) -> Void)?

    init(direction: TransferDirection, target: ConnectionTarget, localURL: URL, remotePath: String, remoteName: String? = nil) {
        self.direction = direction
        self.target = target
        self.localURL = localURL
        self.remotePath = remotePath
        self.remoteName = remoteName
    }

    /// Full path of the uploaded file on the server.
    public var uploadedPath: String {
        let dir = remotePath.hasSuffix("/") ? String(remotePath.dropLast()) : remotePath
        return dir + "/" + (remoteName ?? localURL.lastPathComponent)
    }

    public var name: String {
        direction == .upload ? localURL.lastPathComponent : (remotePath as NSString).lastPathComponent
    }

    public var isFinished: Bool {
        switch state {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }
}

/// Queues scp transfers and reports progress (parsed from scp's progress meter on a PTY).
@MainActor
@Observable
public final class TransferManager {
    public private(set) var items: [TransferItem] = []
    public var maxConcurrent = 2
    @ObservationIgnored private var jobs: [UUID: ScpJob] = [:]
    @ObservationIgnored private let optionsProvider: () -> SSHOptions

    public init(options: @escaping () -> SSHOptions) {
        optionsProvider = options
    }

    public var activeCount: Int { items.filter { $0.state == .running || $0.state == .queued }.count }

    /// Transfers currently moving data.
    public var running: [TransferItem] { items.filter { $0.state == .running } }

    @discardableResult
    public func upload(_ local: URL, to remoteDirectory: String, as name: String? = nil, target: ConnectionTarget,
                       completion: ((TransferItem) -> Void)? = nil) -> TransferItem {
        let item = TransferItem(direction: .upload, target: target, localURL: local, remotePath: remoteDirectory, remoteName: name)
        item.completion = completion
        items.insert(item, at: 0)
        pump()
        return item
    }

    /// Downloads `remotePath` into the local directory (or to an exact file URL).
    @discardableResult
    public func download(_ remotePath: String, to local: URL, target: ConnectionTarget,
                         completion: ((TransferItem) -> Void)? = nil) -> TransferItem {
        let item = TransferItem(direction: .download, target: target, localURL: local, remotePath: remotePath)
        item.completion = completion
        items.insert(item, at: 0)
        pump()
        return item
    }

    public func cancel(_ item: TransferItem) {
        if let job = jobs[item.id] {
            job.cancel()
        } else if item.state == .queued {
            item.state = .cancelled
        }
    }

    public func clearFinished() {
        items.removeAll { $0.isFinished }
    }

    private func pump() {
        while jobs.count < maxConcurrent, let next = items.last(where: { $0.state == .queued }) {
            start(next)
        }
    }

    private func start(_ item: TransferItem) {
        item.state = .running
        item.startedAt = Date()
        let options = optionsProvider()
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
        let env = AskPassBridge.shared.environment(targetKey: item.target.key, purpose: "transfer", mode: "force")
        let job = ScpJob(item: item) { [weak self] job in
            guard let self else { return }
            AskPassBridge.shared.revoke(environment: env)
            self.jobs[item.id] = nil
            item.completion?(item)
            self.pump()
        }
        jobs[item.id] = job
        job.start(executable: executable, arguments: args, environment: env)
    }
}

/// One scp process running on a pseudo terminal so it prints its progress meter.
@MainActor
final class ScpJob {
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
