import Foundation
import TetherCore
import SSHTransport

/// Sends many files as one tar stream: `tar -c` on one side is piped through ssh into `tar -x` on
/// the other. Nothing is written to a temporary archive, every file travels in a single stream (no
/// per-file round trips), and data is counted as it passes so progress, speed and ETA are exact.
///
/// Files are unpacked into a hidden staging folder next to the destination and then moved to their
/// final (conflict-free) names, so a cancelled or failed transfer never leaves half a tree behind
/// and never overwrites anything.
///
/// The stream is compressed as it flows (`TransferCompression`: zstd, lz4, gzip, xz or bzip2, the
/// fastest both ends have unless one is chosen): tar → count → compress → ssh going up, ssh →
/// uncompress → count → tar coming down, so progress counts the files' own bytes. ssh's own
/// compression would belong to the shared connection, not to one of its clients.
///
/// Stopping (cancel, a stalled stream, quitting) ends every process of the chain — asked first,
/// killed after a grace period — and removes the staging folder on both sides.
@MainActor
final class ArchiveJob: TransferJob {
    private let item: TransferItem
    private let options: SSHOptions
    private let compression: TransferCompression?
    private let environment: [String: String]
    private let timeouts: TransferTimeouts
    private let onFinish: @MainActor () -> Void
    private var producer: Process?
    private var consumer: Process?
    /// The chain's third process: ssh, when a compressor (going up) or uncompressor (coming down)
    /// sits between it and the count.
    private var extra: Process?
    /// The method used (shown with the transfer), once known.
    private(set) var method: TransferCompression?
    private let pump = StreamPump()
    private var cancelled = false
    /// Stopped by the watchdog: nothing moved for too long.
    private var stalled = false
    private var finished = false
    private(set) var stagingURL: URL?
    private var lastSample: (date: Date, bytes: Int64)?
    private var watchdog: StallWatchdog?
    /// Uploads: their names were just checked on the server, so it answers (going up, the first
    /// megabytes only fill pipes, see `update`). Downloads: the stream's first byte came.
    var hasMoved: Bool { item.direction == .upload || watchdog?.isWarm ?? true }
    /// Uploads: the folder holding the stream's last member (see `endName`).
    private var endMarkFolder: URL?
    private var errorCollector: ErrorCollector?
    /// Names (lowercased) other transfers will write into a local folder: never chosen here.
    var reservedElsewhere: @MainActor (URL) -> Set<String> = { _ in [] }

    init(item: TransferItem, options: SSHOptions, compression: TransferCompression?, environment: [String: String],
         timeouts: TransferTimeouts = TransferTimeouts(), onFinish: @escaping @MainActor () -> Void) {
        self.item = item
        self.options = options
        self.compression = compression
        self.environment = environment
        self.timeouts = timeouts
        self.onFinish = onFinish
    }

