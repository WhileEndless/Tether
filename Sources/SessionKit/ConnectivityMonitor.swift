import AppKit
import Network

/// Reports what can affect connections: the network going away and coming back, the way out
/// changing while it stays up (Wi-Fi → Ethernet, a VPN, a new hotspot: the old connection may be
/// dead although "online"), and the Mac going to sleep and waking.
@MainActor
public final class ConnectivityMonitor {
    public enum Event: Sendable, Equatable {
        case lost
        case restored
        /// Still online, but through other interfaces.
        case changed
        case willSleep
        case didWake
    }

    private let monitor = NWPathMonitor()
    private var lastStatus: NWPath.Status?
    private var lastInterfaces: [String] = []
    private var observers: [NSObjectProtocol] = []
    public var onEvent: ((Event) -> Void)?
    public private(set) var isOnline = true
    public private(set) var isAsleep = false
    /// The network interfaces in use now (`en0`, `utun3`, …), for the log.
    public var interfaces: [String] { lastInterfaces }

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // Interfaces that come and go without changing the way out (AirDrop, Apple's low-latency
            // links, the cellular baseband interface) are left out.
            let interfaces = path.availableInterfaces.map(\.name)
                .filter { name in !["awdl", "llw", "anpi", "ap"].contains { name.hasPrefix($0) } }.sorted()
            let status = path.status
            Task { @MainActor in self?.update(status: status, interfaces: interfaces) }
        }
        monitor.start(queue: .main)
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAsleep = true
                self?.onEvent?(.willSleep)
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAsleep = false
                self?.onEvent?(.didWake)
            }
        })
    }

    func update(status: NWPath.Status, interfaces: [String]) {
        defer { lastStatus = status; lastInterfaces = interfaces }
        let online = status == .satisfied
        isOnline = online
        guard let previous = lastStatus else { return }
        if previous != status {
            onEvent?(online ? .restored : .lost)
        } else if online, interfaces != lastInterfaces {
            onEvent?(.changed)
        }
    }
}
