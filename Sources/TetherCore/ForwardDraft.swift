import Foundation

/// A port forward as the editor shows it: what the user wants to do (not ssh's -L/-R/-D), the
/// ports and machine for it, and the sentence that says what will happen. Turned into a
/// `PortForward` to save and run; any saved forward reads back into one without losing anything.
public struct ForwardDraft: Equatable, Sendable {
    public enum Purpose: String, CaseIterable, Identifiable, Sendable {
        /// A port of the server, opened on this Mac (-L to the server's own localhost).
        case serverPort
        /// Another machine the server can reach, opened on this Mac (-L to that machine).
        case otherMachine
        /// A port on the server that reaches this Mac or a machine on its network (-R).
        case toThisMac
        /// A SOCKS proxy on this Mac that goes out through the server (-D).
        case socks

        public var id: String { rawValue }

        public func title(server: String) -> String {
            switch self {
            case .serverPort: "Open a port of \(server) on this Mac"
            case .otherMachine: "Reach another machine through \(server)"
            case .toThisMac: "Let \(server) reach this Mac"
            case .socks: "Browse through \(server) (SOCKS proxy)"
            }
        }

        public var kind: PortForward.Kind {
            switch self {
            case .serverPort, .otherMachine: .local
            case .toThisMac: .remote
            case .socks: .dynamic
            }
        }
    }

    public var id: UUID
    public var purpose: Purpose
    public var label: String
    /// The port that listens: on this Mac (`serverPort`, `otherMachine`, `socks`) or on the server
    /// (`toThisMac`). Text, as typed.
    public var listenPort: String
    /// The port connections go to (not for `socks`).
    public var targetPort: String
    /// The machine connections go to: as the server sees it (`otherMachine`), or as this Mac sees
    /// it (`toThisMac`, empty = this Mac). Kept as saved (`127.0.0.1` stays) for `serverPort`.
    public var targetHost: String
    /// The listening port follows the target port (the same number when it is free) until the
    /// user sets it.
    public var listenFollowsTarget: Bool
    /// Other devices on the network may connect to the listening port (bound to all addresses).
    public var openToNetwork: Bool
    /// A bind address other than loopback or all addresses, saved before (kept as it is).
    public var customBind: String?
    /// How "all addresses" is written (a saved `*` stays `*`).
    var allAddresses = "0.0.0.0"
    public var autoStart: Bool

    public init(purpose: Purpose = .serverPort, id: UUID = UUID()) {
        self.id = id
        self.purpose = purpose
        label = ""
        listenPort = ""
        targetPort = ""
        targetHost = ""
        listenFollowsTarget = purpose != .socks && purpose != .toThisMac
        openToNetwork = false
        customBind = nil
        autoStart = false
        if purpose == .socks { listenPort = "1080"; listenFollowsTarget = false }
    }

    /// A saved forward, to edit.
    public init(_ f: PortForward) {
        id = f.id
        label = f.label
        autoStart = f.autoStart
        listenPort = String(f.listenPort)
        targetPort = f.kind == .dynamic ? "" : String(f.destinationPort)
        listenFollowsTarget = false
        let bind = f.bindAddress
        openToNetwork = Self.isAllAddresses(bind)
        if openToNetwork { allAddresses = bind }
        customBind = bind.isEmpty || openToNetwork ? nil : bind
        switch f.kind {
        case .dynamic:
            purpose = .socks
            targetHost = ""
        case .remote:
            purpose = .toThisMac
            targetHost = f.destinationHost.lowercased() == "localhost" ? "" : f.destinationHost
        case .local:
            purpose = Self.isLoopback(f.destinationHost) ? .serverPort : .otherMachine
            targetHost = f.destinationHost
        }
    }

    // MARK: Ports

    /// The target port was typed: the listening port follows it while it may. `available` gives
    /// the port to use for a wanted one (itself when free, else the next free one; nil: none).
    public mutating func targetPortChanged(available: (Int) -> Int?) {
        guard listenFollowsTarget, purpose != .socks, purpose != .toThisMac else { return }
        guard let port = Int(targetPort), (1...65535).contains(port) else { return }
        // Ports below 1024 need administrator rights to listen on an open address: start higher.
        let wanted = port < 1024 ? 8000 + port : port
        listenPort = available(wanted).map(String.init) ?? String(wanted)
    }

    /// The user typed the listening port: it no longer follows.
    public mutating func listenPortEdited() { listenFollowsTarget = false }

    /// The address the listening side binds to.
    public var bindAddress: String {
        if let customBind { return customBind }
        return openToNetwork ? allAddresses : ""
    }

