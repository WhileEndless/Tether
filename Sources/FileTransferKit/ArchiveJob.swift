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
@MainActor
final class ArchiveJob: TransferJob {
    private let item: TransferItem
    private let options: SSHOptions
    private let compress: Bool
    private let environment: [String: String]
    private let onFinish: @MainActor () -> Void
    private var producer: Process?
    private var consumer: Process?
    private let pump = StreamPump()
    private var cancelled = false
    private var stagingURL: URL?
    private var lastSample: (date: Date, bytes: Int64)?

    init(item: TransferItem, options: SSHOptions, compress: Bool, environment: [String: String],
         onFinish: @escaping @MainActor () -> Void) {
        self.item = item
        self.options = options
        self.compress = compress
        self.environment = environment
        self.onFinish = onFinish
    }

    private var stagingName: String { ".tether-transfer-" + item.id.uuidString.prefix(8).lowercased() }

    func start() {
        let producer: Process
        let consumer: Process
        switch item.direction {
        case .upload:
            producer = Self.localTarCreate(item.sources.map { URL(fileURLWithPath: $0) })
            consumer = remoteProcess(script: Self.unpackScript,
                                     arguments: [item.remotePath, stagingName] + item.renames.flatMap { [$0.from, $0.to] })
        case .download:
            let staging = item.localURL.appendingPathComponent(stagingName, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            } catch {
                fail(error.localizedDescription)
                return
            }
            stagingURL = staging
            producer = remoteProcess(script: Self.packScript, arguments: [item.remotePath] + item.sources.map { "./" + $0 })
            consumer = Self.process("/usr/bin/tar", ["-x", "-f", "-", "-C", staging.path])
        }
        self.producer = producer
        self.consumer = consumer

        let group = DispatchGroup()
        for p in [producer, consumer] {
            group.enter()
            p.terminationHandler = { _ in group.leave() }
        }
        let pipeOut = Pipe(), pipeIn = Pipe()
        producer.standardOutput = pipeOut
        consumer.standardInput = pipeIn
        let errors = ErrorCollector()
        producer.standardError = errors.attach()
        consumer.standardError = errors.attach()
        consumer.standardOutput = FileHandle.nullDevice
        producer.standardInput = FileHandle.nullDevice
        do {
            try consumer.run()
            try producer.run()
            AskPassBridge.shared.bindToken(environment, pid: consumer.processIdentifier)
            AskPassBridge.shared.bindToken(environment, pid: producer.processIdentifier)
        } catch {
            producer.terminate()
            consumer.terminate()
            fail(error.localizedDescription)
            return
        }
        // The pipe ends this process does not use must be closed, or EOF never arrives.
        try? pipeOut.fileHandleForWriting.close()
        try? pipeIn.fileHandleForReading.close()

        group.enter()
        let readFD = pipeOut.fileHandleForReading.fileDescriptor
        let writeFD = pipeIn.fileHandleForWriting.fileDescriptor
        pump.run(from: readFD, to: writeFD, progress: { [weak self] bytes in
            Task { @MainActor in self?.update(bytes) }
        }, done: {
            try? pipeOut.fileHandleForReading.close()
            try? pipeIn.fileHandleForWriting.close()
            group.leave()
        })
        // A short grace period lets the last stderr lines arrive.
        group.notify(queue: .main) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
              MainActor.assumeIsolated {
                self?.finish(producerStatus: producer.terminationStatus, consumerStatus: consumer.terminationStatus,
                             errors: errors.text)
              }
            }
        }
    }

    func cancel() {
        cancelled = true
        pump.stop()
        producer?.terminate()
        consumer?.terminate()
    }

    private func update(_ bytes: Int64) {
        guard item.state == .running else { return }
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
        item.finishedAt = Date()
        if cancelled {
            cleanUpStaging()
            item.state = .cancelled
        } else if producerStatus == 0 && consumerStatus == 0 {
            if item.direction == .download, let problem = moveDownloadsIntoPlace() {
                item.state = .failed(problem)
            } else {
                item.progress = 1
                item.filesDone = item.fileCount ?? item.entries.count
                item.state = .completed
            }
            cleanUpStaging()
        } else {
            cleanUpStaging()
            let message = Self.clean(errors)
            item.state = .failed(message.isEmpty ? "Transfer failed (exit codes \(producerStatus)/\(consumerStatus))" : message)
        }
        onFinish()
    }

    private func fail(_ message: String) {
        item.finishedAt = Date()
        item.state = .failed(message)
        onFinish()
    }

    /// An item could not be moved into place: what arrived stays in the staging folder (named in
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
                let to = item.localURL.appendingPathComponent(LocalFiles.uniqueNames(in: item.localURL, for: [pair.to])[0])
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
        if keepStaging, let staging = stagingURL { message += "\nWhat arrived is kept in \(staging.path)" }
        return message
    }

    private func cleanUpStaging() {
        guard !keepStaging else { return }
        if let stagingURL { try? FileManager.default.removeItem(at: stagingURL) }
    }

    // MARK: Processes

    private func remoteProcess(script: String, arguments: [String]) -> Process {
        if item.target.isLocal {
            return Self.process("/bin/sh", ["-c", script, "sh"] + arguments)
        }
        let command = (["sh", "-c", script.shellQuoted, "sh"] + arguments.map(\.shellQuoted)).joined(separator: " ")
        let args = options.commonOptions() + ["-T"] + (compress ? ["-C"] : [])
            + SSHOptions.destinationArguments(for: item.target) + [command]
        let p = Self.process(options.sshBinary, args)
        var env = ProcessInfo.processInfo.environment
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
        var env = ProcessInfo.processInfo.environment
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
    /// final name (pairs of `from to` arguments). The staging folder is always removed.
    static let unpackScript = #"""
    d=$1; t="$1/$2"; shift 2
    mkdir -p -- "$d" || exit 1
    mkdir -- "$t" || exit 1
    trap 'rm -rf -- "$t"' EXIT
    trap 'exit 1' HUP INT TERM PIPE
    tar -xf - -C "$t" || exit 1
    s=0
    while [ $# -ge 2 ]; do
      if [ -e "$d/$2" ] || [ -L "$d/$2" ]; then
        echo "$2 already exists in $d" >&2; s=1
      else
        mv -- "$t/$1" "$d/$2" || s=1
      fi
      shift 2
    done
    exit $s
    """#

    /// Packs the named items of a directory to stdout.
    static let packScript = #"""
    cd -- "$1" || exit 1
    shift
    exec tar -cf - "$@"
    """#

    static func clean(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") && !$0.contains("Ignoring unknown extended header") }
        return lines.suffix(3).joined(separator: "\n")
    }
}

/// Copies bytes between two file descriptors on a background thread and reports the running total.
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
        let thread = Thread { [self] in
            let size = 256 * 1024
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
            defer { buffer.deallocate() }
            var total: Int64 = 0
            var lastReport = Date.distantPast
            loop: while !isStopped {
                let n = read(readFD, buffer, size)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                var offset = 0
                while offset < n {
                    let w = write(writeFD, buffer + offset, n - offset)
                    if w < 0 && errno == EINTR { continue }
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
}

/// Collects stderr of several processes (bounded).
final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func attach() -> Pipe {
        let pipe = Pipe()
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
        }
        return pipe
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
