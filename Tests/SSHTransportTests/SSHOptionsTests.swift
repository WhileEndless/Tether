import Testing
import Foundation
import TetherCore
@testable import SSHTransport

@Suite struct SSHOptionsTests {
    @Test func adhocDestination() {
        let t = ConnectionTarget.adhoc(user: "bob", host: "example.com", port: 2222, jump: "jump.example.com")
        #expect(SSHOptions.destinationArguments(for: t) == ["-p", "2222", "-J", "jump.example.com", "-l", "bob", "--", "example.com"])
        let scp = SSHOptions.scpArguments(for: t)
        #expect(scp.options == ["-P", "2222", "-J", "jump.example.com"])
        #expect(scp.host == "bob@example.com")
    }

    @Test func quickConnectParsing() {
        #expect(ConnectionTarget.parse("web", knownAliases: ["web"]) == .alias("web"))
        #expect(ConnectionTarget.parse("bob@example.com:2200 -J jump", knownAliases: [])
                == .adhoc(user: "bob", host: "example.com", port: 2200, jump: "jump"))
        #expect(ConnectionTarget.parse("[2001:db8::1]:22", knownAliases: [])
                == .adhoc(user: nil, host: "2001:db8::1", port: 22, jump: nil))
    }

    @Test func shellQuoting() {
        #expect("simple-path/x".shellQuoted == "simple-path/x")
        #expect("it's".shellQuoted == #"'it'\''s'"#)
        #expect("a b".shellQuoted == "'a b'")
    }
}

@Suite struct PortForwardTests {
    @Test func specifications() {
        #expect(PortForward(kind: .local, listenPort: 8080, destinationHost: "db.internal", destinationPort: 5432).specification
                == "8080:db.internal:5432")
        #expect(PortForward(kind: .remote, bindAddress: "0.0.0.0", listenPort: 9000, destinationPort: 3000).specification
                == "0.0.0.0:9000:localhost:3000")
        #expect(PortForward(kind: .dynamic, listenPort: 1080, destinationPort: 0).specification == "1080")
        #expect(PortForward(kind: .local, listenPort: 8080, destinationHost: "::1", destinationPort: 80).specification
                == "8080:[::1]:80")
    }

    @Test func detectsBusyLocalPort() throws {
        // Occupy a port, then ask whether it is free.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 1)
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: bound.sin_port))
        #expect(!LocalPorts.isFree(port))
        #expect((LocalPorts.nextFree(from: port) ?? port) != port)
    }
}
