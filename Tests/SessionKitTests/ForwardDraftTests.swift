import Foundation
import Testing
import TetherCore

/// The port forward editor's logic: plain-language choices map to the right ssh forward, the
/// port on this Mac follows the one to reach, and saved forwards read back without loss.
struct ForwardDraftTests {
    @Test func openingAServerPortOnThisMac() throws {
        var d = ForwardDraft(purpose: .serverPort)
        d.targetPort = "8090"
        d.targetPortChanged { $0 }
        #expect(d.listenPort == "8090", "the same number when it is free")
        let f = try #require(d.forward)
        #expect(f.kind == .local)
        #expect(f.specification == "8090:localhost:8090")
        #expect(f.sentence(server: "example.com") == "localhost:8090 on this Mac → port 8090 on example.com")
        #expect(f.offMeaning(server: "example.com") == "Off — nothing listens on port 8090 of this Mac")
    }

    @Test func aTakenPortMovesToTheNextFreeOne() throws {
        var d = ForwardDraft(purpose: .serverPort)
        d.targetPort = "8090"
        d.targetPortChanged { $0 == 8090 ? 8091 : $0 }
        #expect(d.listenPort == "8091")
        // A low port is opened higher on this Mac.
        d.targetPort = "80"
        d.targetPortChanged { $0 }
        #expect(d.listenPort == "8080")
    }

    @Test func aPortSetByHandNoLongerFollows() {
        var d = ForwardDraft(purpose: .serverPort)
        d.targetPort = "8090"
        d.targetPortChanged { $0 }
        d.listenPort = "9999"
        d.listenPortEdited()
        d.targetPort = "3000"
        d.targetPortChanged { $0 }
        #expect(d.listenPort == "9999")
    }

    @Test func aRealFreePortCheck() throws {
        // A port taken on this Mac (a socket bound here for the test) is not offered.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(bound == 0)
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let taken = Int(UInt16(bigEndian: got.sin_port))
        #expect(!LocalPorts.isFree(taken))
        var d = ForwardDraft(purpose: .serverPort)
        d.targetPort = String(taken)
        d.targetPortChanged { LocalPorts.isFree($0) ? $0 : LocalPorts.nextFree(from: $0 + 1) }
        #expect(d.listenPort != String(taken))
    }

    @Test func reachingAnotherMachine() throws {
        var d = ForwardDraft(purpose: .otherMachine)
        d.targetPort = "5432"
        d.targetPortChanged { $0 }
        #expect(d.problem != nil, "the machine is asked for")
        d.targetHost = "db.example.com"
        let f = try #require(d.forward)
        #expect(f.specification == "5432:db.example.com:5432")
        #expect(f.sentence(server: "jump.example.com") == "localhost:5432 on this Mac → db.example.com:5432, reached through jump.example.com")
        d.targetHost = "bad host"
        #expect(d.forward == nil)
        d.targetHost = "192.0.2.10"
        #expect(d.forward?.specification == "5432:192.0.2.10:5432")
        d.targetHost = "2001:db8::1"
        #expect(d.forward?.specification == "5432:[2001:db8::1]:5432")
    }

    @Test func lettingTheServerReachThisMac() throws {
        var d = ForwardDraft(purpose: .toThisMac)
        d.listenPort = "9000"
        d.targetPort = "3000"
        d.targetPortChanged { _ in 1 }      // nothing on this Mac follows: the port is the server's
        #expect(d.listenPort == "9000")
        let f = try #require(d.forward)
        #expect(f.kind == .remote)
        #expect(f.specification == "9000:localhost:3000")
        #expect(f.sentence(server: "example.com") == "Port 9000 on example.com → port 3000 on this Mac")
        #expect(f.offMeaning(server: "example.com") == "Off — port 9000 on example.com is closed")
        d.targetHost = "192.0.2.20"
        #expect(d.forward?.sentence(server: "example.com") == "Port 9000 on example.com → 192.0.2.20:3000 on this Mac’s network")
    }

    @Test func aSocksProxy() throws {
        let d = ForwardDraft(purpose: .socks)
        let f = try #require(d.forward)
        #expect(f.kind == .dynamic)
        #expect(f.specification == "1080")
        #expect(f.sentence(server: "example.com") == "SOCKS proxy at localhost:1080 on this Mac, going out through example.com")
    }

    @Test func openToTheNetwork() throws {
        var d = ForwardDraft(purpose: .serverPort)
        d.targetPort = "8090"
        d.targetPortChanged { $0 }
        d.openToNetwork = true
        let f = try #require(d.forward)
        #expect(f.specification == "0.0.0.0:8090:localhost:8090")
        #expect(!f.listensOnlyOnThisMac)
        #expect(f.sentence(server: "example.com").contains("open to your network"))
    }

    @Test func invalidPortsAreRefused() {
        var d = ForwardDraft(purpose: .serverPort)
        #expect(d.forward == nil)
        d.targetPort = "70000"
        d.listenPort = "8090"
        #expect(d.forward == nil)
        d.targetPort = "0"
        #expect(d.forward == nil)
        d.targetPort = "22"
        #expect(d.forward != nil)
    }

    /// Every saved forward reads back into the editor and saves again unchanged.
    @Test(arguments: [
        PortForward(kind: .local, label: "Web", listenPort: 8080, destinationHost: "localhost", destinationPort: 80, autoStart: true),
        PortForward(kind: .local, listenPort: 8080, destinationHost: "127.0.0.1", destinationPort: 80),
        PortForward(kind: .local, bindAddress: "0.0.0.0", listenPort: 5433, destinationHost: "db.example.com", destinationPort: 5432),
        PortForward(kind: .local, bindAddress: "192.0.2.5", listenPort: 5433, destinationHost: "192.0.2.10", destinationPort: 5432),
        PortForward(kind: .local, listenPort: 8443, destinationHost: "2001:db8::1", destinationPort: 443),
        PortForward(kind: .remote, listenPort: 9000, destinationHost: "localhost", destinationPort: 3000),
        PortForward(kind: .remote, bindAddress: "*", listenPort: 9000, destinationHost: "192.0.2.20", destinationPort: 3000),
        PortForward(kind: .remote, listenPort: 9000, destinationHost: "127.0.0.1", destinationPort: 3000),
        PortForward(kind: .dynamic, listenPort: 1080, destinationHost: "localhost", destinationPort: 0),
        PortForward(kind: .dynamic, bindAddress: "127.0.0.1", listenPort: 1081, destinationHost: "localhost", destinationPort: 0),
    ])
    func savedForwardsRoundTrip(_ f: PortForward) throws {
        let back = try #require(ForwardDraft(f).forward)
        #expect(back == f)
    }

    @Test func purposesOfSavedForwards() {
        #expect(ForwardDraft(PortForward(kind: .local, listenPort: 1, destinationPort: 1)).purpose == .serverPort)
        #expect(ForwardDraft(PortForward(kind: .local, listenPort: 1, destinationHost: "db.example.com", destinationPort: 1)).purpose == .otherMachine)
        #expect(ForwardDraft(PortForward(kind: .remote, listenPort: 1, destinationPort: 1)).purpose == .toThisMac)
        #expect(ForwardDraft(PortForward(kind: .dynamic, listenPort: 1, destinationPort: 0)).purpose == .socks)
    }
}