    /// Unique for the item (twelve hex digits of its id): removing it never touches anything else.
    var stagingName: String {
        LocalFiles.stagingPrefix + item.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    /// The last member of an upload's stream: the server moves nothing into place unless it
    /// arrived, so a stream cut off between two files (a cancel, a dropped connection) never
    /// leaves part of the transfer at the destination.
    var endName: String {
        ".tether-end-" + item.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    private var processes: [Process] { [producer, consumer, extra].compactMap { $0 } }

    /// Starts with the compression chosen beforehand (see `TransferManager`: what both ends
    /// have, and whether the compressing end is fast enough); nil: not compressed.
    func start() {
        start(with: compression)
    }

    /// Where programs are looked for on this Mac (Apple's, then Homebrew's and MacPorts').
    nonisolated static let localFolders = ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]

    nonisolated static func localPath(_ program: String) -> String? {
        localFolders.map { $0 + "/" + program }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func start(with method: TransferCompression?) {
        self.method = method
        item.compression = method
        item.stage = .streaming
        let producer: Process
        let consumer: Process
        let tool = method?.program
        switch item.direction {
        case .upload:
            let mark = FileManager.default.temporaryDirectory.appendingPathComponent("tether-end-\(item.id.uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: mark, withIntermediateDirectories: true)
                try Data().write(to: mark.appendingPathComponent(endName))
            } catch {
                fail(error.localizedDescription)
                return
            }
            endMarkFolder = mark
            producer = Self.localTarCreate(item.sources.map { URL(fileURLWithPath: $0) } + [mark.appendingPathComponent(endName)])
            let remote = remoteProcess(script: Self.unpackScript,
                                       arguments: [tool ?? "-", item.remotePath, stagingName, endName] + item.renames.flatMap { [$0.from, $0.to] })
            if let tool, let path = Self.localPath(tool) {
                // Counted here, compressed on the way to ssh.
                let coder = Self.process(path, ["-1", "-c"])
                let wire = Pipe()
                coder.standardOutput = wire
                remote.standardInput = wire
                extra = remote
                consumer = coder
            } else {
                consumer = remote
            }
        case .download:
            let staging = item.localURL.appendingPathComponent(stagingName, isDirectory: true)
            do {
                // The staging folder itself must be new (never one that exists, which would be
                // removed afterwards).
                try FileManager.default.createDirectory(at: item.localURL, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            } catch {
                fail(error.localizedDescription)
                return
            }
            stagingURL = staging
            let remote = remoteProcess(script: Self.packScript, arguments: [tool ?? "-", item.remotePath] + item.sources.map { "./" + $0 })
            if let tool, let path = Self.localPath(tool) {
                // Uncompressed as it arrives, then counted.
                let coder = Self.process(path, ["-d", "-c"])
                let wire = Pipe()
                remote.standardOutput = wire
                coder.standardInput = wire
                extra = remote
                producer = coder
            } else {
                producer = remote
            }
            consumer = Self.process("/usr/bin/tar", ["-x", "-f", "-", "-C", staging.path])
        }
        self.producer = producer
        self.consumer = consumer

        let extra = self.extra
        let all = [producer, consumer] + (extra.map { [$0] } ?? [])
        let group = DispatchGroup()
        for p in all {
            group.enter()
            p.terminationHandler = { _ in group.leave() }
        }
        let pipeOut = Pipe(), pipeIn = Pipe()
        producer.standardOutput = pipeOut
        consumer.standardInput = pipeIn
        // The server's script says where it is (unpacked, moving into place, removing its folder).
        let errors = ErrorCollector { [weak self] stage in
            Task { @MainActor in self?.serverSays(stage) }
        }
        errorCollector = errors
        for p in all { p.standardError = errors.attach() }
        if extra == nil || item.direction == .download { consumer.standardOutput = FileHandle.nullDevice }
        if extra == nil || item.direction == .upload { producer.standardInput = FileHandle.nullDevice }
        if let extra, item.direction == .upload { extra.standardOutput = FileHandle.nullDevice }
        if let extra, item.direction == .download { extra.standardInput = FileHandle.nullDevice }
        do {
            // From the far end back: each one's reader is there before its writer starts.
            for p in all.reversed() { try p.run() }
            for p in all { AskPassBridge.shared.bindToken(environment, pid: p.processIdentifier) }
        } catch {
            // Only a process that started can be stopped (stopping one that never ran ends the app).
            for p in all where p.isRunning { p.terminate() }
            cleanUpStaging()
            fail(error.localizedDescription)
            return
        }
        // The pipe ends this process does not use must be closed, or EOF never arrives.
        try? pipeOut.fileHandleForWriting.close()
        try? pipeIn.fileHandleForReading.close()
        for end in [extra?.standardInput, extra?.standardOutput] {
            if let wire = end as? Pipe {
                try? wire.fileHandleForReading.close()
                try? wire.fileHandleForWriting.close()
            }
        }

        // Nothing moving for too long (a connection gone silent, a server that stopped reading):
        // stopped with a clear message rather than waiting for ever.
        let watchdog = StallWatchdog(timeouts: timeouts) { [weak self] in self?.stall() }
        self.watchdog = watchdog
        watchdog.start()

        group.enter()
        let readFD = pipeOut.fileHandleForReading.fileDescriptor
        let writeFD = pipeIn.fileHandleForWriting.fileDescriptor
        pump.run(from: readFD, to: writeFD, progress: { [weak self] bytes in
            Task { @MainActor in self?.update(bytes) }
        }, done: { [weak self] in
            try? pipeOut.fileHandleForReading.close()
            try? pipeIn.fileHandleForWriting.close()
            // The far end now finishes (unpacks, moves into place): that counts as moving.
            Task { @MainActor in
                self?.watchdog?.activity(warm: true)
                if self?.item.stage == .streaming { self?.item.stage = .finishing }
            }
            group.leave()
        })
        // A short grace period lets the last stderr lines arrive.
        group.notify(queue: .main) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
              MainActor.assumeIsolated {
                // Every process of the chain must have done its part (ssh's status counts too).
                let far = extra.map { $0.terminationStatus } ?? 0
                self?.finish(producerStatus: producer.terminationStatus,
                             consumerStatus: consumer.terminationStatus == 0 ? far : consumer.terminationStatus,
                             errors: errors.text)
              }
            }
        }
    }

    func cancel() {
        guard !finished else { return }
        cancelled = true
        // Still asking the server which compressors it has: nothing runs yet, so it ends now (the
        // answer, when it comes, is not used).
        guard producer != nil else { endWithoutProcesses(); return }
        stop()
    }

    private func stall() {
        guard !finished, !cancelled else { return }
        stalled = true
        stop()
    }

    /// Asks every process to end, and kills what is still there after the grace period (an ssh
    /// waiting on a dead connection, a program ignoring SIGTERM): the job always ends.
    private func stop() {
        watchdog?.stop()
        pump.stop()
        for p in processes where p.isRunning { p.terminate() }
        let grace = timeouts.stopGrace
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                for p in self.processes where p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
    }

    // MARK: Quitting

    func signalForQuit(_ signal: Int32) {
        watchdog?.stop()
        pump.stop()
        for p in processes where p.isRunning { kill(p.processIdentifier, signal) }
    }

    var hasExited: Bool { processes.allSatisfy { !$0.isRunning } }

    func cleanUpForQuit() {
        guard !finished else { return }
        // Every process had already ended well (its end was not handled yet): a complete
        // transfer, kept — a download is moved into place now.
        if producer != nil, processes.allSatisfy({ !$0.isRunning && $0.terminationReason == .exit && $0.terminationStatus == 0 }) {
            finish(producerStatus: 0, consumerStatus: 0, errors: "")
            return
        }
        cancelled = true
        finished = true
        errorCollector?.close()
        cleanUpStaging()
        removeEndMark()
        // The server's unpacking script removes its staging folder when the stream ends; this is
        // in case it could not (a detached ssh, as Tether is ending).
        if item.direction == .upload, !item.target.isLocal {
            TransferManager.detachedRemoteScript(RemoteFileSystem.stagingCleanupScript, arguments: [item.remotePath, stagingName],
                                                 target: item.target, options: options)
        }
        item.finishedAt = Date()
        item.state = .cancelled
    }

    // MARK: Progress and the end

    private func update(_ bytes: Int64) {
        guard item.state == .running, !finished else { return }
        // Going up, the first megabytes fill pipes and buffers before ssh has even connected.
        watchdog?.activity(warm: bytes >= (item.direction == .upload ? 8 << 20 : 1))
        item.bytesDone = bytes
        if let total = item.totalBytes, total > 0 {
            item.progress = min(Double(bytes) / Double(total), 0.99)
        }
        item.transferred = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let now = Date()
        if let last = lastSample, now.timeIntervalSince(last.date) >= 0.5 {
            let rate = Double(bytes - last.bytes) / now.timeIntervalSince(last.date)
            if rate > 0 {
                item.speed = ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file) + "/s"
                if let total = item.totalBytes, total > bytes {
                    let secs = Int(Double(total - bytes) / rate)
                    item.eta = String(format: "%d:%02d", secs / 60, secs % 60)
                }
            }
            lastSample = (now, bytes)
        } else if lastSample == nil {
            lastSample = (now, bytes)
        }
    }

