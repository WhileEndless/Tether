import Foundation
import Testing
import TetherCore
import TestSupport
@testable import SessionKit

/// Tabs closed here whose sessions go on running on the server are remembered (name and color
/// only), and whether a tab's session is still there is told apart from "could not ask". The
/// scripts run with the local shell against stand-in `tmux` and `screen` programs (never the real
/// ones: the PATH holds only the stand-ins, `grep` and /bin).
@Suite final class LeftOnServerTests {
    let folder: URL

    init() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tether-left-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    private func note(_ name: String, host: String = "example.com", title: String? = nil, ago: TimeInterval = 0) -> LeftSession {
        LeftSession(targetKey: host, name: name, persistence: .tmux, title: title, color: .blue, closedAt: Date().addingTimeInterval(-ago))
    }

    @MainActor @Test func notesAreKeptMatchedAndForgotten() {
        let store = JSONStore<[LeftSession]>(url: folder.appendingPathComponent("left.json"))
        let left = LeftOnServer(store: store)
        left.remember(note("tether-0000aaaa", title: "Build"))
        left.remember(note("tether-0000bbbb", host: "jump.example.com"))
        #expect(left.find("example.com", "tether-0000aaaa")?.title == "Build")
        #expect(left.find("jump.example.com", "tether-0000aaaa") == nil, "a note belongs to its host")
        // Noted again: one note, the newest.
        left.remember(note("tether-0000aaaa", title: "Deploy"))
        #expect(left.all.filter { $0.name == "tether-0000aaaa" }.count == 1)
        #expect(left.find("example.com", "tether-0000aaaa")?.title == "Deploy")
        left.forget("example.com", "tether-0000aaaa")
        #expect(left.find("example.com", "tether-0000aaaa") == nil)
        left.forgetAll(on: "jump.example.com")
        #expect(left.all.isEmpty)
    }

    @MainActor @Test func oldNotesGoAndThereAreNeverTooMany() {
        let many = (0..<(LeftOnServer.maxCount + 50)).map { note(String(format: "tether-%08x", $0), ago: Double($0)) }
        let old = note("tether-ffffffff", ago: LeftOnServer.maxAge + 60)
        let kept = LeftOnServer.pruned(many + [old], now: Date())
        #expect(kept.count == LeftOnServer.maxCount)
        #expect(!kept.contains { $0.name == old.name })
        #expect(kept.first?.name == "tether-00000000", "the newest first")
    }

    // MARK: Still there?

    /// Runs `script` with `name`, `tmux` / `screen` being stand-ins printing `output` and exiting
    /// with `status` (`has-session` exits with `hasSession`), and `ps` one listing `processes`.
    private func ask(_ script: String, program: String, hasSession: Int32 = 1, output: String, status: Int32,
                     processes: String = "sh", name: String = "tether-0000abcd") throws -> Int32 {
        let bin = folder.appendingPathComponent("bin-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        func tool(_ file: String, _ body: String) throws {
            let path = bin.appendingPathComponent(file)
            try ("#!/bin/sh\n" + body).write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }
        try tool(program, """
        [ "$1" = has-session ] && exit \(hasSession)
        [ "$1" = kill-session ] && exit 0
        [ "$1" = -S ] && exit 0
        cat <<'END'
        \(output)
        END
        exit \(status)
        """)
        try tool("ps", "printf '%s\\n' '\(processes)'\n")
        // Only the stand-ins and the tools the scripts use: macOS has a real `screen` in /usr/bin.
        let tools = folder.appendingPathComponent("tools")
        if !FileManager.default.fileExists(atPath: tools.path) {
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            for t in ["grep", "awk", "id"] {
                try FileManager.default.createSymbolicLink(atPath: tools.appendingPathComponent(t).path, withDestinationPath: "/usr/bin/" + t)
            }
        }
        let r = BoundedProcess.run("/bin/sh", ["-c", script, "sh", name],
                                   environment: ["PATH": bin.path + ":" + tools.path + ":/bin", "HOME": folder.path], timeout: 15)
        #expect(!r.timedOut)
        return r.status
    }