    /// Where connections go, as saved.
    var destinationHost: String {
        switch purpose {
        case .serverPort: Self.isLoopback(targetHost) && !targetHost.trimmingCharacters(in: .whitespaces).isEmpty ? targetHost : "localhost"
        case .otherMachine: targetHost.trimmingCharacters(in: .whitespaces)
        case .toThisMac: targetHost.trimmingCharacters(in: .whitespaces).isEmpty ? "localhost" : targetHost.trimmingCharacters(in: .whitespaces)
        case .socks: "localhost"
        }
    }

    // MARK: Checking and saving

    /// What keeps it from being saved, in words (nil: ready).
    public var problem: String? {
        guard let listen = Int(listenPort), (1...65535) ~= listen else {
            return purpose == .toThisMac ? "Enter the port to open on the server (1–65535)." : "Enter the port to use on this Mac (1–65535)."
        }
        if purpose == .socks { return nil }
        guard let target = Int(targetPort), (1...65535) ~= target else { return "Enter the port to reach (1–65535)." }
        let host = targetHost.trimmingCharacters(in: .whitespaces)
        if purpose == .otherMachine, host.isEmpty { return "Enter the machine to reach: its name or address, as the server sees it." }
        if (purpose == .otherMachine || purpose == .toThisMac), !host.isEmpty, !Self.isValidHost(host) {
            return "“\(host)” is not a machine name or address."
        }
        return nil
    }

    /// The forward to save, when it can be.
    public var forward: PortForward? {
        guard problem == nil, let listen = Int(listenPort) else { return nil }
        return PortForward(id: id, kind: purpose.kind, label: label.trimmingCharacters(in: .whitespaces), bindAddress: bindAddress,
                           listenPort: listen, destinationHost: destinationHost,
                           destinationPort: purpose == .socks ? 0 : Int(targetPort) ?? 0, autoStart: autoStart)
    }

    // MARK: Hosts

    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        return h.isEmpty || h == "localhost" || h.hasPrefix("127.") || h == "::1"
    }

    static func isAllAddresses(_ host: String) -> Bool {
        ["0.0.0.0", "*", "::", "[::]"].contains(host.trimmingCharacters(in: .whitespaces))
    }

    /// A host name or an IPv4/IPv6 address (brackets allowed around IPv6).
    static func isValidHost(_ host: String) -> Bool {
        let h = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        guard !h.isEmpty, h.count <= 253 else { return false }
        if h.contains(":") {        // IPv6
            return h.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } && h.filter({ $0 == ":" }).count >= 2
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        return h.unicodeScalars.allSatisfy { allowed.contains($0) && $0.isASCII } && !h.hasPrefix("-") && !h.hasPrefix(".")
    }
}

// MARK: Words

extension PortForward {
    /// What it does, with the real values: "localhost:8090 on this Mac → port 8090 on server".
    public func sentence(server: String) -> String {
        let dest = destinationHost.contains(":") && !destinationHost.hasPrefix("[") ? "[\(destinationHost)]" : destinationHost
        switch kind {
        case .local:
            if ForwardDraft.isLoopback(destinationHost) {
                return "\(macListen) → port \(destinationPort) on \(server)"
            }
            return "\(macListen) → \(dest):\(destinationPort), reached through \(server)"
        case .remote:
            let open = ForwardDraft.isAllAddresses(bindAddress) ? " (open to its network)" : ""
            let to = ForwardDraft.isLoopback(destinationHost) ? "port \(destinationPort) on this Mac" : "\(dest):\(destinationPort) on this Mac’s network"
            return "Port \(listenPort) on \(server)\(open) → \(to)"
        case .dynamic:
            return "SOCKS proxy at \(macListen), going out through \(server)"
        }
    }

    /// Where it listens on this Mac, in words.
    var macListen: String {
        if bindAddress.isEmpty || ForwardDraft.isLoopback(bindAddress) { return "localhost:\(listenPort) on this Mac" }
        if ForwardDraft.isAllAddresses(bindAddress) { return "port \(listenPort) on this Mac (open to your network)" }
        return "\(bindAddress):\(listenPort) on this Mac"
    }

    /// What being off means for it.
    public func offMeaning(server: String) -> String {
        switch kind {
        case .remote: "Off — port \(listenPort) on \(server) is closed"
        case .local, .dynamic: "Off — nothing listens on port \(listenPort) of this Mac"
        }
    }

    /// What it does while on (shorter than the sentence: the row's title says the rest).
    public func onMeaning(server: String) -> String {
        "On — " + sentence(server: server)
    }
}
