import Foundation
import Testing
@testable import SSHTransport

/// The Connection Log keeps what helps follow a problem — ssh's steps through connecting and signing
/// in, its errors — and leaves out the protocol chatter.
@Suite struct ConnectionLogTests {
    static let verbose = """
    OpenSSH_9.8p1, LibreSSL 3.3.6
    debug1: Reading configuration data /etc/ssh/ssh_config
    debug1: Connecting to example.com [192.0.2.10] port 22.
    debug1: Connection established.
    debug1: identity file \(NSHomeDirectory())/.ssh/id_ed25519 type 3
    debug1: Remote protocol version 2.0, remote software version OpenSSH_9.6
    debug1: kex: algorithm: curve25519-sha256
    debug1: Server host key: ssh-ed25519 SHA256:abc
    debug1: Host 'example.com' is known and matches the ED25519 host key.
    debug1: Authentications that can continue: publickey,password
    debug1: Offering public key: \(NSHomeDirectory())/.ssh/id_ed25519 ED25519 SHA256:def
    debug1: Next authentication method: password
    debug1: Authenticated to example.com ([192.0.2.10]:22) using "password".
    debug1: channel 0: new session [client-session] (inactive timeout: 0)
    """

    @Test func detailKeepsTheStepsAndLeavesOutTheChatter() {
        let detail = DiagnosticText.detail(Self.verbose)
        #expect(detail.contains("Connecting to example.com"))
        #expect(detail.contains("remote software version OpenSSH_9.6"))
        #expect(detail.contains("Authentications that can continue: publickey,password"))
        #expect(detail.contains("using \"password\""))
        #expect(detail.contains("OpenSSH_9.8p1"), "lines that are not debug output stay")
        #expect(!detail.contains("Reading configuration data"))
        #expect(!detail.contains("kex: algorithm"))
        #expect(!detail.contains("channel 0: new session"))
        #expect(!detail.contains(NSHomeDirectory()), "the home folder is written ~")
        #expect(detail.contains("~/.ssh/id_ed25519"))
    }

    @Test func detailKeepsTheLastLines() {
        let many = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let detail = DiagnosticText.detail(many)
        #expect(detail.split(separator: "\n").count == 16)
        #expect(detail.hasSuffix("line 40"))
    }

    @Test func howSshSignedIn() {
        #expect(DiagnosticText.signInMethod(Self.verbose.components(separatedBy: "\n")) == "password")
        #expect(DiagnosticText.signInMethod(["debug1: Authentication succeeded (publickey)."]) == "publickey")
        #expect(DiagnosticText.signInMethod(["debug1: Connection established."]) == nil)
    }

    @Test func textNamesTheKindPlaceAndIndentsSshsWords() {
        let log = ConnectionLog()
        log.problem("Sign-in failed", .signIn, host: "user@example.com", tab: "build (tether-1)",
                    detail: "Permission denied (publickey,password).")
        log.info("The Mac woke up", .network)
        let text = log.text.components(separatedBy: "\n")
        #expect(text.count == 3)
        #expect(text[0].contains("PROBLEM signIn [user@example.com · build (tether-1)] Sign-in failed"))
        #expect(text[1] == "    Permission denied (publickey,password).")
        #expect(text[2].hasSuffix("INFO network The Mac woke up"))
    }

    @Test func keepsTheNewestEvents() {
        let log = ConnectionLog()
        for i in 0..<(ConnectionLog.limit + 10) { log.info("event \(i)") }
        #expect(log.all.count == ConnectionLog.limit)
        #expect(log.all.first?.message == "event 10")
    }

    @Test func durations() {
        #expect(SharedConnections.seconds(0.84) == "0.8 s")
        #expect(SharedConnections.seconds(42) == "42 s")
        #expect(SharedConnections.seconds(185) == "3 min 5 s")
        #expect(SharedConnections.seconds(7_500) == "2 h 5 min")
    }

    @Test func onlyTheWholeHomeFolderIsAbbreviatedAndProxyCommandsAreHidden() {
        #expect(DiagnosticText.homeAbbreviated("key /home/user/.ssh/id and /home/user2/x", home: "/home/user")
                == "key ~/.ssh/id and /home/user2/x")
        #expect(DiagnosticText.homeAbbreviated("at /home/user", home: "/home/user") == "at ~")
        let masked = DiagnosticText.detail("debug1: Executing proxy command: exec sshpass -p hunter2 ssh -W host:22 jump")
        #expect(!masked.contains("hunter2"))
        #expect(masked.contains("(not shown)"))
    }
}
