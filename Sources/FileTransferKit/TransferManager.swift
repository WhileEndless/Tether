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
    public var compression: TransferCompression
    /// Compress less (or not at all) when the compressing end is slow — a few cores, or busy —
    /// and ask first before a heavy method chosen in Settings runs there.
    public var adaptToSlowHosts: Bool

    public init(parallel: Int = 3, archiveMode: TransferArchiveMode = .auto, archiveThreshold: Int = 5,
                compression: TransferCompression = .auto, adaptToSlowHosts: Bool = true) {
        self.parallel = parallel
        self.archiveMode = archiveMode
        self.archiveThreshold = archiveThreshold
        self.compression = compression
        self.adaptToSlowHosts = adaptToSlowHosts
    }

    /// Whether a transfer with this many files is packed into one stream.
    public func packs(fileCount: Int) -> Bool {
        switch archiveMode {
        // Also one file: a large log or dump goes compressed.
        case .always: fileCount >= 1
        case .never: false
        case .auto: fileCount >= max(archiveThreshold, 2)
        }
    }
}

/// What a packed transfer is doing now (its stream packs, sends and unpacks at the same time).
public enum TransferStage: Equatable, Sendable {
    /// Asking the host what it has (tar, compressors) and how busy it is.
    case checkingHost
    /// Checking the names at the destination.
    case checkingNames
    /// Waiting for the user's answer (`TransferItem.question`).
    case waitingForAnswer
    /// Packing (and compressing) on one end, sending, unpacking on the other.
    case streaming
    /// Everything was sent; the receiving end unpacks the rest.
    case finishing
    case movingIntoPlace
    case removingTemporary
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
    public internal(set) var localURL: URL
    /// Single transfers: the remote directory (upload) or file (download). Packed: the remote directory.
    public let remotePath: String
    /// For uploads: the file name on the server (nil = keep the local name). Set again when the
    /// name was taken by the time the copy started (the next free one is used, never a replacement).
    public internal(set) var remoteName: String?
    /// What went where. One entry for single transfers.
    public internal(set) var entries: [TransferEntry]
    public internal(set) var state: State = .queued
    public internal(set) var progress: Double = 0
    public internal(set) var currentFile = ""
    public internal(set) var speed = ""
    /// How a packed transfer's stream was compressed (nil: not compressed, or not packed).
    public internal(set) var compression: TransferCompression?
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
    /// Cancelled, and its processes are being stopped.
    public internal(set) var isStopping = false
    /// Packed transfers: what is happening now.
    public internal(set) var stage: TransferStage?
    /// Something worth knowing about how it was sent ("sent file by file: … has no tar").
    public internal(set) var note: String?
    /// A question that holds up the start (see `TransferManager.answer`).
    public internal(set) var question: CompressionQuestion?
    public internal(set) var startedAt: Date?
    public internal(set) var finishedAt: Date?
    public let createdAt = Date()
    /// Uploads: what to do after a packed upload has been unpacked (rename into place).
    @ObservationIgnored var renames: [(from: String, to: String)] = []
    /// Packed transfers: the local files (upload) or remote names (download).
    @ObservationIgnored var sources: [String] = []

    /// Called on completion (success or not), once.
    @ObservationIgnored public var completion: ((TransferItem) -> Void)?
    @ObservationIgnored private var reported = false
    /// Packed transfers: the group's completion (kept for Retry and for sending file by file).
    @ObservationIgnored var groupCompletion: (([TransferItem]) -> Void)?
    /// Retry was asked for (it is being sent again: not twice).
    @ObservationIgnored var retrying = false

    func report() {
        guard !reported else { return }
        reported = true
        completion?(self)
    }

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

    /// A failed transfer can be sent again from the start (with the same rules: nothing is overwritten).
    public var canRetry: Bool {
        if case .failed = state { return !retrying }
        return false
    }

