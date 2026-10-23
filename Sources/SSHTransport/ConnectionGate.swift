import Foundation

/// Lets one connection at a time be set up per host (and shared-connection slot). Opening many
/// tabs to the same host at once otherwise starts many ssh logins in parallel: sshd drops the
/// excess (`MaxStartups`), and several processes race to create the same shared connection.
/// Queued sessions continue as soon as the shared connection is up, so they still open quickly.
public actor ConnectionGate {
    public static let shared = ConnectionGate()
    private var busy: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public func acquire(_ key: String) async {
        if busy.insert(key).inserted { return }
        await withCheckedContinuation { waiters[key, default: []].append($0) }
    }

    /// Waits until no login to `key` is in progress (without holding up anyone after it).
    /// Background work — monitoring, file listings, platform checks — uses this so it rides on the
    /// shared connection the login creates instead of starting logins of its own.
    public func waitForTurn(_ key: String) async {
        guard busy.contains(key) else { return }
        await acquire(key)
        release(key)
    }

    public func release(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue.isEmpty ? nil : queue
            next.resume()          // ownership passes straight to the next waiter
        } else {
            busy.remove(key)
        }
    }
}
