import Foundation
import Testing
@testable import SSHTransport

/// How a failed sign-in counts for what it was answered with: only what the server judged is
/// forgotten (`SignInEnd`).
@Suite struct SignInEndTests {
    func end(_ stop: MasterLauncher.Stop? = nil, killed: Bool = false, network: Bool = false, cancelled: Bool = false,
             log: [String] = []) -> SignInEnd {
        SharedConnections.end(status: stop, killed: killed, networkChanged: network, cancelledByUser: cancelled, log: log)
    }

    @Test func whatTheServerJudged() {
        #expect(end(log: ["user@example.com: Permission denied (publickey,password)."]) == .failed)
        #expect(end(log: ["Connection closed by 192.0.2.5 port 22"]) == .failed, "a server may hang up instead of saying no")
    }

    @Test func whatItNeverJudged() {
        #expect(end(log: ["ssh: connect to host 192.0.2.5 port 22: Operation timed out"]) == .notJudged)
        #expect(end(log: ["ssh: Could not resolve hostname example.com: nodename nor servname provided, or not known"]) == .notJudged)
        #expect(end(.stopped, killed: true) == .notJudged, "a tab closed, Retry, stuck before any question")
        #expect(end(killed: true) == .notJudged, "ended by Tether: an answer that came too late")
        #expect(end(network: true, log: ["Connection closed by 192.0.2.5 port 22"]) == .notJudged)
        #expect(end(killed: true, cancelled: true) == .notJudged)
        #expect(end(log: ["kex_exchange_identification: Connection closed by remote host",
                     "Connection closed by UNKNOWN port 65535"]) == .notJudged, "the jump host's connection ended")
    }

    @Test func sentAndNeverAnswered() {
        #expect(end(.unanswered, killed: true) == .unanswered)
    }
}
