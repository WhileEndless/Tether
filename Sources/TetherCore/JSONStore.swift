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

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    public func save(_ value: Value) {
        guard let data = encode(value) else { return }
        DeferredWrites.shared.cancel(url)
        try? data.write(to: url, options: [.atomic])
    }

    /// For state that changes often (tabs, open sessions): encodes now, writes on a background
    /// queue shortly after, keeping only the newest version — no disk write on the main thread
    /// for every tab switch. `DeferredWrites.flush()` writes everything pending (at quit).
    public func saveSoon(_ value: Value) {
        guard let data = encode(value) else { return }
        DeferredWrites.shared.schedule(data, to: url)
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
    private var scheduled = false

    func schedule(_ data: Data, to url: URL) {
        lock.lock()
        pending[url] = data
        let start = !scheduled
        scheduled = true
        lock.unlock()
        if start { queue.asyncAfter(deadline: .now() + 0.4) { self.writePending() } }
    }

    func cancel(_ url: URL) {
        lock.lock(); pending[url] = nil; lock.unlock()
    }

    private func writePending() {
        lock.lock()
        let batch = pending
        pending = [:]
        scheduled = false
        lock.unlock()
        for (url, data) in batch { try? data.write(to: url, options: [.atomic]) }
    }

    /// Writes everything pending before returning (at quit).
    public func flush() {
        queue.sync { writePending() }
    }
}