    @Test func tmuxGoneOnlyWhenTheServerSaysSo() throws {
        let s = TerminalSession.tmuxSessionThere
        #expect(try ask(s, program: "tmux", hasSession: 0, output: "", status: 0) == 0)
        #expect(try ask(s, program: "tmux", output: "work: 1 windows", status: 0) == 1, "a server without it")
        #expect(try ask(s, program: "tmux", output: "no server running on /tmp/tmux-1000/default", status: 1) == 1)
        #expect(try ask(s, program: "tmux", output: "error connecting to /tmp/tmux-1000/default (No such file or directory)", status: 1) == 1)
        // Could not tell: never "gone".
        #expect(try ask(s, program: "tmux", output: "error connecting to /tmp/tmux-1000/default (Permission denied)", status: 1) == 2)
        #expect(try ask(s, program: "tmux", output: "protocol version mismatch", status: 1) == 2)
        #expect(try ask(s, program: "not-tmux", output: "", status: 0) == 2, "no tmux on the PATH")
        // Its socket removed (a /tmp clean-up) while the tmux server runs on: out of reach, not gone.
        #expect(try ask(s, program: "tmux", output: "no server running on /tmp/tmux-1000/default", status: 1,
                        processes: "sh\ntmux: server") == 2)
    }

    @Test func screenGoneOnlyWhenItListed() throws {
        let s = TerminalSession.screenSessionThere
        #expect(try ask(s, program: "screen", output: "There is a screen on:\n\t123.tether-0000abcd\t(Detached)\n1 Socket in /run/screen/S-user.", status: 1) == 0)
        #expect(try ask(s, program: "screen", output: "There is a screen on:\n\t123.work\t(Detached)\n1 Socket in /run/screen/S-user.", status: 1) == 1)
        #expect(try ask(s, program: "screen", output: "No Sockets found in /run/screen/S-user.", status: 1) == 1)
        #expect(try ask(s, program: "screen", output: "Directory /run/screen must have mode 777.", status: 1) == 2)
        #expect(try ask(s, program: "not-screen", output: "", status: 0) == 2, "no screen on the PATH")
        // Names are compared as they are, not as patterns.
        let odd = #"we[ird].*\x"#
        #expect(try ask(s, program: "screen", output: "There is a screen on:\n\t123.\(odd)\t(Detached)\n1 Socket in /run/screen/S-user.",
                        status: 1, name: odd) == 0)
        #expect(try ask(s, program: "screen", output: "There is a screen on:\n\t123.weird-x\t(Detached)\n1 Socket in /run/screen/S-user.",
                        status: 1, name: odd) == 1)
        #expect(try ask(s, program: "screen", output: "There is a screen on:\n\t123.tether-0000abcd-2\t(Detached)\n1 Socket in /run/screen/S-user.",
                        status: 1) == 1, "another name that starts the same")
    }

    /// Ending a session counts only when it is gone afterwards, never when tmux or screen is missing.
    @Test func endingSaysWhetherItWorked() throws {
        #expect(try ask(TerminalSession.endTmuxSession, program: "tmux", hasSession: 1, output: "", status: 0) == 0)
        #expect(try ask(TerminalSession.endTmuxSession, program: "tmux", hasSession: 0, output: "", status: 0) == 1, "still there")
        #expect(try ask(TerminalSession.endTmuxSession, program: "not-tmux", output: "", status: 0) == 2)
        #expect(try ask(TerminalSession.endScreenSession, program: "screen", output: "No Sockets found in /run/screen/S-user.", status: 1) == 0)
        #expect(try ask(TerminalSession.endScreenSession, program: "not-screen", output: "", status: 0) == 2)
    }
}
