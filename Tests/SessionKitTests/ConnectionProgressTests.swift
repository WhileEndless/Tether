import Testing
@testable import SessionKit

@Suite struct ConnectionProgressTests {
    @Test func followsSSHVerboseOutput() {
        var p = ConnectionProgress()
        p.ingest("debug1: Setting implicit ProxyCommand from ProxyJump: ssh -v -W '[%h]:%p' jump.example.com")
        #expect(p.detail == "Starting jump host connection")
        p.ingest("debug1: Connecting to jump.example.com [192.0.2.1] port 22.")
        #expect(p.step == .connect && p.hops == ["jump.example.com"])
        p.ingest("debug1: Connection established.")
        p.ingest("debug1: Authenticating to jump.example.com:22 as 'admin'")
        #expect(p.step == .authenticate && p.detail.contains("admin"))
        p.ingest("debug1: Offering public key: /home/user/.ssh/id_ed25519 ED25519 SHA256:abc explicit")
        #expect(p.detail == "Trying key id_ed25519")
        p.ingest("Authenticated to jump.example.com ([192.0.2.1]:22) using \"publickey\".")
        #expect(p.detail.contains("publickey"))
        p.ingest("debug1: Connecting to web.internal [10.0.0.5] port 2222.")
        #expect(p.step == .connect && p.hops == ["jump.example.com", "web.internal"])
        p.ingest("debug1: Next authentication method: password")
        #expect(p.detail == "Password required")
        p.ingest("debug1: Entering interactive session.")
        #expect(p.step == .startSession)
        #expect(p.failure == nil)
        #expect(p.fraction > 0.5)
    }

    @Test func diagnosesFailures() {
        var p = ConnectionProgress()
        p.ingest("user@web.internal: Permission denied (publickey,password).")
        #expect(p.failure == "The server rejected the sign-in.")
        #expect(p.hint?.contains("Edit Host") == true)
        #expect(ConnectionProgress.diagnose("ssh: Could not resolve hostname nope: nodename nor servname provided")?.0
                == "The host name could not be resolved.")
        #expect(ConnectionProgress.diagnose("connect to host 192.0.2.9 port 22: Connection refused") != nil)
        #expect(ConnectionProgress.diagnose("debug1: Connection established.") == nil)
    }

    /// What the jump host said about the server behind it is the cause shown — not the generic
    /// "closed during the handshake" ssh adds after it, and not "the server refused" (it was the
    /// jump host's word about the server, not this Mac's about the jump host).
    @Test func aJumpHostsWordsAreTheCauseShown() {
        var p = ConnectionProgress()
        p.ingest("channel 0: open failed: connect failed: Connection refused")
        p.ingest("stdio forwarding failed")
        p.ingest("kex_exchange_identification: Connection closed by remote host")
        p.ingest("Connection closed by UNKNOWN port 65535")
        #expect(p.failure == "The jump host answered, but could not reach the server (Connection refused).")
        let lines = ["channel 0: open failed: connect failed: Connection timed out", "stdio forwarding failed",
                     "kex_exchange_identification: Connection closed by remote host"]
        #expect(ConnectionProgress.diagnose(lines: lines)?.0 == "The jump host answered, but could not reach the server (Connection timed out).")
        #expect(ConnectionProgress.diagnose("channel 0: open failed: administratively prohibited: open failed\nstdio forwarding failed")?.0
                == "The jump host does not allow connections through it to this server.")
        // Without a jump host the same words keep their plain meaning.
        #expect(ConnectionProgress.diagnose("ssh: connect to host jump.example.com port 22: Connection refused")?.0
                == "The server refused the connection.")
    }
}
