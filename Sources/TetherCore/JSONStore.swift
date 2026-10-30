import Foundation

/// Minimal JSON file persistence for Codable values in Application Support.
public struct JSONStore<Value: Codable> {
    public let url: URL

    public init(filename: String) {
        url = AppPaths.supportDirectory.appendingPathComponent(filename)
    }

    public init(url: URL) {
        self.url = url
    }

    /// The stored value. A file that is there but cannot be read as one (damaged, or written by an
    /// incompatible version) is moved aside first — `name.unreadable-<date>.json` next to it — so the
    /// next save never overwrites what it held.
    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            moveAside()
            return nil
        }
    }

    private func moveAside() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = url.deletingPathExtension().lastPathComponent + ".unreadable-" + f.string(from: Date())
        var aside = url.deletingLastPathComponent().appendingPathComponent(base + ".json")
        var n = 1
        while FileManager.default.fileExists(atPath: aside.path) {
            aside = url.deletingLastPathComponent().appendingPathComponent("\(base)-\(n).json")
            n += 1
        }
        try? FileManager.default.moveItem(at: url, to: aside)
    }

    public func save(_ value: Value) {
        guard let data = encode(value) else { return }
        DeferredWrites.shared.cancel(url)
        try? data.write(to: url, options: [.atomic])
    }

    /// For state that changes often (tabs, open sessions): encodes now, writes on a background
    /// queue shortly after, keeping only the newest version — no disk write on the main thread
    /// for every tab switch. `DeferredWrites.flush()` writes everything pending (at quit).
    /// `within`: how long it may wait (state that is cheap to lose, such as which tab was in front:
    /// the sessions themselves are on the servers, kept by tmux or screen).
    public func saveSoon(_ value: Value, within delay: TimeInterval = DeferredWrites.defaultDelay) {
        guard let data = encode(value) else { return }
        DeferredWrites.shared.schedule(data, to: url, within: delay)
    }

    private func encode(_ value: Value) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(value)
    }
}

/// Coalesced background file writes (see `JSONStore.saveSoon`).
public final class DeferredWrites: @unchecked Sendable {
    public static let shared = DeferredWrites()
    private let queue = DispatchQueue(label: "tether.deferred-writes", qos: .utility)
    private let lock = NSLock()
    private var pending: [URL: Data] = [:]
    /// When the pending writes are due (the soonest asked for), and which scheduling is current.
    private var due: DispatchTime?
    private var generation = 0
    public static let defaultDelay: TimeInterval = 1.5
    /// For state that is cheap to lose (tabs, windows): written at most this often while it changes.
    public static let relaxedDelay: TimeInterval = 10

    func schedule(_ data: Data, to url: URL, within delay: TimeInterval = defaultDelay, replacing: Bool = true) {
        let when = DispatchTime.now() + delay
        lock.lock()
        if replacing || pending[url] == nil { pending[url] = data }
        // Writes asked for meanwhile are gathered: switching tabs quickly writes once.
        let reschedule = due.map { when < $0 } ?? true
        if reschedule { due = when; generation += 1 }
        let mine = generation
        lock.unlock()
        if reschedule {
            queue.asyncAfter(deadline: when) {
                guard self.lock.withLock({ self.generation == mine }) else { return }
                self.writePending()
            }
        }
    }

    func cancel(_ url: URL) {
        lock.lock(); pending[url] = nil; lock.unlock()
        queue.async { self.written[url] = nil }     // written directly (`save`): compare afresh
    }

    private func writePending() {
        lock.lock()
        let batch = pending
        pending = [:]
        due = nil
        lock.unlock()
        var failed: [URL: Data] = [:]
        for (url, data) in batch where written[url] != data {
            if (try? data.write(to: url, options: [.atomic])) != nil { written[url] = data } else { failed[url] = data }
        }
        // Not written (a full disk, a folder gone): kept, and tried again later and at quit —
        // unless a newer state came meanwhile.
        guard !failed.isEmpty else { return }
        lock.lock()
        for (url, data) in failed where pending[url] == nil { pending[url] = data }
        lock.unlock()
        for (url, data) in failed { schedule(data, to: url, within: Self.retryDelay, replacing: false) }
    }

    /// How long a write that failed waits before it is tried again.
    static let retryDelay: TimeInterval = 30

    /// What was last written to each file (on `queue` only): an unchanged state is not written again.
    private var written: [URL: Data] = [:]

    /// Writes everything pending before returning (at quit).
    public func flush() {
        queue.sync { writePending() }
    }
}
