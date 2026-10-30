import Foundation

/// `SharedConnections.shared` is one for the whole test run, and suites run side by side: a suite
/// that points it at its own socket folder (`useSocketDirectory`) and resets it afterwards takes
/// this lock for that time, so another suite cannot swap the folder under it (its connection then
/// waited for its time limit). A holder that never lets go is waited for two minutes at most.
public actor SharedConnectionsTestLock {
    public static let shared = SharedConnectionsTestLock()
    private var held = false

    public func acquire() async {
        let deadline = Date().addingTimeInterval(120)
        while held, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        held = true
    }

    public func release() { held = false }
}
