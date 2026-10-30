import Foundation

/// Lets one connection at a time be set up per host (and shared-connection slot). Opening many
/// tabs to the same host at once otherwise starts many ssh logins in parallel: sshd drops the
/// excess (`MaxStartups`), and several processes race to create the same shared connection.
/// Queued sessions continue as soon as the shared connection is up, so they still open quickly.
public actor ConnectionGate {
    public static let shared = ConnectionGate()
    private var busy: Set<String> = []
    private var waiters: [String: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)]] = [:]

    /// Waits for the turn and returns true: the caller then holds it until `release`. Returns false
    /// without the turn when the task is cancelled (a tab closed while waiting), or when the one
    /// holding it has not let go after `timeout` seconds — a sign-in stuck somewhere must never
    /// hold up every other tab of the host for good; the caller goes ahead on its own then.
    @discardableResult
    public func acquire(_ key: String, timeout: TimeInterval = 180) async -> Bool {
        if busy.insert(key).inserted { return true }
        let id = UUID()
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled { await self?.giveUp(id, key) }
        }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiters[key, default: []].append((id, $0)) }
        } onCancel: {
            Task { await self.giveUp(id, key) }
        }
    }

    private func giveUp(_ id: UUID, _ key: String) {
        guard var queue = waiters[key], let i = queue.firstIndex(where: { $0.id == id }) else { return }
        let waiter = queue.remove(at: i)
        waiters[key] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(returning: false)
    }

    /// Waits until no login to `key` is in progress (without holding up anyone after it).
    /// Background work — monitoring, file listings, platform checks — uses this so it rides on the
    /// shared connection the login creates instead of starting logins of its own.
    public func waitForTurn(_ key: String) async {
        guard busy.contains(key) else { return }
        if await acquire(key) { release(key) }
    }

    public func release(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue.isEmpty ? nil : queue
            next.continuation.resume(returning: true)          // ownership passes straight to the next waiter
        } else {
            busy.remove(key)
        }
    }
}
