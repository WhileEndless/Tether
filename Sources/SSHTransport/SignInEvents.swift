import Foundation

/// A sign-in to a server, as it starts and ends — told by whatever signs in (a shared connection,
/// or an ssh that signs in by itself when connections are not shared) to whoever keeps track of
/// what it was answered with (`SealedPasswordCache`, saving to the keychain after success).
public enum SignInEvent: Sendable, Equatable {
    /// The sign-in with this askpass token is for this connection (`SharedConnections.identity`).
    case started(token: String, connection: String)
    /// It ended (`SignInEnd`: how the server judged what it was sent).
    case ended(token: String, end: SignInEnd)
}

public protocol SignInObserver: AnyObject, Sendable {
    func signIn(_ event: SignInEvent)
}

/// Decides when a sign-in that may ask is allowed to start (not while Tether is locked).
public protocol SignInGatekeeper: AnyObject, Sendable {
    func mayStart() async
}

/// Where sign-ins are told about, and what a sign-in needs to know from the app: the gate, and
/// whether the user cancelled a sign-in's question.
///
/// Observers are held weakly and told in the order they were added, on the poster's thread.
public final class SignInEvents: @unchecked Sendable {
    public static let shared = SignInEvents()

    private let lock = NSLock()
    private struct Weak { weak var observer: SignInObserver? }
    private var observers: [Weak] = []
    private weak var _gatekeeper: SignInGatekeeper?
    private var cancelledTokens: Set<String> = []

    public init() {}

    public func add(_ observer: SignInObserver) {
        lock.withLock {
            observers.removeAll { $0.observer == nil }
            observers.append(Weak(observer: observer))
        }
    }

    public func remove(_ observer: SignInObserver) {
        lock.withLock { observers.removeAll { $0.observer == nil || $0.observer === observer } }
    }

    public func post(_ event: SignInEvent) {
        let current = lock.withLock { observers.compactMap(\.observer) }
        for o in current { o.signIn(event) }
    }

    public var gatekeeper: SignInGatekeeper? {
        get { lock.withLock { _gatekeeper } }
        set { lock.withLock { _gatekeeper = newValue } }
    }

    /// Waits until a sign-in that may ask is allowed (returns at once without a gatekeeper).
    public func mayStart() async {
        guard let gatekeeper else { return }
        lock.withLock { held += 1 }
        defer { lock.withLock { held -= 1 } }
        await gatekeeper.mayStart()
    }

    private var held = 0
    /// Sign-ins wait for the gate now (Tether is locked): what waits for them is not stuck.
    public var holdsSignIns: Bool { lock.withLock { held > 0 } }

    /// The user cancelled this sign-in's question: it ends unjudged, and its waiters stop too.
    public func userCancelled(token: String) { lock.withLock { _ = cancelledTokens.insert(token) } }

    /// Whether the user cancelled it (asked once: the mark is taken).
    public func takeCancelled(token: String) -> Bool { lock.withLock { cancelledTokens.remove(token) != nil } }

}
