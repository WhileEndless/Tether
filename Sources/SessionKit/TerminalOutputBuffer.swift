import Foundation
import CryptoKit
import Darwin
import TetherCore

/// A lossless FIFO between PTY reads and the UI. All disk work runs on the producer/reader
/// queues, never on the main actor. Keys are per-buffer and never persisted, including for
/// private terminals. Unlike a recording, this buffer cannot be recovered after a crash.
final class TerminalOutputBuffer: @unchecked Sendable {
    struct Limits {
        var memory = 2 << 20
        var disk = 2 << 30
        var chunk = 64 << 10
    }

    final class Budget: @unchecked Sendable {
        static let shared = Budget(memory: 32 << 20, disk: 2 << 30)
        private let lock = NSLock()
        private let memoryLimit: Int
        private let diskLimit: Int
        private(set) var memory = 0
        private(set) var disk = 0

        init(memory: Int, disk: Int) { memoryLimit = memory; diskLimit = disk }

        func reserve(_ bytes: Int, disk: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if disk {
                guard bytes <= diskLimit - self.disk else { return false }
                self.disk += bytes
            } else {
                guard bytes <= memoryLimit - memory else { return false }
                memory += bytes
            }
            return true
        }

        func release(_ bytes: Int, disk: Bool) {
            lock.lock(); defer { lock.unlock() }
            if disk { self.disk -= bytes } else { memory -= bytes }
        }

        var usage: (memory: Int, disk: Int) {
            lock.lock(); defer { lock.unlock() }; return (memory, disk)
        }
    }

    private enum Entry {
        case memory(Data)
        case file(URL, bytes: Int, sequence: UInt64, plainCount: Int)
    }

    private let condition = NSCondition()
    private let key = SymmetricKey(size: .bits256)
    private let limits: Limits
    private let budget: Budget
    private let root: URL?
    private var directory: URL?
    private var entries: [Entry] = []
    private var head = 0
    private var sequence: UInt64 = 0
    private var memoryBytes = 0
    private var diskBytes = 0
    private var closed = false

    init(limits: Limits = Limits(), budget: Budget = .shared, root: URL? = nil) {
        self.limits = limits
        self.budget = budget
        self.root = root
    }

    deinit { close() }

    /// Runs on the PTY's serial delivery queue. A full or unavailable disk applies backpressure
    /// to this one PTY; neither the UI nor another session waits on this condition.
    @discardableResult
    func append(_ bytes: ArraySlice<UInt8>, available: () -> Void = {}) -> Bool {
        for start in stride(from: bytes.startIndex, to: bytes.endIndex, by: limits.chunk) {
            let data = Data(bytes[start..<min(start + limits.chunk, bytes.endIndex)])
            condition.lock()
            while !closed {
                if memoryBytes + data.count <= limits.memory, budget.reserve(data.count, disk: false) {
                    entries.append(.memory(data))
                    memoryBytes += data.count
                    break
                }
                // AES-GCM adds a 12-byte nonce and a 16-byte authentication tag.
                // Charge complete filesystem blocks, not just ciphertext length. A stream of
                // small reads must not evade the disk quota through per-file allocation costs.
                let size = ((data.count + 28 + 4095) / 4096) * 4096
                if diskBytes + size <= limits.disk, budget.reserve(size, disk: true) {
                    do {
                        if directory == nil {
                            let url = (root ?? Self.processRoot).appendingPathComponent(UUID().uuidString, isDirectory: true)
                            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                                   attributes: [.posixPermissions: 0o700])
                            directory = url
                        }
                        let url = directory!.appendingPathComponent(String(sequence))
                        let box = try AES.GCM.seal(data, using: key, authenticating: Self.tag(sequence))
                        try box.combined!.write(to: url, options: [.atomic])
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                        entries.append(.file(url, bytes: size, sequence: sequence, plainCount: data.count))
                        sequence += 1
                        diskBytes += size
                        break
                    } catch {
                        budget.release(size, disk: true)
                        // Keep the input in memory and retry; never acknowledge lost output.
                    }
                }
                condition.unlock()
                available()
                condition.lock()
                if !closed { _ = condition.wait(until: Date().addingTimeInterval(0.05)) }
            }
            let accepted = !closed
            condition.unlock()
            if !accepted { return false }
            available()
        }
        return true
    }

    /// Non-blocking when empty. Decryption and deletion are restricted to the reader queue.
    func take() throws -> Data? {
        condition.lock(); defer { condition.unlock() }
        guard !closed, head < entries.count else { return nil }
        var output = Data()
        while head < entries.count {
            let count: Int
            switch entries[head] {
            case .memory(let data): count = data.count
            case .file(_, _, _, let plainCount): count = plainCount
            }
            if !output.isEmpty, output.count + count > limits.chunk { break }
            do {
                let data: Data
                switch entries[head] {
                case .memory(let bytes):
                    data = bytes
                    memoryBytes -= bytes.count
                    budget.release(bytes.count, disk: false)
                case .file(let url, let bytes, let sequence, _):
                    let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
                    data = try AES.GCM.open(box, using: key, authenticating: Self.tag(sequence))
                    try FileManager.default.removeItem(at: url)
                    diskBytes -= bytes
                    budget.release(bytes, disk: true)
                }
                output.append(data)
                entries[head] = .memory(Data())
                head += 1
            } catch {
                // Deliver the valid prefix first. The unreadable entry stays at the head and
                // fails the next read, so an error never discards already-consumed bytes.
                if output.isEmpty { throw error }
                break
            }
        }
        if head == entries.count { entries.removeAll(keepingCapacity: true); head = 0 }
        else if head >= 64 { entries.removeFirst(head); head = 0 }
        condition.broadcast()
        return output
    }

    var hasOutput: Bool {
        condition.lock(); defer { condition.unlock() }; return !closed && head < entries.count
    }

    func close() {
        condition.lock(); defer { condition.unlock() }
        guard !closed else { return }
        closed = true
        budget.release(memoryBytes, disk: false)
        budget.release(diskBytes, disk: true)
        memoryBytes = 0; diskBytes = 0
        entries.removeAll(); head = 0
        if let directory {
            try? FileManager.default.removeItem(at: directory)
            // rmdir is atomic and refuses a nonempty directory: another session's files
            // must never be removed when the last file of this session is consumed.
            if root == nil { _ = rmdir(directory.deletingLastPathComponent().path) }
        }
        directory = nil
        condition.broadcast()
    }

    private static func tag(_ sequence: UInt64) -> Data {
        withUnsafeBytes(of: sequence.bigEndian) { Data($0) }
    }

    /// Only our process's children are used. Stale directories from dead processes are removed
    /// without touching a running second instance. Names and file contents contain no host data.
    private static let processRoot: URL = {
        let fm = FileManager.default
        if AppPaths.isRunningTests {
            return fm.temporaryDirectory.appendingPathComponent("tether-output-tests-\(getpid())-\(UUID().uuidString)", isDirectory: true)
        }
        let root = fm.temporaryDirectory.appendingPathComponent("tether-output-\(getuid())", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for child in children {
            guard let pid = Int32(child.lastPathComponent.split(separator: "-").first ?? ""), pid > 0 else { continue }
            if kill(pid, 0) == -1, errno == ESRCH { try? fm.removeItem(at: child) }
        }
        return root.appendingPathComponent("\(getpid())-\(UUID().uuidString)", isDirectory: true)
    }()
}