    /// The stage in words, with where it runs ("Packing and compressing on this Mac (zstd), sending,
    /// unpacking on example.com").
    public var stageText: String? {
        guard let stage, state == .running else { return nil }
        let host = target.displayName
        let up = direction == .upload
        switch stage {
        case .checkingHost: return "Asking \(host) what it can unpack and compress…"
        case .checkingNames: return "Checking the names on \(host)…"
        case .waitingForAnswer: return question?.text ?? "Waiting for your answer…"
        case .streaming:
            let packing = compression.map { "Packing and compressing (\($0.program ?? $0.rawValue))" } ?? "Packing"
            return up ? "\(packing) on this Mac, sending, unpacking on \(host)"
                      : "\(packing) on \(host), sending, unpacking on this Mac"
        case .finishing: return up ? "Unpacking on \(host)…" : "Unpacking on this Mac…"
        case .movingIntoPlace: return up ? "Moving into place on \(host)…" : "Moving into place…"
        case .removingTemporary: return up ? "Removing temporary files on \(host)…" : "Removing temporary files…"
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

/// How long a transfer may go without moving anything before it is stopped as stalled.
public struct TransferTimeouts: Sendable {
    /// Once data has moved.
    public var stall: TimeInterval
    /// Before any data moved (connecting, perhaps waiting for a password).
    public var firstData: TimeInterval
    /// After asking a transfer's programs to end, how long before they are killed.
    public var stopGrace: TimeInterval
    /// A transfer that has heard nothing from its server for this long no longer keeps other
    /// servers' transfers waiting for a place (see `TransferManager.pump`).
    public var unanswered: TimeInterval

    public init(stall: TimeInterval = 120, firstData: TimeInterval = 600, stopGrace: TimeInterval = 3, unanswered: TimeInterval = 10) {
        self.stall = stall
        self.firstData = firstData
        self.stopGrace = stopGrace
        self.unanswered = unanswered
    }
}

/// The work before a transfer starts — finding the folder, checking names on the server, counting
/// the files — shown with the transfers and cancellable.
@MainActor
@Observable
public final class TransferPreparation: Identifiable {
    public enum Step: Equatable, Sendable {
        case resolvingFolder
        case checkingNames(Int)
        case countingLocal
        case countingRemote
    }

    public let id = UUID()
    public let direction: TransferDirection
    public let target: ConnectionTarget
    /// What it is for ("Upload 3 items to example.com:/srv").
    public let title: String
    public internal(set) var step: Step = .resolvingFolder
    /// Counted so far (local counts).
    public internal(set) var files = 0
    public internal(set) var bytes: Int64 = 0
    public internal(set) var isCancelled = false
    public let startedAt = Date()
    @ObservationIgnored let counter = MeasureCounter()
    @ObservationIgnored var cancelHandler: (() -> Void)?

    init(direction: TransferDirection, target: ConnectionTarget, title: String) {
        self.direction = direction
        self.target = target
        self.title = title
    }

    /// "Counting files… 12,345 files, 3.2 GB so far"
    public var statusText: String {
        switch step {
        case .resolvingFolder:
            return "Finding the folder on the server…"
        case .checkingNames(let n):
            return n == 1 ? "Checking the name on the server…" : "Checking \(n.formatted()) names on the server…"
        case .countingLocal:
            guard files > 0 else { return "Counting files…" }
            return "Counting files… \(files.formatted()) file\(files == 1 ? "" : "s"), "
                + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " so far"
        case .countingRemote:
            return "Counting files on the server…"
        }
    }
}

/// Whether a continuation was resumed (touched on the main actor only).
private final class ResumeOnce: @unchecked Sendable {
    var done = false
}

/// A running transfer that can be stopped.
@MainActor
protocol TransferJob: AnyObject {
    func cancel()
    /// Quitting: sends the signal to the job's processes now.
    func signalForQuit(_ signal: Int32)
    var hasExited: Bool { get }
    /// Something came from the server (the copy began): it is not waiting for a server that does
    /// not answer.
    var hasMoved: Bool { get }
    /// Quitting, once its processes ended: removes what it left on this Mac at once (and on the
    /// server through a detached ssh).
    func cleanUpForQuit()
}

/// Queues transfers and runs several at once. Single files go through scp; many files are packed
/// into one tar stream (packed here, unpacked on the other side, no temporary archive on disk),
/// which avoids a round trip per file.
///
/// Every transfer ends: cancelling stops its processes (killed after a grace period), one that
/// moves nothing for too long fails as stalled, and its place in the parallel limit is freed
/// whatever happened. When the app quits, running transfers are stopped and what they left
/// (partial files, staging folders) is removed — only what they made themselves.
@MainActor
@Observable
public final class TransferManager {
    public private(set) var items: [TransferItem] = []
    /// Transfers being prepared (names checked, files counted).
    public private(set) var preparations: [TransferPreparation] = []
    @ObservationIgnored private var jobs: [UUID: TransferJob] = [:]
    /// When each job started (see `unansweredHosts`).
    @ObservationIgnored private var launched: [UUID: Date] = [:]
    /// Starts the queue again once a job has waited `TransferTimeouts.unanswered` (see `pump`).
    @ObservationIgnored private var unansweredCheck: Task<Void, Never>?
    /// Transfers whose shared connection is being prepared (they count towards the parallel limit).
    @ObservationIgnored private var preparing: Set<UUID> = []
    /// Their preparation, so a cancel stops waiting for the sign-in (and its question) at once.
    @ObservationIgnored private var preparingTasks: [UUID: Task<Void, Never>] = [:]
    /// Uploads whose name is being checked on the server right before the copy (counted too).
    @ObservationIgnored private var starting: Set<UUID> = []
    /// Where each transfer from queued to finished will write (see `destinations(of:)`): no two
    /// transfers ever choose the same name, and a cleanup removes only what its own transfer reserved.
    @ObservationIgnored private var reservations: [UUID: Set<String>] = [:]
    /// Transfers waiting for an answer to their question; nil: cancelled.
    @ObservationIgnored private var questionWaiters: [UUID: CheckedContinuation<(compress: Bool, remember: Bool)?, Never>] = [:]
    /// Answers kept for a host while Tether runs (compress there, or not).
    @ObservationIgnored private var compressionChoices: [String: Bool] = [:]
    @ObservationIgnored private let optionsProvider: () -> SSHOptions
    @ObservationIgnored private let policyProvider: () -> TransferPolicy
    @ObservationIgnored public var timeouts = TransferTimeouts()
    @ObservationIgnored private var quitting = false
    @ObservationIgnored nonisolated(unsafe) private var quitObserver: NSObjectProtocol?

    public init(options: @escaping () -> SSHOptions, policy: @escaping () -> TransferPolicy = { TransferPolicy() }) {
        optionsProvider = options
        policyProvider = policy
        // Posted on the main thread as the app ends (AppKit's NSApplicationWillTerminateNotification).
        quitObserver = NotificationCenter.default.addObserver(forName: Notification.Name("NSApplicationWillTerminateNotification"),
                                                              object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAllForQuit() }
        }
    }

    deinit {
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
    }

    public var policy: TransferPolicy { policyProvider() }

    public var activeCount: Int {
        items.filter { $0.state == .running || $0.state == .queued }.count + preparations.count
    }

    /// Transfers currently moving data.
    public var running: [TransferItem] { items.filter { $0.state == .running } }

    // MARK: Single items

    /// Uploads under `name` (the local name when nil). The name is checked right before the copy
    /// starts: when something has it by then, the next free one is used — never a replacement.
    @discardableResult
    public func upload(_ local: URL, to remoteDirectory: String, as name: String? = nil, target: ConnectionTarget,
                       completion: ((TransferItem) -> Void)? = nil) -> TransferItem {
        let item = TransferItem(direction: .upload, target: target, localURL: local, remotePath: remoteDirectory,
                                remoteName: name ?? local.lastPathComponent)
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

    /// Two names that would be the same file in one folder (ignoring case on the Mac's disk).
    static func hasClashingNames(_ names: [String], caseInsensitive: Bool) -> Bool {
        let keys = names.map { caseInsensitive ? $0.lowercased() : $0 }
        return Set(keys).count != keys.count
    }

    /// Uploads files into `remoteDirectory` under the given (already conflict-free) names.
    /// Many files are packed into one stream unless `pack` says otherwise; `completion` runs once
    /// for the whole group.
    @discardableResult
    public func uploadGroup(_ files: [URL], names: [String], to remoteDirectory: String, target: ConnectionTarget,
                            fileCount: Int, totalBytes: Int64?, pack: Bool? = nil,
                            completion: (([TransferItem]) -> Void)? = nil) -> [TransferItem] {
        // Packed streams need a POSIX shell and tar on the host; Windows hosts copy file by file.
        // Items unpack side by side in one staging folder: two with the same name (from different
        // folders) would land on each other there, so they go file by file instead.
        let shouldPack = (pack ?? policy.packs(fileCount: fileCount)) && files.count >= 1 && fileCount > 1
            && PlatformCache.shared.cached(target.key)?.isWindows != true && !PlatformCache.shared.isDevice(target.key)
            && !Self.hasClashingNames(files.map(\.lastPathComponent), caseInsensitive: false)
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
            item.groupCompletion = completion
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
        // The Mac's disk ignores case: README and readme from a Linux folder would unpack onto each
        // other in the staging folder, so they go file by file (each to its own free name).
        let shouldPack = (pack ?? policy.packs(fileCount: fileCount)) && fileCount > 1 && !target.isLocal
            && PlatformCache.shared.cached(target.key)?.isWindows != true && !PlatformCache.shared.isDevice(target.key)
            && !Self.hasClashingNames(remoteNames, caseInsensitive: true)
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
            item.groupCompletion = completion
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

    /// What a download of several items gave: each arrived item's local URL by remote path, how
    /// many did not arrive, and the last error. nil (in the completion): cancelled before anything was sent.
    public struct DownloadOutcome: Sendable {
        public var arrived: [String: URL]
        public var failed: Int
        public var message: String?
    }

    /// The one way several remote items are downloaded (the Download command, ⌘C, a drag to
    /// Finder): counted first when folders are among them (shown, cancellable), then one packed
    /// stream when the policy says so, otherwise file by file, under free local names.
    /// `completion` runs once.
    public func downloadItems(_ items: [RemoteFile], from target: ConnectionTarget, to local: URL, fs: RemoteFileSystem,
                              completion: @escaping (DownloadOutcome?) -> Void) {
        var reported = false
        let report: (DownloadOutcome?) -> Void = { outcome in
            guard !reported else { return }
            reported = true
            completion(outcome)
        }
        guard !items.isEmpty else { report(DownloadOutcome(arrived: [:], failed: 0)); return }
        let parents = Set(items.map { ($0.path as NSString).deletingLastPathComponent })
        Task { @MainActor in
            // Staging folders an interrupted packed download left here (a crash) go first.
            await self.removeLeftovers(in: local)
            // Only folders need counting; plain files are counted as they are.
            var size = TransferSize(files: items.count, bytes: items.reduce(0) { $0 + ($1.isDirectory ? 0 : $1.size) })
            if items.contains(where: \.isDirectory), self.policy.archiveMode != .never {
                let prep = self.beginPreparation(.download, target: target,
                                                 title: "Download \(items.count) item\(items.count == 1 ? "" : "s") from \(target.displayName)")
                let paths = items.map(\.path)
                var cancelled = false
                do {
                    if let counted = try await self.untilCancelled(prep, step: .countingRemote, { try await fs.measure(paths) }) {
                        size = counted
                    } else {
                        cancelled = true
                    }
                } catch {
                    // Could not count (a very large tree, a slow host): planned from what the listing says.
                }
                self.endPreparation(prep)
                if cancelled { report(nil); return }
            }
            try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            let names = LocalFiles.uniqueNames(in: local, for: items.map(\.name),
                                               alsoTaken: self.reservedLocalNames(in: local, except: UUID()))
            let finish: ([TransferItem]) -> Void = { made in
                var arrived: [String: URL] = [:]
                var message: String?
                for item in made {
                    if case .failed(let text) = item.state { message = text }
                    if item.state == .cancelled { message = message ?? "The download was cancelled." }
                    guard item.state == .completed else { continue }
                    for entry in item.entries where LocalFiles.exists(entry.to) { arrived[entry.from] = URL(fileURLWithPath: entry.to) }
                }
                let missing = items.count - arrived.count
                if missing > 0, message == nil { message = "\(missing) item\(missing == 1 ? "" : "s") did not arrive." }
                report(DownloadOutcome(arrived: arrived, failed: missing, message: message))
            }
            if parents.count == 1, let parent = parents.first {
                self.downloadGroup(items.map(\.name), from: parent, to: local, as: names, target: target,
                                   fileCount: size.files, totalBytes: size.bytes, completion: finish)
            } else {
                var made: [TransferItem] = []
                var remaining = items.count
                for (f, name) in zip(items, names) {
                    made.append(self.download(f.path, to: local.appendingPathComponent(name), target: target) { _ in
                        remaining -= 1
                        if remaining == 0 { finish(made) }
                    })
                }
            }
        }
    }

    // MARK: Cancel and retry

    /// Stops a transfer: a running one ends its processes (it shows "Stopping…" until they are
    /// gone); one queued, preparing its connection or checking its name ends at once and frees its place.
    public func cancel(_ item: TransferItem) {
        if let job = jobs[item.id] {
            item.isStopping = true
            job.cancel()
            return
        }
        guard !item.isFinished else { return }
        item.state = .cancelled
        item.finishedAt = Date()
        // Waiting for the sign-in (perhaps a question to the user): no longer waited for.
        preparingTasks.removeValue(forKey: item.id)?.cancel()
        preparing.remove(item.id)
        starting.remove(item.id)
        reservations[item.id] = nil
        item.question = nil
        questionWaiters.removeValue(forKey: item.id)?.resume(returning: nil)
        item.report()
        pump()
    }

    public func cancelAll() {
        for p in preparations { cancel(p) }
        for item in items where !item.isFinished { cancel(item) }
    }

    public func clearFinished() {
        items.removeAll { $0.isFinished }
    }

    public func remove(_ item: TransferItem) {
        guard item.isFinished else { return }
        items.removeAll { $0.id == item.id }
    }

    /// Sends a failed transfer again from the start, in its place in the list. The same rules as
    /// the first time: free names are chosen again (what the failed attempt left was removed),
    /// nothing is overwritten. Items whose source is gone fail with that reason.
    public func retry(_ item: TransferItem) {
        guard item.canRetry, items.contains(where: { $0.id == item.id }) else { return }
        let target = item.target
        let missing = item.direction == .upload
            ? (item.method == .archive ? item.sources : [item.localURL.path]).first { !LocalFiles.exists($0) } : nil
        if let missing {
            item.state = .failed("\((missing as NSString).lastPathComponent) is no longer on this Mac, so it cannot be sent again.")
            return
        }
        item.retrying = true
        // A packed transfer tells its group again (an upload bar, a folder to refresh); a single
        // copy's completion belongs to the first attempt (a drag to Finder answers only once).
        let group = item.groupCompletion
        switch (item.direction, item.method) {
        case (.upload, .scp):
            items.removeAll { $0.id == item.id }
            upload(item.localURL, to: item.remotePath, as: item.remoteName, target: target)
        case (.download, .scp):
            items.removeAll { $0.id == item.id }
            download(item.remotePath, to: item.localURL, target: target)
        case (.download, .archive):
            items.removeAll { $0.id == item.id }
            let names = LocalFiles.uniqueNames(in: item.localURL, for: item.renames.map(\.to),
                                               alsoTaken: reservedLocalNames(in: item.localURL, except: item.id))
            downloadGroup(item.sources, from: item.remotePath, to: item.localURL, as: names, target: target,
                          fileCount: item.fileCount ?? item.sources.count, totalBytes: item.totalBytes, pack: true, completion: group)
        case (.upload, .archive):
            // The names are chosen on the server again, as the first time (from the local names).
            let fs = RemoteFileSystem(executor: RemoteExecutor(target: target, options: optionsProvider()))
            let wanted = item.renames.map(\.from), dir = item.remotePath
            let prep = beginPreparation(.upload, target: target, title: "Upload \(item.entries.count) items to \(target.displayName):\(dir)")
            Task { @MainActor in
                defer { self.endPreparation(prep) }
                do {
                    guard let names = try await self.untilCancelled(prep, step: .checkingNames(wanted.count), {
                        try await fs.uniqueNames(in: dir, for: wanted, mayBeMissing: true)
                    }) else { item.retrying = false; return }
                    self.items.removeAll { $0.id == item.id }
                    self.uploadGroup(item.sources.map { URL(fileURLWithPath: $0) }, names: names, to: dir, target: target,
                                     fileCount: item.fileCount ?? item.sources.count, totalBytes: item.totalBytes, pack: true,
                                     completion: group)
                } catch {
                    item.retrying = false
                    item.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: Preparing

    /// Shows the work before a transfer (with the transfers, cancellable) until `endPreparation`.
    public func beginPreparation(_ direction: TransferDirection, target: ConnectionTarget, title: String) -> TransferPreparation {
        let p = TransferPreparation(direction: direction, target: target, title: title)
        preparations.insert(p, at: 0)
        return p
    }

    public func endPreparation(_ p: TransferPreparation) {
        preparations.removeAll { $0.id == p.id }
    }

    /// Stops a preparation: a count stops at once, a question to the server is no longer waited for.
    public func cancel(_ p: TransferPreparation) {
        guard !p.isCancelled else { return }
        p.isCancelled = true
        p.counter.cancel()
        p.cancelHandler?()
        p.cancelHandler = nil
        endPreparation(p)
    }

    /// Counts local files off the main thread, showing the count as it grows. nil when cancelled
    /// (also when the calling task is cancelled).
    public func measureLocal(_ urls: [URL], in p: TransferPreparation) async -> TransferSize? {
        p.step = .countingLocal
        let counter = p.counter
        guard !counter.isCancelled else { return nil }
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                let s = counter.snapshot
                p.files = s.files
                p.bytes = s.bytes
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        let size = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) { LocalFiles.measure(urls, limit: 5_000_000, counter: counter) }.value
        } onCancel: {
            counter.cancel()
        }
        poll.cancel()
        p.files = size.files
        p.bytes = size.bytes
        return counter.isCancelled ? nil : size
    }

    /// Runs `work` (a question to the server) for a preparation; nil as soon as the preparation is
    /// cancelled (the answer, when it comes, is ignored).
    public func untilCancelled<T: Sendable>(_ p: TransferPreparation, step: TransferPreparation.Step? = nil,
                                            _ work: @escaping @Sendable () async throws -> T) async throws -> T? {
        guard !p.isCancelled else { return nil }
        if let step { p.step = step }
        let once = ResumeOnce()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T?, Error>) in
            let finish: @MainActor (Result<T?, Error>) -> Void = { r in
                guard !once.done else { return }
                once.done = true
                p.cancelHandler = nil
                c.resume(with: r)
            }
            p.cancelHandler = { finish(.success(nil)) }
            Task { @MainActor in
                do { finish(.success(try await work())) } catch { finish(.failure(error)) }
            }
        }
    }

    // MARK: Scheduling

    private func enqueue(_ item: TransferItem) {
        items.insert(item, at: 0)
        if quitting {
            item.state = .cancelled
            item.finishedAt = Date()
            item.report()
            return
        }
        reserve(item)
        pump()
    }

    /// Starts queued transfers in the order they were added, up to the parallel limit.
    private func pump() {
        guard !quitting else { return }
        let limit = min(max(policy.parallel, 1), 16)
        // A host whose sign-in hangs holds one place, never the whole queue: one transfer per host is
        // prepared at a time (the others of that host follow once its connection is there).
        while let next = items.last(where: { item in
                  item.state == .queued && !items.contains { preparing.contains($0.id) && $0.target.key == item.target.key }
                      && mayStart(item, limit: limit)
              }) {
            start(next)
        }
        checkUnansweredSoon()
    }

    /// Within the parallel limit; or beyond it by as many transfers as wait for servers that do not
    /// answer — never for one of those servers. A server that does not answer (its connection died
    /// unnoticed, a firewall drops everything) then holds up only its own transfers, until they fail
    /// as stalled or are stopped.
    private func mayStart(_ item: TransferItem, limit: Int) -> Bool {
        let busy = jobs.count + preparing.count + starting.count
        if busy < limit { return true }
        let silent = unansweredHosts()
        guard !silent.isEmpty, !silent.keys.contains(item.target.key) else { return false }
        return busy - silent.values.reduce(0, +) < limit
    }

    /// Hosts with jobs that have heard nothing from their server since they started
    /// `TransferTimeouts.unanswered` ago, and how many such jobs each has.
    private func unansweredHosts() -> [String: Int] {
        let now = Date()
        var hosts: [String: Int] = [:]
        for (id, job) in jobs where !job.hasMoved {
            guard let at = launched[id], now.timeIntervalSince(at) >= timeouts.unanswered,
                  let item = items.first(where: { $0.id == id }) else { continue }
            hosts[item.target.key, default: 0] += 1
        }
        return hosts
    }

    /// Transfers wait for a place while a job has heard nothing yet: the queue is looked at again
    /// when that job counts as unanswered.
    private func checkUnansweredSoon() {
        guard unansweredCheck == nil, items.contains(where: { $0.state == .queued }) else { return }
        let now = Date()
        let due = jobs.filter { !$0.value.hasMoved }.compactMap { launched[$0.key] }
            .map { $0.addingTimeInterval(timeouts.unanswered) }.filter { $0 > now }.min()
        guard let due else { return }
        unansweredCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(due.timeIntervalSince(now) + 0.05))
            guard let self, !Task.isCancelled else { return }
            self.unansweredCheck = nil
            self.pump()
        }
    }

    private func finished(_ item: TransferItem) {
        jobs[item.id] = nil
        launched[item.id] = nil
        preparing.remove(item.id)
        starting.remove(item.id)
        reservations[item.id] = nil
        item.isStopping = false
        item.report()
        pump()
    }

    // MARK: Reserved destinations

    static func remoteKey(_ target: ConnectionTarget, _ path: String) -> String { "R\u{1}\(target.key)\u{1}\(path)" }

    /// The Mac's disk ignores case, so local keys do too.
    static func localKey(_ path: String) -> String { "L\u{1}" + URL(fileURLWithPath: path).standardizedFileURL.path.lowercased() }

    func destinations(of item: TransferItem) -> Set<String> {
        Set(item.entries.map { item.direction == .upload ? Self.remoteKey(item.target, $0.to) : Self.localKey($0.to) })
    }

    private func reserve(_ item: TransferItem) {
        reservations[item.id] = destinations(of: item)
    }

    private func reservedByOthers(_ id: UUID) -> Set<String> {
        reservations.filter { $0.key != id }.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    /// Names (lowercased) other transfers will write into a local folder.
    func reservedLocalNames(in folder: URL, except id: UUID) -> Set<String> {
        let prefix = Self.localKey(folder.path) + "/"
        return Set(reservedByOthers(id).compactMap { key in
            guard key.hasPrefix(prefix) else { return nil }
            let name = key.dropFirst(prefix.count)
            return name.contains("/") ? nil : String(name)
        })
    }

    /// Names other transfers will write into a folder on the server.
    private func reservedRemoteNames(in dir: String, target: ConnectionTarget, except id: UUID) -> Set<String> {
        let prefix = Self.remoteKey(target, TransferItem.join(dir, ""))
        return Set(reservedByOthers(id).compactMap { key in
            guard key.hasPrefix(prefix) else { return nil }
            let name = key.dropFirst(prefix.count)
            return name.contains("/") ? nil : String(name)
        })
    }

    /// Free names on the server that no other transfer has reserved either. The server is asked
    /// for as many free candidates per name as other transfers could hold (`name`, `name-1`, …:
    /// one batch, one round trip); the first candidate nobody reserved is taken — checked again
    /// after the answer, since another transfer may have reserved one meanwhile.
    func freeRemoteNames(_ wanted: [String], in dir: String, fs: RemoteFileSystem, for item: TransferItem,
                         mayBeMissing: Bool = false) async throws -> [String] {
        for _ in 0..<5 {
            let before = reservedRemoteNames(in: dir, target: item.target, except: item.id)
            var request: [String] = []
            var spans: [Range<Int>] = []
            for name in wanted {
                let base = Self.stem(name)
                let k = 1 + before.filter { $0 == name || $0.hasPrefix(base + "-") }.count
                spans.append(request.count..<request.count + k)
                request += Array(repeating: name, count: k)
            }
            let free = try await fs.uniqueNames(in: dir, for: request, mayBeMissing: mayBeMissing)
            let now = reservedRemoteNames(in: dir, target: item.target, except: item.id)
            let picks = spans.map { span in free[span].first { !now.contains($0) } }
            if picks.allSatisfy({ $0 != nil }) { return picks.map { $0! } }
        }
        throw RemoteError("Could not choose free names in \(dir).")
    }

    /// The part of a name a number goes after, as the server's names are made (`LocalFiles.numberedParts`).
    static func stem(_ name: String) -> String {
        LocalFiles.numberedParts(name, separator: "-").base
    }

    private func start(_ item: TransferItem) {
        let device = !item.target.isLocal && PlatformCache.shared.isDevice(item.target.key)
        // Nothing on a network device can say whether a name is taken, so nothing is uploaded
        // there (an existing file must never be overwritten). Downloads work, by plain scp.
        if device, item.direction == .upload {
            item.state = .failed("Uploads to a network device are off: Tether cannot check there that no file would be replaced.")
            item.finishedAt = Date()
            finished(item)
            return
        }
        item.state = .running
        item.startedAt = Date()
        let options = optionsProvider()
        // scp and the packed transfer run as clients of the host's shared connection: prepared
        // first (one sign-in for the host, however many transfers start together).
        if !item.target.isLocal, options.useControlMaster, options.controlPath == nil {
            // Counted as running while the connection is prepared, so the parallel limit holds.
            preparing.insert(item.id)
            preparingTasks[item.id] = Task { @MainActor [weak self] in
                let prepared = await RemoteExecutor(target: item.target, options: options).prepared(purpose: "transfer")
                guard let self else { return }
                self.preparingTasks[item.id] = nil
                self.preparing.remove(item.id)
                // Cancelled meanwhile: it already ended (and freed its place); it stays cancelled.
                guard item.state == .running else { self.pump(); return }
                switch prepared {
                case .ready(let ready):
                    self.start(item, options: ready.options, device: device)
                    self.pump()      // the host's next transfers can be prepared now
                case .refused(let result):
                    item.state = .failed(RemoteExecutor.cleanError(result.errorOutput, fallback: "Could not connect."))
                    item.finishedAt = Date()
                    self.finished(item)
                }
            }
            return
        }
        start(item, options: options, device: device)
    }

    private func start(_ item: TransferItem, options: SSHOptions, device: Bool) {
        let env = AskPassBridge.shared.environment(targetKey: item.target.key, purpose: "transfer", mode: "force")
        let done: @MainActor () -> Void = { [weak self] in
            AskPassBridge.shared.revoke(environment: env)
            self?.finished(item)
        }
        if item.method == .archive {
            // The host's kind is known before anything is packed (a Windows host or a device never
            // gets a POSIX script: it is sent file by file instead), and an upload's names are
            // checked again right before (another transfer or someone may have taken one).
            starting.insert(item.id)
            Task { @MainActor [weak self] in
                await self?.preparePacked(item, options: options, env: env, done: done)
            }
            return
        }
        // The free name was chosen when the download was asked for; it waited in the queue since, and
        // something may have taken the name meanwhile (another download, the user) or another
        // transfer may be about to write it. scp would overwrite it, or copy a folder into the one
        // now there: the next free name instead.
        if item.direction == .download {
            let folder = item.localURL.deletingLastPathComponent()
            let others = reservedLocalNames(in: folder, except: item.id)
            if LocalFiles.exists(item.localURL.path) || others.contains(item.localURL.lastPathComponent.lowercased()) {
                let free = folder.appendingPathComponent(LocalFiles.uniqueNames(in: folder, for: [item.localURL.lastPathComponent],
                                                                                alsoTaken: others)[0])
                item.localURL = free
                item.entries = [TransferEntry(from: item.remotePath, to: free.path, renamed: true)]
                reserve(item)
            }
        }
        // An upload: its name is checked right before the copy (it waited in the queue, and scp
        // would replace a file that took it meanwhile); the next free one is used when it is taken.
        // A partial copy is removed after a failure — it is then this copy's own.
        if item.direction == .upload, let name = item.remoteName {
            starting.insert(item.id)
            let fs = RemoteFileSystem(executor: RemoteExecutor(target: item.target, options: options))
            Task { @MainActor [weak self] in
                guard let self else { return }
                let checked: Result<String, Error>
                do { checked = .success(try await self.freeRemoteNames([name], in: item.remotePath, fs: fs, for: item)[0]) }
                catch { checked = .failure(error) }
                self.starting.remove(item.id)
                guard item.state == .running else { done(); return }
                switch checked {
                case .failure(let error):
                    item.state = .failed("Could not check the name on the server, so nothing was sent: \(error.localizedDescription)")
                    item.finishedAt = Date()
                    done()
                case .success(let free):
                    if free != name {
                        item.remoteName = free
                        item.entries = [TransferEntry(from: item.localURL.path, to: item.uploadedPath, renamed: true)]
                    }
                    self.reserve(item)
                    let path = item.uploadedPath
                    if item.target.isLocal {
                        let clean: () -> Void = { LocalFiles.discard(URL(fileURLWithPath: path)) }
                        self.launchScp(item, options: options, device: device, env: env, cleanUp: clean, quitCleanUp: clean, done: done)
                    } else {
                        let target = item.target
                        self.launchScp(item, options: options, device: device, env: env,
                                       cleanUp: { Task { try? await fs.delete(path) } },
                                       quitCleanUp: { Self.detachedRemoteScript(#"[ -n "$1" ] && [ "$1" != / ] && rm -rf -- "$1""#,
                                                                                arguments: [path], target: target, options: options) },
                                       done: done)
                    }
                }
            }
            return
        }
        let clean = partialCleanup(for: item)
        launchScp(item, options: options, device: device, env: env, cleanUp: clean, quitCleanUp: clean, done: done)
    }

    /// Before a packed transfer starts: the host's kind (a Windows host or a device never gets a
    /// POSIX script), what both ends have (tar, compressors that really work both ways — with no
    /// common packed way it goes file by file, saying why), how to compress given how busy the
    /// compressing end is (asking first when a heavy method would run on a slow one), and an
    /// upload's names checked again right before (another transfer or someone may have taken one).
    /// Nothing is created anywhere until the stream starts.
    private func preparePacked(_ item: TransferItem, options: SSHOptions, env: [String: String], done: @escaping @MainActor () -> Void) async {
        let executor = RemoteExecutor(target: item.target, options: options)
        let host = item.target.displayName
        item.stage = .checkingHost
        let platform = await executor.resolvedPlatform()
        guard item.state == .running else { done(); return }
        if !item.target.isLocal, platform.isWindows || PlatformCache.shared.isDevice(item.target.key) {
            AskPassBridge.shared.revoke(environment: env)
            sendFileByFile(item, reason: platform.isWindows
                ? "Sent file by file: \(host) is a Windows host (packed transfers need tar and a POSIX shell there)."
                : "Sent file by file: \(host) is a network device or limited shell.")
            return
        }
        let local = await HostProbe.local()
        let remote = item.target.isLocal ? local : await HostProbe.probe(item.target, options: options)
        guard item.state == .running else { done(); return }
        guard local.hasTar, remote.hasTar else {
            AskPassBridge.shared.revoke(environment: env)
            sendFileByFile(item, reason: "Sent file by file: \(remote.hasTar ? "this Mac" : host) has no tar to pack with.")
            return
        }
        // Compressing on this Mac itself only costs time.
        var method: TransferCompression?
        let chosen = policy.compression
        if !item.target.isLocal, chosen != .off {
            let resolved = chosen.resolved(local: local.programs, remote: remote.programs)
            if chosen != .auto, resolved != chosen {
                item.note = "\(chosen.rawValue) is not on both ends: " + (resolved.map { "\($0.rawValue) is used." } ?? "sent without compressing.")
            }
            let compressing = item.direction == .upload ? (name: "This Mac", cpu: local.cpu) : (name: host, cpu: remote.cpu)
            switch CompressionAdvice.decide(chosen: chosen, resolved: resolved, both: local.programs.intersection(remote.programs),
                                            side: compressing.name, cpu: compressing.cpu, bytes: item.totalBytes,
                                            adapt: policy.adaptToSlowHosts) {
            case .use(let m):
                method = m
                if chosen == .auto, m != resolved, let resolved {
                    item.note = "\(compressing.name) is slow to compress (\(compressing.cpu.summary)): "
                        + (m.map { "\($0.rawValue) instead of \(resolved.rawValue)." } ?? "sent without compressing.")
                }
            case .ask(let question):
                let key = item.target.key
                let compress: Bool
                if let remembered = compressionChoices[key] {
                    compress = remembered
                } else {
                    item.stage = .waitingForAnswer
                    item.question = question
                    let answer = await withCheckedContinuation { questionWaiters[item.id] = $0 }
                    item.question = nil
                    guard let answer, item.state == .running else { done(); return }
                    compress = answer.compress
                    if answer.remember { compressionChoices[key] = compress }
                }
                method = compress ? question.method : nil
            }
        }
        if item.direction == .upload {
            item.stage = .checkingNames
            do {
                let free = try await freeRemoteNames(item.renames.map(\.to), in: item.remotePath,
                                                     fs: RemoteFileSystem(executor: executor), for: item, mayBeMissing: true)
                for (i, name) in free.enumerated() where name != item.renames[i].to {
                    item.renames[i].to = name
                    if i < item.entries.count {
                        item.entries[i].to = TransferItem.join(item.remotePath, name)
                        item.entries[i].renamed = true
                    }
                }
                reserve(item)
            } catch {
                if item.state == .running {
                    item.state = .failed("Could not check the names on the server, so nothing was sent: \(error.localizedDescription)")
                    item.finishedAt = Date()
                }
                done()
                return
            }
        }
        starting.remove(item.id)
        guard item.state == .running, !quitting else { done(); return }
        let job = ArchiveJob(item: item, options: options, compression: method, environment: env, timeouts: timeouts, onFinish: done)
        job.reservedElsewhere = { [weak self] folder in self?.reservedLocalNames(in: folder, except: item.id) ?? [] }
        jobs[item.id] = job
        launched[item.id] = Date()
        job.start()
    }

    /// Answers a transfer's question (`TransferItem.question`): compress anyway, or send without
    /// compressing; `remember`: the same answer for this host's later transfers while Tether runs.
    public func answer(_ item: TransferItem, compress: Bool, remember: Bool) {
        questionWaiters.removeValue(forKey: item.id)?.resume(returning: (compress, remember))
    }

    /// A packed transfer for a host that turned out not to take one (Windows, a network device, no
    /// tar): sent file by file instead, in its place, telling its group as before.
    private func sendFileByFile(_ item: TransferItem, reason: String) {
        items.removeAll { $0.id == item.id }
        starting.remove(item.id)
        reservations[item.id] = nil
        let made: [TransferItem]
        switch item.direction {
        case .upload:
            made = uploadGroup(item.sources.map { URL(fileURLWithPath: $0) }, names: item.renames.map(\.to), to: item.remotePath,
                               target: item.target, fileCount: item.fileCount ?? item.sources.count, totalBytes: item.totalBytes,
                               pack: false, completion: item.groupCompletion)
        case .download:
            made = downloadGroup(item.sources, from: item.remotePath, to: item.localURL, as: item.renames.map(\.to), target: item.target,
                                 fileCount: item.fileCount ?? item.sources.count, totalBytes: item.totalBytes, pack: false,
                                 completion: item.groupCompletion)
        }
        for m in made { m.note = reason }
        pump()
    }

    private func launchScp(_ item: TransferItem, options: SSHOptions, device: Bool, env: [String: String],
                           cleanUp: @escaping () -> Void, quitCleanUp: @escaping () -> Void, done: @escaping @MainActor () -> Void) {
        guard item.state == .running, !quitting else { done(); return }
        // A cleanup removes only what this transfer reserved (no other transfer can have chosen it).
        let mine = destinations(of: item)
        let owns: @MainActor () -> Bool = { [weak self] in
            guard let held = self?.reservations[item.id] else { return false }
            return mine.isSubset(of: held)
        }
        var executable = options.scpBinary
        var args: [String]
        if item.target.isLocal {
            // "Remote" is this Mac: a plain recursive copy.
            executable = "/bin/cp"
            args = ["-Rp", "--"] + (item.direction == .upload ? [item.localURL.path, item.remoteName == nil ? item.remotePath : item.uploadedPath]
                                                              : [item.remotePath, item.localURL.path])
        } else {
            let (destOpts, host) = SSHOptions.scpArguments(for: item.target, jump: !options.usesSharedConnection)
            // Devices often speak only the classic scp protocol, not SFTP (scp's default now).
            args = options.commonOptions() + destOpts + (device ? ["-O"] : []) + ["-r", "-p"]
            switch item.direction {
            case .upload:
                args += ["--", item.localURL.path, "\(host):\(item.remoteName == nil ? item.remotePath : item.uploadedPath)"]
            case .download:
                args += ["--", "\(host):\(item.remotePath)", item.localURL.path]
            }
        }
        // A local cp prints no progress, so nothing could tell a stall from a large file.
        let job = ScpJob(item: item, timeouts: timeouts, watch: !item.target.isLocal,
                         cleanUp: { if owns() { cleanUp() } }, quitCleanUp: { if owns() { quitCleanUp() } }) { _ in
            done()
        }
        jobs[item.id] = job
        launched[item.id] = Date()
        job.start(executable: executable, arguments: args, environment: env)
    }

    // MARK: Quitting and leftovers

    /// Stops every transfer as the app ends (called by itself when AppKit posts that it will
    /// terminate; calling it again does nothing): queued and preparing ones end, running ones'
    /// processes are asked to end and killed after `grace`, and what they left on this Mac —
    /// partial downloads under names they made, staging folders — is removed at once. A partial
    /// upload under a fresh name, or a staging folder on the server, is removed by a detached ssh
    /// (sharing the connection when there is one, never asking for a password).
    public func stopAllForQuit(grace: TimeInterval = 1) {
        guard !quitting else { return }
        quitting = true
        for p in preparations { cancel(p) }
        for task in preparingTasks.values { task.cancel() }
        preparingTasks.removeAll()
        for waiter in questionWaiters.values { waiter.resume(returning: nil) }
        questionWaiters.removeAll()
        for item in items where !item.isFinished && jobs[item.id] == nil {
            item.state = .cancelled
            item.finishedAt = Date()
        }
        let running = Array(jobs.values)
        // Nothing running: nothing to wait for (the run loop is not turned while the app ends).
        guard !running.isEmpty else {
            preparing.removeAll()
            starting.removeAll()
            reservations.removeAll()
            return
        }
        for job in running { job.signalForQuit(SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        // The main run loop keeps turning meanwhile: a transfer that had just ended (well or not) is
        // handled as usual, so a complete one is kept, not cleaned up.
        while Date() < deadline, !running.allSatisfy(\.hasExited) { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        let stubborn = running.filter { !$0.hasExited }
        for job in stubborn { job.signalForQuit(SIGKILL) }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(stubborn.isEmpty ? 0.15 : 0.2))
        for job in running { job.cleanUpForQuit() }
        jobs.removeAll()
        preparing.removeAll()
        starting.removeAll()
        reservations.removeAll()
    }

    /// Staging folders of packed downloads running now (never removed as leftovers).
    var activeStagingPaths: Set<String> {
        Set(jobs.values.compactMap { ($0 as? ArchiveJob)?.stagingURL?.standardizedFileURL.path })
    }

    /// Removes staging folders that packed downloads into `folder` left when Tether ended in the
    /// middle of them (a crash, a forced quit): see `LocalFiles.removeLeftoverStaging`. Off the main thread.
    public func removeLeftovers(in folder: URL) async {
        let active = activeStagingPaths
        _ = await Task.detached(priority: .utility) { LocalFiles.removeLeftoverStaging(in: folder, active: active) }.value
    }

    /// Runs a script on the server through a detached ssh that outlives the app (as it quits):
    /// never waited for, never asking anything (BatchMode).
    ///
    /// POSIX hosts only, on purpose: packed transfers never go to Windows, and a partial scp upload
    /// on a Windows host is left as it is when Tether quits (it is removed when the copy fails or is
    /// cancelled while Tether runs, through `RemoteFileSystem.delete`, which has a PowerShell variant).
    static func detachedRemoteScript(_ script: String, arguments: [String], target: ConnectionTarget, options: SSHOptions) {
        if !target.isLocal, PlatformCache.shared.cached(target.key)?.isWindows != false { return }
        let p = Process()
        if target.isLocal {
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script, "sh"] + arguments
        } else {
            let command = (["sh", "-c", script.shellQuoted, "sh"] + arguments.map(\.shellQuoted)).joined(separator: " ")
            p.executableURL = URL(fileURLWithPath: options.sshBinary)
            p.arguments = options.commonOptions() + ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
                + SSHOptions.destinationArguments(for: target, jump: !options.usesSharedConnection) + [command]
        }
        p.environment = ChildEnvironment.base
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

extension TransferManager {
    /// What a cancelled or failed copy leaves behind is removed — only a file or folder this copy
    /// created: a download into a name that did not exist when it started, an upload under a name
    /// (`remoteName`) that was still free when it started. Nothing that was there before is touched.
    func partialCleanup(for item: TransferItem) -> () -> Void {
        let fm = FileManager.default
        switch item.direction {
        case .download:
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: item.localURL.path, isDirectory: &isDir)
            // Into an existing folder: scp creates the file inside it.
            let made = exists && isDir.boolValue
                ? item.localURL.appendingPathComponent((item.remotePath as NSString).lastPathComponent)
                : item.localURL
            guard !LocalFiles.exists(made.path) else { return {} }
            return { LocalFiles.discard(made) }
        case .upload:
            guard item.remoteName != nil else { return {} }
            let path = item.uploadedPath
            guard item.target.isLocal, !LocalFiles.exists(path) else { return {} }   // servers: see `start`
            return { LocalFiles.discard(URL(fileURLWithPath: path)) }
        }
    }
}

/// One scp process running on a pseudo terminal so it prints its progress meter.
@MainActor
final class ScpJob: TransferJob {
    private let item: TransferItem
    private let timeouts: TransferTimeouts
    private let watch: Bool
    private let cleanUp: @MainActor () -> Void
    private let quitCleanUp: @MainActor () -> Void
    private var process: LocalProcess?
    private var bridge: ScpBridge?
    private var pid: pid_t = 0
    private var output = ""
    private var cancelled = false
    private var stalled = false
    /// The process ended (it is reaped: its pid must not be signalled any more).
    private var exited = false
    /// Seen ending with status 0 before its end was handled (while quitting).
    private var exitedCleanly = false
    private var finished = false
    private var lastProgress = ""
    private var watchdog: StallWatchdog?
    /// A copy on this Mac prints no progress: it never waits for a server.
    var hasMoved: Bool { watchdog?.isWarm ?? true }
    /// The copy finished completely (set when the process ends).
    private(set) var succeeded = false
    private let onFinish: (ScpJob) -> Void

    init(item: TransferItem, timeouts: TransferTimeouts = TransferTimeouts(), watch: Bool = true,
         cleanUp: @escaping @MainActor () -> Void = {}, quitCleanUp: @escaping @MainActor () -> Void = {},
         onFinish: @escaping (ScpJob) -> Void) {
        self.item = item
        self.timeouts = timeouts
        self.watch = watch
        self.cleanUp = cleanUp
        self.quitCleanUp = quitCleanUp
        self.onFinish = onFinish
    }

    func start(executable: String, arguments: [String], environment: [String: String]) {
        var env = ChildEnvironment.base
        env["TERM"] = "dumb"
        for (k, v) in environment { env[k] = v }
        let bridge = ScpBridge(job: self)
        self.bridge = bridge
        let p = LocalProcess(delegate: bridge, dispatchQueue: .main)
        process = p
        p.startProcess(executable: executable, args: arguments, environment: env.map { "\($0.key)=\($0.value)" })
        guard p.running, p.shellPid > 0 else {
            // No pseudo terminal or process could be made: nothing will ever report back.
            exited = true
            output = "Could not start \((executable as NSString).lastPathComponent)."
            terminated(nil)
            return
        }
        pid = p.shellPid
        AskPassBridge.shared.bindToken(environment, pid: pid)
        if watch {
            let watchdog = StallWatchdog(timeouts: timeouts) { [weak self] in self?.stall() }
            self.watchdog = watchdog
            watchdog.start()
        }
    }

    func cancel() {
        guard !finished else { return }
        cancelled = true
        stop()
    }

    private func stall() {
        guard !finished, !cancelled else { return }
        stalled = true
        stop()
    }

    /// Ends scp and its ssh (its process group: scp runs in a session of its own), killing them
    /// after the grace period. LocalProcess's own terminate() is not used: it stops watching the
    /// process, so its end would never be reported (and the transfer never finish).
    private func stop() {
        watchdog?.stop()
        signal(SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeouts.stopGrace) { [weak self] in
            MainActor.assumeIsolated { self?.signal(SIGKILL) }
        }
    }

    private func signal(_ sig: Int32) {
        guard pid > 0, !exited else { return }
        if kill(-pid, sig) != 0 { kill(pid, sig) }
    }

    // MARK: Quitting

    func signalForQuit(_ sig: Int32) {
        cancelled = true
        watchdog?.stop()
        signal(sig)
    }

    /// Looks without reaping (WNOWAIT): LocalProcess reaps the process and reports its status,
    /// which would read as success if the process had been reaped here first.
    var hasExited: Bool {
        guard !exited, pid > 0 else { return true }
        var info = siginfo_t()
        if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
            if info.si_pid == pid {
                exited = true
                exitedCleanly = info.si_code == CLD_EXITED && info.si_status == 0
            }
        } else if errno == ECHILD {
            exited = true      // reaped already: its end is on its way to `terminated`
        }
        return exited
    }

    func cleanUpForQuit() {
        guard !finished else { return }
        finished = true
        if exitedCleanly {
            // It had finished the copy just before: kept.
            item.progress = 1
            item.finishedAt = Date()
            item.state = .completed
            succeeded = true
            return
        }
        quitCleanUp()
        item.finishedAt = Date()
        item.state = .cancelled
    }

    // MARK: Output

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
            let moved = fields.count > pctIndex + 1 ? String(fields[pctIndex + 1]) : ""
            if fields.count > pctIndex + 1 { item.transferred = moved }
            if fields.count > pctIndex + 2 { item.speed = String(fields[pctIndex + 2]) }
            if fields.count > pctIndex + 3 { item.eta = String(fields[pctIndex + 3]) }
            // The meter is redrawn every second also when nothing moves ("- stalled -"): only a
            // change in what was copied counts.
            let progress = "\(file)|\(pct)|\(moved)"
            if progress != lastProgress {
                lastProgress = progress
                watchdog?.activity(warm: true)
            }
        }
    }

    fileprivate func terminated(_ status: Int32?) {
        exited = true
        process = nil
        guard !finished else { return }
        finished = true
        watchdog?.stop()
        item.finishedAt = Date()
        if status == 0 && !stalled, item.direction == .download, !LocalFiles.exists(item.localURL.path) {
            // scp said nothing went wrong, but nothing is there: never reported as done.
            item.state = .failed("The copy ended without an error, but nothing arrived at \(item.localURL.path).")
        } else if status == 0 && !stalled {
            // Complete, also when a cancel came too late: what arrived is kept.
            item.progress = 1
            item.state = .completed
            succeeded = true
        } else if cancelled {
            item.state = .cancelled
        } else if stalled {
            item.state = .failed(TransferFailure.stalled(host: item.target.displayName, after: timeouts.stall))
        } else {
            let lines = output.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.contains("%") }
            item.state = .failed(TransferFailure.message(lines.suffix(3).joined(separator: "\n"), host: item.target.displayName,
                                                         fallback: Self.describe(status)))
        }
        if !succeeded { cleanUp() }
        onFinish(self)
    }

    /// LocalProcess reports the raw wait status.
    static func describe(_ status: Int32?) -> String {
        guard let status else { return "The copy ended without saying why." }
        if status & 0x7f == 0 { return "scp exited with code \((status >> 8) & 0xff)" }
        return "scp was ended by signal \(status & 0x7f)"
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
