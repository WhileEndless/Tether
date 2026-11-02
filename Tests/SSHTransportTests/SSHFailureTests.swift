import Foundation
import Testing
@testable import SSHTransport

/// One reading of ssh's words for every feature. The questions differ on purpose: a refused
/// connection is unreachable (tried again in rounds) but not the network's failure for a sign-in
/// (a server may hang up instead of saying no).
@Suite struct SSHFailureTests {
    @Test func theSameWordsAnswerEachQuestionAsDesigned() {
        let refused = "ssh: connect to host example.com port 22: Connection refused"
        #expect(SSHFailure.isUnreachable(refused))
        #expect(!SSHFailure.isNetwork(refused))
        #expect(SSHFailure.isLostDuringTransfer(refused))

        let timedOut = "ssh: connect to host 192.0.2.5 port 22: Operation timed out"
        #expect(SSHFailure.isNetwork(timedOut) && SSHFailure.isUnreachable(timedOut))

        let name = "ssh: Could not resolve hostname web.example.com: nodename nor servname provided, or not known"
        #expect(SSHFailure.isNetwork(name) && SSHFailure.isNameNotFound(name) && SSHFailure.isPermanent(name))

        let denied = "user@example.com: Permission denied (publickey,password)."
        #expect(SSHFailure.isRefusedSignIn(denied) && SSHFailure.isPermanent(denied))
        #expect(!SSHFailure.isNetwork(denied))

        #expect(SSHFailure.isSessionRefused("channel 2: open failed: administratively prohibited: open failed"))
        #expect(SSHFailure.isSessionRefused("Session open refused by peer"))
        #expect(SSHFailure.isLostSharedConnection("Connection closed by UNKNOWN port 65535"))
        #expect(SSHFailure.isLostSharedConnection("Control socket connect(/tmp/x): No such file or directory"))
        #expect(!SSHFailure.isLostSharedConnection("control socket connect"), "ssh's own capitalisation only")

        #expect(SSHFailure.isBrokenConnection("client_loop: send disconnect: Broken pipe"))
        #expect(SSHFailure.isLostDuringTransfer("Connection to example.com closed by remote host."))
        // A key file named in ssh_config that is missing is skipped, not a failure.
        #expect(!SSHFailure.isPermanent("no such identity: /home/user/.ssh/id_missing: No such file or directory"))
    }

    /// The old names read the same as the one place they now forward to.
    @Test func earlierNamesForward() {
        for text in ["Operation timed out", "Connection refused", "Permission denied (password).", "Broken pipe",
                     "Session open refused by peer", "Connection closed by UNKNOWN port 65535", "fine"] {
            #expect(SealedPasswordCache.isNetworkFailure(text) == SSHFailure.isNetwork(text))
            #expect(SharedConnections.isSessionRefused(text) == SSHFailure.isSessionRefused(text))
            #expect(SharedConnections.isLostConnectionMessage(text) == SSHFailure.isLostSharedConnection(text))
        }
    }

    /// An ssh that signed in by itself: only its own failure (255) is judged, and the network's
    /// failure or a stop by Tether is not the server's verdict.
    @Test func signInEndOfAnOwnSignIn() {
        #expect(SSHFailure.signInEnd(status: 0, stderr: "", stopped: false) == .succeeded)
        #expect(SSHFailure.signInEnd(status: 1, stderr: "Connection timed out", stopped: false) == .succeeded,
                "a command's own failure: the sign-in worked")
        #expect(SSHFailure.signInEnd(status: 255, stderr: "Permission denied (password).", stopped: false) == .failed)
        #expect(SSHFailure.signInEnd(status: 255, stderr: "No route to host", stopped: false) == .notJudged)
        #expect(SSHFailure.signInEnd(status: 255, stderr: "Permission denied", stopped: true) == .notJudged)
        #expect(SSHFailure.signInEnd(status: -2, stderr: "", stopped: false) == .notJudged, "ended by a signal")
    }

    /// The jump host answered but could not reach the server behind it: unreachable (tried again in
    /// the server's rounds), not the server's session limit, and the jump host's own reason kept.
    @Test func aJumpHostThatCannotReachTheServer() {
        let said = """
        channel 0: open failed: connect failed: No route to host
        stdio forwarding failed
        kex_exchange_identification: Connection closed by remote host
        """
        #expect(SSHFailure.isJumpCannotReachTarget(said))
        #expect(SSHFailure.isUnreachable(said))
        #expect(SSHFailure.jumpFailureReason(said) == "No route to host")
        #expect(!SSHFailure.isJumpCannotReachTarget("ssh: connect to host jump.example.com port 22: Connection refused"))
        #expect(!SSHFailure.isJumpCannotReachTarget("channel 3: open failed: administratively prohibited: open failed"),
                "a refused session on a server's own connection stays the session limit's")
        #expect(SSHFailure.isSessionRefused("channel 3: open failed: administratively prohibited: open failed"))
    }
}
