import Foundation

/// The one place that says when servers can be reached again — a server signed in, the network
/// came back, Tether was unlocked — so every feature that waits (file views whose listing failed,
/// transfers stopped by a lost connection, monitors, port forwards to restore) reacts to the same
/// moment instead of each guessing with timers of its own.
@MainActor
public final class HostLinks {
    public static let shared = HostLinks()

    public enum Event: Sendable, Equatable {
        /// A sign-in to this host (target key) worked: its connection is up.
        case signedIn(String)
        /// The Mac woke, or the network came back or changed.
        case networkBack
        /// Tether was unlocked: what waited for that may start.
        case unlocked
        /// A connection of this host (target key) ended (its silent channel saw it go, or it was
        /// found dead and closed).
        case connectionEnded(String)
        /// A connection of this host (target key) was checked and still reaches its server.
        case linkAlive(String)
    }

    /// Whether the Mac has a way out now (set by the connectivity monitor).
    public var networkUp = true

    /// Servers whose sign-in asks a second step (a one-time code, a push to approve) after the
    /// password: every further connection would ask it again, so their tabs share one connection
    /// for as long as the server lets them (by server: any of its names).
    private var secondStep: Set<String> = []

    public func noteSecondStep(_ host: String) {
        if secondStep.insert(Self.server(host)).inserted {
            ConnectionLog.shared.info("This server asks a second step at sign-in; its tabs share one connection while it allows", .signIn, host: host)
        }
    }

    public func asksSecondStep(_ host: String) -> Bool { secondStep.contains(Self.server(host)) }

    private static func server(_ host: String) -> String { ResolvedNames.serverID(for: host) ?? host }

    /// When the user last cancelled a sign-in of each server: what follows by itself (the next
    /// queued transfer, a file window, a forward) does not ask again for a moment.
    private var cancelled: [String: Date] = [:]
    public static let cancelQuiet: TimeInterval = 15

    public func noteCancelled(_ host: String) { cancelled[Self.server(host)] = Date() }

    /// The user asked for this host again (Retry, Reconnect): a sign-in may ask, also right after
    /// one was cancelled.
    public func signInWanted(_ host: String) { cancelled[Self.server(host)] = nil }

    /// Whether something that follows by itself may sign in (and ask) for `host` now.
    public func mayAskByItself(_ host: String) -> Bool {
        guard let at = cancelled[Self.server(host)] else { return true }
        return Date().timeIntervalSince(at) >= Self.cancelQuiet
    }

    private var observers: [UUID: (Event) -> Void] = [:]
    private var waiters: [UUID: (host: String, continuation: CheckedContinuation<Bool, Never>)] = [:]

    public init() {}

    /// Calls `handler` for every event from now on (until `stopObserving`).
    @discardableResult
    public func observe(_ handler: @escaping (Event) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    public func stopObserving(_ id: UUID) { observers[id] = nil }

    public func post(_ event: Event) {
        // Signed in: a cancel before it no longer holds anything back.
        if case .signedIn(let host) = event { cancelled[Self.server(host)] = nil }
        for handler in observers.values { handler(event) }
        for (id, waiter) in waiters where Self.concerns(event, waiter.host) {
            waiters[id] = nil
            waiter.continuation.resume(returning: true)
        }
    }

    /// From any thread or actor: posted on the main actor.
    public nonisolated static func post(_ event: Event) {
        Task { @MainActor in shared.post(event) }
    }

    /// Waits until `host` can be reached again (it signed in, the network came back, Tether was
    /// unlocked) — true — or `seconds` passed — false. Cancelling the caller ends the wait (false).
    public func whenReachable(_ host: String, within seconds: TimeInterval) async -> Bool {
        let id = UUID()
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            self?.resume(id, with: false)
        }
        defer { timeout.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: false); return }
                waiters[id] = (host, continuation)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.resume(id, with: false) }
        }
    }

    private func resume(_ id: UUID, with value: Bool) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: value)
    }

    /// Whether `event` is news for `host` (any of its names).
    public static func concerns(_ event: Event, _ host: String) -> Bool {
        switch event {
        case .networkBack, .unlocked: return true
        case .signedIn(let signed), .linkAlive(let signed): return sameServer(signed, host)
        case .connectionEnded: return false
        }
    }

    /// Two host keys for the same server (aliases, Quick Connect), once ssh told where they lead.
    public static func sameServer(_ a: String, _ b: String) -> Bool {
        a == b || (ResolvedNames.serverID(for: a).map { $0 == ResolvedNames.serverID(for: b) } ?? false)
    }
}
