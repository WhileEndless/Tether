import Foundation

/// A saved SSH port forward for a host.
public struct PortForward: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        /// -L: a port on this Mac reaches a host/port as seen from the server.
        case local
        /// -R: a port on the server reaches a host/port as seen from this Mac.
        case remote
        /// -D: a SOCKS proxy on this Mac that tunnels through the server.
        case dynamic

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .local: "Local (this Mac → server side)"
            case .remote: "Remote (server → this Mac)"
            case .dynamic: "SOCKS proxy"
            }
        }
        public var flag: String {
            switch self {
            case .local: "-L"
            case .remote: "-R"
            case .dynamic: "-D"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var label: String
    /// Address the listening side binds to (empty = default, i.e. loopback).
    public var bindAddress: String
    public var listenPort: Int
    public var destinationHost: String
    public var destinationPort: Int
    /// Start automatically whenever a session to the host connects.
    public var autoStart: Bool

    public init(id: UUID = UUID(), kind: Kind = .local, label: String = "", bindAddress: String = "",
                listenPort: Int, destinationHost: String = "localhost", destinationPort: Int, autoStart: Bool = false) {
        self.id = id
        self.kind = kind
        self.label = label
        self.bindAddress = bindAddress
        self.listenPort = listenPort
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
        self.autoStart = autoStart
    }

    /// Argument for -L / -R / -D.
    public var specification: String {
        let bind = bindAddress.isEmpty ? "" : (bindAddress.contains(":") ? "[\(bindAddress)]:" : "\(bindAddress):")
        switch kind {
        case .dynamic: return "\(bind)\(listenPort)"
        case .local, .remote:
            let dest = destinationHost.contains(":") ? "[\(destinationHost)]" : destinationHost
            return "\(bind)\(listenPort):\(dest):\(destinationPort)"
        }
    }

    /// Human readable summary, e.g. "localhost:8080 → db.internal:5432".
    public var summary: String {
        let listen = "\(bindAddress.isEmpty ? "localhost" : bindAddress):\(listenPort)"
        switch kind {
        case .local: return "\(listen) → \(destinationHost):\(destinationPort)"
        case .remote: return "server \(listen) → \(destinationHost):\(destinationPort)"
        case .dynamic: return "SOCKS \(listen)"
        }
    }

    /// Whether the listening port is on this Mac (so it can be checked and opened locally).
    public var listensLocally: Bool { kind != .remote }
}

public enum LocalPorts {
    /// True if nothing on this Mac is listening on `port` at `address` (default loopback).
    public static func isFree(_ port: Int, address: String = "") -> Bool {
        let host = address.isEmpty || address == "localhost" ? "127.0.0.1" : address
        let fd = socket(host.contains(":") ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if host.contains(":") {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(port).bigEndian)
            inet_pton(AF_INET6, host, &addr.sin6_addr)
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 }
            }
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, host == "*" || host == "0.0.0.0" ? "0.0.0.0" : host, &addr.sin_addr)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// The first free port at or above `start`.
    public static func nextFree(from start: Int, address: String = "") -> Int? {
        var p = max(start, 1024)
        while p < 65535 {
            if isFree(p, address: address) { return p }
            p += 1
        }
        return nil
    }
}
