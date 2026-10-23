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
}