    private func finish(producerStatus: Int32, consumerStatus: Int32, errors: String) {
        guard !finished else { return }
        finished = true
        watchdog?.stop()
        item.finishedAt = Date()
        removeEndMark()
        // Every process ended well: the transfer is complete, also when a cancel came too late.
        if producerStatus == 0 && consumerStatus == 0 && !stalled {
            if item.direction == .download { item.stage = .movingIntoPlace }
            if item.direction == .download, let problem = moveDownloadsIntoPlace() {
                item.state = .failed(problem)
            } else {
                item.progress = 1
                item.filesDone = item.fileCount ?? item.entries.count
                item.state = .completed
            }
            cleanUpStaging()
        } else if cancelled {
            cleanUpStaging()
            // The server may have been moving items into place: those that got there are complete.
            if item.direction == .upload, item.stage == .movingIntoPlace {
                item.note = "Cancelled while moving into place on \(item.target.displayName): items already moved there are complete and stay."
            }
            item.state = .cancelled
        } else if stalled {
            cleanUpStaging()
            item.state = .failed(TransferFailure.stalled(host: item.target.displayName, after: timeouts.stall))
        } else {
            cleanUpStaging()
            // Asked again next time: a program that failed here may not really work there.
            if method != nil { HostProbe.forget(item.target) }
            item.state = .failed(TransferFailure.message(errors, host: item.target.displayName,
                                                         fallback: "Transfer failed (exit codes \(producerStatus)/\(consumerStatus))"))
        }
        if item.state != .completed { removeRemoteStaging() }
        errorCollector?.close()
        onFinish()
    }

