import Foundation
import Observation
import TetherCore

/// Tabs closed on this Mac while their tmux or screen session went on running on the server.
///
/// Remembered so that such a session, listed under its host, is known as one of this Mac's (and
/// comes first), and opens again under the name and color its tab had. A session on the server
/// without such a note — another Mac's, or someone else's who signs in with the same account — is
/// listed too, but never opened or ended in a batch: only one by one, by the user.
///
/// Only what the user gave the tab is kept (a name they typed, a color), never a title taken from
/// what ran in it (it can hold a command line); private tabs leave nothing here. Notes go after
/// `maxAge`, and there are never more than `maxCount`.
public struct LeftSession: Codable, Hashable, Sendable {
    public var targetKey: String
    /// The tmux or screen session's name on the server.
    public var name: String
    public var persistence: PersistenceMode
    /// The name the user gave the tab, if they did.
    public var title: String?
    public var color: TagColor
    public var closedAt: Date
}

@MainActor
@Observable
final class LeftOnServer {
    static let maxCount = 200
    static let maxAge: TimeInterval = 90 * 24 * 3600

    @ObservationIgnored private let store: JSONStore<[LeftSession]>
    private(set) var all: [LeftSession]

    init(store: JSONStore<[LeftSession]> = JSONStore(filename: "left-on-server.json"), now: Date = Date()) {
        self.store = store
        all = []
        all = Self.pruned(store.load() ?? [], now: now)
    }

    func find(_ targetKey: String, _ name: String) -> LeftSession? {
        all.first { $0.name == name && $0.targetKey == targetKey }
    }

    func remember(_ session: LeftSession) {
        all.removeAll { $0.name == session.name && $0.targetKey == session.targetKey }
        all.insert(session, at: 0)
        all = Self.pruned(all, now: Date())
        store.saveSoon(all, within: 1)
    }

    func forget(_ targetKey: String, _ name: String) {
        let before = all.count
        all.removeAll { $0.name == name && $0.targetKey == targetKey }
        if all.count != before { store.saveSoon(all, within: 1) }
    }

    func forgetAll(on targetKey: String) {
        let before = all.count
        all.removeAll { $0.targetKey == targetKey }
        if all.count != before { store.saveSoon(all, within: 1) }
    }

    static func pruned(_ list: [LeftSession], now: Date) -> [LeftSession] {
        Array(list.filter { now.timeIntervalSince($0.closedAt) < maxAge }
            .sorted { $0.closedAt > $1.closedAt }
            .prefix(maxCount))
    }
}
