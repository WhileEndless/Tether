import Foundation
import Testing
@testable import SSHTransport

/// How long a sign-in waits for a server that does not answer: the setting reaches the shared
/// connection and, without sharing, every tab's own ssh.
@Suite struct ConnectTimeoutTests {
    func value(_ args: [String]) -> String? {
        zip(args, args.dropFirst()).first { $0.0 == "-o" && $0.1.hasPrefix("ConnectTimeout=") }?.1
    }

    @Test func theSharedConnectionAndUnsharedTabsUseTheSetting() {
        var o = SSHOptions(useControlMaster: false)
        o.connectTimeout = 35
        #expect(value(o.interactiveArguments(target: .alias("web"), remoteCommand: nil)) == "ConnectTimeout=35")
        var shared = SSHOptions(useControlMaster: true)
        shared.connectTimeout = 35
        #expect(value(shared.masterArguments(target: .alias("web"), controlPath: "/tmp/x", logFile: nil, proxyCommand: nil)) == "ConnectTimeout=35")
        // A tab riding a prepared shared connection never connects by itself.
        shared.controlPath = "/tmp/x"
        #expect(value(shared.interactiveArguments(target: .alias("web"), remoteCommand: nil)) == nil)
    }

    @Test func theDefaultIsTwentySeconds() {
        #expect(SSHOptions().connectTimeout == 20)
        #expect(SSHOptions(settings: .init()).connectTimeout == 20)
    }
}