    /// Going up, a stopped or failed stream may leave the server's staging folder behind (its
    /// script removes it when it sees the stream end — not if it never sees that).
    private func removeRemoteStaging() {
        guard item.direction == .upload else { return }
        let fs = RemoteFileSystem(executor: RemoteExecutor(target: item.target, options: options))
        let name = stagingName, dir = item.remotePath
        Task { await fs.removeStaging(name, in: dir) }
    }

    /// A stage the server's unpacking script reported ("@@stage moving" on its error output).
    private func serverSays(_ stage: String) {
        guard !finished, item.state == .running else { return }
        switch stage {
        case "moving": item.stage = .movingIntoPlace
        case "cleaning": item.stage = .removingTemporary
        default: break
        }
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        finished = true
        removeEndMark()
        item.finishedAt = Date()
        item.state = .failed(message)
        onFinish()
    }

    /// Ends a job cancelled before any process started.
    private func endWithoutProcesses() {
        guard !finished else { return }
        finished = true
        item.finishedAt = Date()
        item.state = .cancelled
        onFinish()
    }

    /// An item could not be moved into place: what arrived is kept in a visible folder (named in
    /// the error) instead of being thrown away.
    private var keepStaging = false

    /// Moves unpacked downloads to their final names. Never replaces an existing file.
    private func moveDownloadsIntoPlace() -> String? {
        guard let staging = stagingURL else { return nil }
        let fm = FileManager.default
        var problems: [String] = []
        for (i, pair) in item.renames.enumerated() {
            let from = staging.appendingPathComponent(pair.from)
            // Taken meanwhile (the free name was chosen before the transfer started): the next free
            // name, never a replacement — and never throwing away what was downloaded.
            var moved: URL?
            var lastError: Error?
            for _ in 0..<5 where moved == nil {
                let to = item.localURL.appendingPathComponent(
                    LocalFiles.uniqueNames(in: item.localURL, for: [pair.to], alsoTaken: reservedElsewhere(item.localURL))[0])
                do { try fm.moveItem(at: from, to: to); moved = to } catch { lastError = error }
            }
            if let moved {
                // What "Show in Finder" and the Transfers list point at.
                if i < item.entries.count, item.entries[i].to != moved.path {
                    item.entries[i].to = moved.path
                    item.entries[i].renamed = true
                }
            } else {
                problems.append(lastError?.localizedDescription ?? "\(pair.to) could not be moved into place")
                keepStaging = true
            }
        }
        guard !problems.isEmpty else { return nil }
        var message = problems.prefix(3).joined(separator: "\n")
        if keepStaging {
            // Out of the hidden staging folder (which a later cleanup would remove) into a visible one.
            let kept = item.localURL.appendingPathComponent(LocalFiles.uniqueNames(in: item.localURL, for: ["Incomplete download"])[0])
            let place = (try? fm.moveItem(at: staging, to: kept)) != nil ? kept : staging
            message += "\nWhat arrived is kept in \(place.path)"
        }
        return message
    }

