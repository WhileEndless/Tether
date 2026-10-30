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

    /// Re-attaching: the session is reported gone only when tmux says so (it answers without the
    /// session, or no tmux server runs); a tmux that cannot be asked — another version after an
    /// upgrade, no tmux 3 at all — is "unreachable", and the tab is not ended for it.
    @Test func aSessionIsGoneOnlyWhenTmuxSaysSo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-bs-\(UUID())")
        let bin = dir.appendingPathComponent("bin"), empty = dir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A fake tmux 3.4 without the session; how `list-sessions` answers comes from $FAKE.
        let fake = """
        #!/bin/sh
        case "$1" in
          -V) echo "tmux 3.4" ;;
          has-session) exit 1 ;;
          list-sessions)
            case "$FAKE" in
              ok) echo "other: 1 windows"; exit 0 ;;
              noserver) echo "no server running on /tmp/tmux-0/default" >&2; exit 1 ;;
              nosocket) echo "error connecting to /tmp/tmux-0/default (No such file or directory)" >&2; exit 1 ;;
              mismatch) echo "protocol version mismatch (client 8, server 7); try again" >&2; exit 1 ;;
            esac ;;
          *) echo "UNEXPECTED $*"; exit 3 ;;
        esac
        """
        try fake.write(to: bin.appendingPathComponent("tmux"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("tmux").path)
        let command = RemoteBootstrap.command(mode: .tmux, sessionName: "tether-test", attachOnly: true)
        func marker(_ fakeMode: String, path: URL) -> RemoteBootstrap.Marker? {
            let r = BoundedProcess.run("/bin/sh", ["-c", command], environment: ["PATH": path.path + ":/usr/bin:/bin", "FAKE": fakeMode],
                                       timeout: 20)
            let text = r.output
            guard let start = text.range(of: "\u{1b}]7770;"), let end = text[start.upperBound...].firstIndex(of: "\u{07}") else { return nil }
            #expect(!text.contains("UNEXPECTED"), "\(text)")
            return RemoteBootstrap.Marker(payload: String(text[start.upperBound..<end]))
        }
        #expect(marker("ok", path: bin) == .gone)
        #expect(marker("noserver", path: bin) == .gone)
        #expect(marker("nosocket", path: bin) == .gone)
        guard case .unreachable(let why)? = marker("mismatch", path: bin) else { Issue.record("a version mismatch is not gone"); return }
        #expect(why.contains("protocol version mismatch") && !why.contains(";"), "\(why)")
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/tmux") || FileManager.default.isExecutableFile(atPath: "/bin/tmux") { return }
        guard case .unreachable? = marker("ok", path: empty) else { Issue.record("no tmux at all is not gone either"); return }
    }
}
