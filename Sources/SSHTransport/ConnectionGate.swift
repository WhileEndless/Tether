import Foundation

/// Lets one connection at a time be set up per host (and shared-connection slot). Opening many
/// tabs to the same host at once otherwise starts many ssh logins in parallel: sshd drops the
/// excess (`MaxStartups`), and several processes race to create the same shared connection.
/// Queued sessions continue as soon as the shared connection is up, so they still open quickly.
public actor ConnectionGate {
    public static let shared = ConnectionGate()

    /// The queue a host's sign-ins wait in: its server's (two names for one server — aliases, Quick
    /// Connect — sign in one after the other), or the host's own while ssh has not said where it leads.
    public nonisolated static func key(_ host: String) -> String {
        ResolvedNames.serverID(for: host).map { "server:" + $0 } ?? host
    }
    private var busy: Set<String> = []
    private var waiters: [String: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)]] = [:]
    /// Whether the user is being asked something for a host of this queue (see
    /// `AskPassBridge.waitsOnUser`): replaceable for tests, which must not use the real bridge.
    private let waitsOnUser: @Sendable (String) -> Bool
    /// How long, in all, a waiter keeps waiting for a question that is in front of the user.
    private let userWaitCap: TimeInterval
    private var waitingSince: [UUID: Date] = [:]

    public init(userWaitCap: TimeInterval = 900,
                waitsOnUser: @escaping @Sendable (String) -> Bool = { key in
                    AskPassBridge.shared.waitsOnUser(where: { ConnectionGate.key($0) == key })
                }) {
        self.userWaitCap = userWaitCap
        self.waitsOnUser = waitsOnUser
    }

    /// The one holding `key`'s turn waits for the user's answer to a question in front of them: a
    /// waiter that stops waiting must not start a login (and a second question) of its own.
    public func holderWaitsOnUser(_ key: String) -> Bool { busy.contains(key) && waitsOnUser(key) }

    /// Waits for the turn and returns true: the caller then holds it until `release`. Returns false
    /// without the turn when the task is cancelled (a tab closed while waiting), or when the one
    /// holding it has not let go after `timeout` seconds — a sign-in stuck somewhere must never
    /// hold up every other tab of the host for good; the caller goes ahead on its own then.
    @discardableResult
    public func acquire(_ key: String, timeout: TimeInterval = 180) async -> Bool {
        if busy.insert(key).inserted { return true }
        let id = UUID()
        waitingSince[id] = Date()
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled { await self?.giveUp(id, key, recheck: timeout) }
        }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiters[key, default: []].append((id, $0)) }
        } onCancel: {
            Task { await self.giveUp(id, key, cancelled: true) }
        }
    }

    private func giveUp(_ id: UUID, _ key: String, cancelled: Bool = false, recheck: TimeInterval = 60) {
        guard var queue = waiters[key], let i = queue.firstIndex(where: { $0.id == id }) else { waitingSince[id] = nil; return }
        // The one holding the turn waits for the user's answer to a question in front of them: not
        // stuck — the others keep waiting for it instead of each starting a login (and a question)
        // of its own; for at most `userWaitCap` in all. A question nobody can see does not count
        // (it ends by itself), and a waiter that was cancelled (its tab closed) goes at once.
        let waited = waitingSince[id].map { Date().timeIntervalSince($0) } ?? .infinity
        if !cancelled, waited < userWaitCap, waitsOnUser(key) {
            let again = min(60, max(0.05, recheck))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(again))
                await self?.giveUp(id, key, recheck: again)
            }
            return
        }
        let waiter = queue.remove(at: i)
        waiters[key] = queue.isEmpty ? nil : queue
        waitingSince[id] = nil
        waiter.continuation.resume(returning: false)
    }

    /// Waits until no login to `key` is in progress (without holding up anyone after it).
    /// Background work — monitoring, file listings, platform checks — uses this so it rides on the
    /// shared connection the login creates instead of starting logins of its own.
    public func waitForTurn(_ host: String) async {
        let key = Self.key(host)
        guard busy.contains(key) else { return }
        if await acquire(key) { release(key) }
    }

    public func release(_ key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue.isEmpty ? nil : queue
            waitingSince[next.id] = nil
            next.continuation.resume(returning: true)          // ownership passes straight to the next waiter
        } else {
            busy.remove(key)
        }
    }
}