    /// Off the main thread for a large tree (`LocalFiles.discard`).
    private func cleanUpStaging() {
        guard !keepStaging, let stagingURL else { return }
        LocalFiles.discard(stagingURL)
    }

    private func removeEndMark() {
        if let endMarkFolder { try? FileManager.default.removeItem(at: endMarkFolder) }
        endMarkFolder = nil
    }

    // MARK: Processes

    private func remoteProcess(script: String, arguments: [String]) -> Process {
        if item.target.isLocal {
            let p = Self.process("/bin/sh", ["-c", script, "sh"] + arguments)
            p.environment = ChildEnvironment.local
            return p
        }
        let command = (["sh", "-c", script.shellQuoted, "sh"] + arguments.map(\.shellQuoted)).joined(separator: " ")
        let args = options.commonOptions() + ["-T"]
            + SSHOptions.destinationArguments(for: item.target, jump: !options.usesSharedConnection) + [command]
        let p = Self.process(options.sshBinary, args)
        var env = ChildEnvironment.base
        for (k, v) in environment { env[k] = v }
        p.environment = env
        return p
    }

    /// `tar -c` of local files, each relative to its own folder. GNU format: long names and large
    /// files work everywhere, and no macOS-only metadata (resource forks, xattrs) is included.
    static func localTarCreate(_ files: [URL]) -> Process {
        // -H: an item that is itself a symbolic link (a linked folder) sends what it points to; a
        // link to a path on this Mac would mean nothing on the server.
        var args = ["-c", "-f", "-", "-H", "--format", "gnutar", "--no-mac-metadata", "--no-xattrs", "--no-acls", "--no-fflags"]
        for f in files {
            args += ["-C", f.deletingLastPathComponent().path, "./" + f.lastPathComponent]
        }
        let p = process("/usr/bin/tar", args)
        var env = ChildEnvironment.base
        env["COPYFILE_DISABLE"] = "1"
        p.environment = env
        return p
    }

    static func process(_ executable: String, _ arguments: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        return p
    }

