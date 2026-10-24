import Foundation
import Testing
import TestSupport
@testable import SessionKit

@Suite struct RemoteBootstrapTests {
    /// Runs the bootstrap with a fake `screen` (and no tmux) that reports the settings file it got.
    @Test func screenSettingsFileIsPrivateAndNeverPlanted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-bs-\(UUID())")
        let bin = dir.appendingPathComponent("bin"), tmp = dir.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // What an attacker would plant under the old fixed name.
        try "screen sh -c 'echo PLANTED'\n".write(to: tmp.appendingPathComponent(".tether-screenrc-\(getuid())"), atomically: true, encoding: .utf8)
        let fake = """
        #!/bin/sh
        if [ "$1" = -ls ]; then exit 1; fi
        if [ "$1" = -c ]; then echo "RC=$2 MODE=$(stat -f %Lp "$2") $(grep -c defscrollback "$2")"; cat "$2"; fi
        """
        try fake.write(to: bin.appendingPathComponent("screen"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("screen").path)

        let command = RemoteBootstrap.command(mode: .screen, sessionName: "tether-test", attachOnly: false, historyLimit: 50_000)
        let r = BoundedProcess.run("/bin/sh", ["-c", command], environment: ["PATH": bin.path + ":/usr/bin:/bin", "TMPDIR": tmp.path],
                                   timeout: 20)
        let text = r.output + r.errorOutput
        #expect(text.contains("MODE=600 1"), "output: \(text)")
        #expect(text.contains("defscrollback 50000"))
        #expect(!text.contains("PLANTED"))
        #expect(!text.contains(".tether-screenrc-\(getuid())"))
    }
}
