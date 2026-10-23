import AppKit
import Network

/// Reports network availability changes and wake-from-sleep, so sessions can react immediately
/// instead of waiting for ssh's keep-alive timeout.
@MainActor
public final class ConnectivityMonitor {
    private let monitor = NWPathMonitor()
    private var lastStatus: NWPath.Status?
    private var observer: NSObjectProtocol?
    /// Called with `false` when the network goes away and `true` when it comes back (or on wake).
    public var onChange: ((Bool) -> Void)?
    public private(set) var isOnline = true

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let online = path.status == .satisfied
                let changed = self.lastStatus != nil && self.lastStatus != path.status
                self.lastStatus = path.status
                self.isOnline = online
                if changed { self.onChange?(online) }
            }
        }
        monitor.start(queue: .main)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onChange?(true) }
        }
    }
}