    /// Unpacks stdin into a staging folder inside the destination, then moves each item to its
    /// final name (pairs of `from to` arguments). The staging folder is always removed, also when
    /// the stream ends early (the connection dropped, the transfer was cancelled).
    /// `$1`: the program the stream is compressed with (zstd, lz4, gzip, xz, bzip2) or `-`; its
    /// exit status counts too (a stream cut off between two files must not pass as complete).
    static let unpackScript = #"""
    z=$1; d=$2; t="$2/$3"; e=$4; shift 4
    case $z in zstd|lz4|gzip|xz|bzip2|-) ;; *) echo "Unknown compression: $z" >&2; exit 2 ;; esac
    case $e in .tether-end-*) ;; *) echo "Missing end mark" >&2; exit 2 ;; esac
    # A destination folder made here is removed again when nothing reached it (rmdir: only empty).
    made=; [ -d "$d" ] || made=1
    mkdir -p -- "$d" || exit 1
    mkdir -- "$t" || { [ -n "$made" ] && rmdir -- "$d" 2>/dev/null; exit 1; }
    trap 'rm -rf -- "$t"; [ -n "$made" ] && rmdir -- "$d" 2>/dev/null' EXIT
    trap 'exit 1' HUP INT TERM PIPE
    if [ "$z" = - ]; then tar -xf - -C "$t" || exit 1
    else
      exec 4>&1
      s=$( { { "$z" -d -c; echo $? >&3; } | tar -xf - -C "$t" >&4; } 3>&1 ) || exit 1
      [ "${s:-1}" = 0 ] || { echo "The compressed stream ended early ($z exit status ${s:-unknown})" >&2; exit 1; }
    fi
    [ -f "$t/$e" ] || { echo "The stream ended early, so nothing was moved into place" >&2; exit 1; }
    rm -f -- "$t/$e"
    echo "@@stage moving" >&2
    # Takes the final name only while it is free, never replacing anything: a folder by making it
    # (mkdir fails when the name exists) and moving its contents in, with its permissions; a file
    # by a hard link (which fails when the name exists); anything else after a check.
    place() {
      if [ -e "$2" ] || [ -L "$2" ]; then return 3; fi
      if [ -d "$1" ] && [ ! -L "$1" ]; then
        mkdir -- "$2" 2>/dev/null || return 3
        m=$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null)
        case "$2" in -*) ;; *) [ -n "$m" ] && chmod "$m" "$2" 2>/dev/null ;; esac
        for f in "$1"/* "$1"/.[!.]* "$1"/..?*; do
          [ -e "$f" ] || [ -L "$f" ] || continue
          mv -- "$f" "$2/" || return 1
        done
        return 0
      fi
      if [ -f "$1" ] && [ ! -L "$1" ] && ln -- "$1" "$2" 2>/dev/null; then rm -f -- "$1"; return 0; fi
      if [ -e "$2" ] || [ -L "$2" ]; then return 3; fi
      mv -- "$1" "$2"
    }
    # Each stage line doubles as a check that Tether is still there: once the connection is gone,
    # writing it fails (SIGPIPE), and the script stops and removes what it made.
    s=0
    while [ $# -ge 2 ]; do
      echo "@@stage moving" >&2
      place "$t/$1" "$d/$2"; r=$?
      if [ $r = 3 ]; then echo "$2 already exists in $d" >&2; s=1; elif [ $r != 0 ]; then s=1; fi
      shift 2
    done
    echo "@@stage cleaning" >&2
    exit $s
    """#

    /// Packs the named items of a directory to stdout, compressed with `$1` (or not: `-`). tar's
    /// own exit status is kept through the pipe.
    static let packScript = #"""
    z=$1
    case $z in zstd|lz4|gzip|xz|bzip2|-) ;; *) echo "Unknown compression: $z" >&2; exit 2 ;; esac
    cd -- "$2" || exit 1
    shift 2
    [ "$z" = - ] && exec tar -cf - "$@"
    exec 4>&1
    s=$( { { tar -cf - "$@"; echo $? >&3; } | "$z" -1 -c >&4; } 3>&1 )
    exit "${s:-1}"
    """#

    nonisolated static func clean(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") && !$0.contains("Ignoring unknown extended header")
                && !$0.hasPrefix("@@stage ") }
        return lines.suffix(3).joined(separator: "\n")
    }
}

/// Copies bytes between two file descriptors on a background thread and reports the running total.
/// It waits with `poll` in short steps, so `stop()` ends it within a quarter of a second even when
/// neither end moves (a reader that stopped reading, a writer that went silent).
final class StreamPump: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func run(from readFD: Int32, to writeFD: Int32, progress: @escaping @Sendable (Int64) -> Void,
             done: @escaping @Sendable () -> Void) {
        // A reader that went away must not kill the app with SIGPIPE.
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        // Only this process holds these ends (the children have the others).
        for fd in [readFD, writeFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        let thread = Thread { [self] in
            let size = 256 * 1024
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
            defer { buffer.deallocate() }
            var total: Int64 = 0
            var lastReport = Date.distantPast
            loop: while !isStopped {
                guard Self.wait(readFD, for: Int16(POLLIN)) else { continue }
                let n = read(readFD, buffer, size)
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                if n <= 0 { break }
                var offset = 0
                while offset < n {
                    if isStopped { break loop }
                    guard Self.wait(writeFD, for: Int16(POLLOUT)) else { continue }
                    let w = write(writeFD, buffer + offset, n - offset)
                    if w < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    if w <= 0 { break loop }
                    offset += w
                }
                total += Int64(n)
                let now = Date()
                if now.timeIntervalSince(lastReport) > 0.2 {
                    lastReport = now
                    progress(total)
                }
            }
            progress(total)
            done()
        }
        thread.name = "Tether transfer"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Whether the descriptor is ready (or closed or in error: the next call says which), waiting
    /// at most a quarter of a second.
    private static func wait(_ fd: Int32, for events: Int16) -> Bool {
        var p = pollfd(fd: fd, events: events, revents: 0)
        let r = poll(&p, 1, 250)
        return r > 0 || (r < 0 && errno != EINTR)
    }
}

/// Collects stderr of several processes (bounded), passing on the stage lines the server's
/// script writes there ("@@stage <name>").
final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let onStage: (@Sendable (String) -> Void)?

    init(onStage: (@Sendable (String) -> Void)? = nil) {
        self.onStage = onStage
    }

    private var pipes: [Pipe] = []

    /// Stops reading: the far end's next line then fails, as when ssh's channel closes.
    func close() {
        lock.lock()
        let all = pipes
        pipes.removeAll()
        lock.unlock()
        for pipe in all {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
        }
    }

    func attach() -> Pipe {
        let pipe = Pipe()
        lock.lock(); pipes.append(pipe); lock.unlock()
        final class Pending: @unchecked Sendable { var line = Data() }
        let pending = Pending()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.lock.lock()
            self.data.append(chunk)
            if self.data.count > 16_384 { self.data = self.data.suffix(8_192) }
            self.lock.unlock()
            guard let onStage = self.onStage else { return }
            // Only this pipe's handler touches its partial line.
            pending.line.append(chunk)
            while let nl = pending.line.firstIndex(of: 0x0a) {
                let line = String(decoding: pending.line[pending.line.startIndex..<nl], as: UTF8.self)
                pending.line.removeSubrange(pending.line.startIndex...nl)
                if line.hasPrefix("@@stage ") { onStage(String(line.dropFirst(8))) }
            }
            if pending.line.count > 4096 { pending.line.removeAll() }
        }
        return pipe
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Fails a transfer that moved nothing for too long, instead of letting it wait for ever. Before
/// any real data moved, the longer `firstData` limit applies (the connection may still be signing
/// in, waiting for a password); after that, `stall`.
@MainActor
final class StallWatchdog {
    private let timeouts: TransferTimeouts
    private let onStall: @MainActor () -> Void
    private var last = Date()
    private(set) var isWarm = false
    private var task: Task<Void, Never>?

    init(timeouts: TransferTimeouts, onStall: @escaping @MainActor () -> Void) {
        self.timeouts = timeouts
        self.onStall = onStall
    }

    func start() {
        last = Date()
        let step = max(min(timeouts.stall / 4, 1), 0.05)
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(step))
                guard let self, !Task.isCancelled else { return }
                let limit = self.isWarm ? self.timeouts.stall : max(self.timeouts.firstData, self.timeouts.stall)
                if Date().timeIntervalSince(self.last) > limit {
                    self.stop()
                    self.onStall()
                    return
                }
            }
        }
    }

    /// Something moved; `warm`: real data (from now on the shorter limit applies).
    func activity(warm: Bool) {
        last = Date()
        if warm { isWarm = true }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Readable reasons for a failed transfer.
enum TransferFailure {
    /// What ssh and scp say when the connection went away under them.
    static let lostConnectionMarkers = [
        "broken pipe", "connection reset", "connection closed", "closed by remote host", "client_loop",
        "lost connection", "connection timed out", "timeout, server", "read from master failed", "mux_client",
        "network is unreachable", "no route to host", "connection refused", "control socket connect",
    ]

    static func isLostConnection(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lostConnectionMarkers.contains { lower.contains($0) }
            || lower.contains("connection to") && lower.contains("closed")
    }

    static func message(_ errors: String, host: String, fallback: String) -> String {
        let cleaned = ArchiveJob.clean(errors)
        if isLostConnection(errors) {
            let reason = cleaned.split(separator: "\n").last.map { "\n" + $0 } ?? ""
            return "The connection to \(host) was lost, so the transfer stopped. Retry sends it again from the start.\(reason)"
        }
        return cleaned.isEmpty ? fallback : cleaned
    }

    static func stalled(host: String, after seconds: TimeInterval) -> String {
        let span = seconds >= 120 ? "\(Int(seconds / 60)) minutes" : seconds >= 60 ? "a minute" : "\(Int(seconds.rounded())) seconds"
        return "Nothing moved for \(span): the connection to \(host) seems to have stalled, so the transfer was stopped. Retry sends it again from the start."
    }
}
