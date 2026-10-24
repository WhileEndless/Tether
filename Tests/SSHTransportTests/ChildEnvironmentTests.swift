import Foundation
import Testing
import TetherCore
@testable import SSHTransport

/// Programs Tether starts on this Mac find its tools (tmux from Homebrew) even when the app was
/// started from the Dock with launchd's minimal PATH, and never talk to an outer tmux server.
@Suite struct ChildEnvironmentTests {
    @Test func toolFoldersComeFirstOnce() {
        #expect(ChildEnvironment.withToolFolders("/usr/bin:/bin:/usr/sbin:/sbin")
                == "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(ChildEnvironment.withToolFolders("/usr/local/bin:/usr/bin") == "/opt/homebrew/bin:/opt/local/bin:/usr/local/bin:/usr/bin")
        #expect(ChildEnvironment.withToolFolders(nil).hasSuffix("/usr/bin:/bin:/usr/sbin:/sbin"))
    }

    @Test func localScriptsSeeTheToolFoldersAndNoOuterTmux() async {
        let r = await RemoteExecutor(target: .local, options: SSHOptions()).run(script: #"printf '%s|%s' "$PATH" "${TMUX-unset}""#)
        let parts = String(decoding: r.stdout, as: UTF8.self).split(separator: "|").map(String.init)
        #expect(parts.first?.split(separator: ":").contains("/opt/homebrew/bin") == true, "PATH: \(parts.first ?? "")")
        #expect(parts.last == "unset")
    }
}
