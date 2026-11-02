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
    /// What the way out is made of: interfaces in the order the system prefers them, gateways and
    /// this Mac's addresses on them — a new Wi-Fi network on the same `en0`, a VPN back on the same
    /// `utun` with another address, another interface preferred, all change it.
    private var lastSignature: [String] = []
    /// When the Mac went to sleep, and the way out then.
    private var sleptAt: Date?
    private var signatureAtSleep: [String] = []
    /// How long the Mac slept, and whether it woke on another way out (set at `.didWake`).
    public private(set) var lastSleep: (duration: TimeInterval, otherNetwork: Bool)?
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
            // Each listed once (one can be there twice, once per address family).
            let (interfaces, signature) = Self.describe(path)
            let status = path.status
            Task { @MainActor in self?.update(status: status, interfaces: interfaces, signature: signature) }
        }
        monitor.start(queue: .main)
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAsleep = true
                self?.sleptAt = Date()
                self?.signatureAtSleep = self?.lastSignature ?? []
                self?.onEvent?(.willSleep)
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isAsleep = false
                // The network as it is now (path updates can still be on their way): read at once.
                let path = self.monitor.currentPath
                self.isOnline = path.status == .satisfied
                let slept = self.sleptAt.map { Date().timeIntervalSince($0) } ?? 0
                // Compared with the path as it is now: its update usually comes after this notice.
                let now = path.status == .satisfied ? Self.describe(path).signature : self.lastSignature
                self.lastSleep = (slept, !self.signatureAtSleep.isEmpty && self.signatureAtSleep != now)
                // What later updates are compared with: the network as found now. Woken before Wi-Fi
                // was back, the update that brings it is then "restored" — compared with the state
                // before sleeping it looked like nothing changed, and tabs waited for an event that
                // never came.
                self.lastStatus = path.status
                if path.status == .satisfied { self.lastSignature = now }
                self.onEvent?(.didWake)
            }
        })
    }

    /// The interfaces in use (in order of preference) and what tells one way out from another:
    /// those, the gateways and this Mac's addresses on them.
    nonisolated static func describe(_ path: NWPath) -> (interfaces: [String], signature: [String]) {
        var seen: Set<String> = []
        let interfaces = path.availableInterfaces.map(\.name)
            .filter { name in !["awdl", "llw", "anpi", "ap"].contains { name.hasPrefix($0) } && seen.insert(name).inserted }
        let gateways = path.gateways.map { "\($0)" }.sorted()
        return (interfaces, interfaces + ["|"] + gateways + ["|"] + addresses(on: Set(interfaces)))
    }

    /// The new state is in place before the event goes out: what it reports (`interfaces`, for the
    /// log) is the network as it is now, not as it was.
    func update(status: NWPath.Status, interfaces: [String], signature: [String]? = nil) {
        let previous = lastStatus, before = lastSignature
        let signature = signature ?? interfaces
        lastStatus = status
        lastInterfaces = interfaces
        lastSignature = signature
        let online = status == .satisfied
        isOnline = online
        guard let previous else { return }
        if previous != status {
            onEvent?(online ? .restored : .lost)
        } else if online, signature != before {
            onEvent?(.changed)
        }
    }

    /// Reads the network as it is now and reports what changed since the last update — for when a
    /// path update was missed (they are not guaranteed after every sleep or interface change).
    public func recheck() {
        guard !isAsleep else { return }
        let path = monitor.currentPath
        // Only whether the network is there: what it is made of comes with the path updates (one
        // still on its way would otherwise be reported as a change twice).
        guard path.status != lastStatus else { return }
        let (interfaces, signature) = Self.describe(path)
        update(status: path.status, interfaces: interfaces, signature: signature)
    }

    /// This Mac's IPv4 addresses on these interfaces (link-local ones left out: they never change).
    nonisolated static func addresses(on names: Set<String>) -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [String] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = p.pointee.ifa_addr, names.contains(String(cString: p.pointee.ifa_name)) else { continue }
            // IPv4 only: IPv6 temporary (privacy) addresses change by themselves every few hours,
            // and each change would look like another network. A real change of network changes
            // the interfaces, the gateways or the IPv4 address.
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if text.lowercased().hasPrefix("fe80") || text.hasPrefix("169.254.") { continue }
            found.append(text)
        }
        return found.sorted()
    }
}
