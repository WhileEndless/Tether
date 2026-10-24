import Foundation
import Testing
import TestSupport
@testable import MonitorKit

/// Runs the probe scripts with the local /bin/sh to catch shell syntax errors and check that
/// their output parses (the local machine stands in for a server).
@Suite struct ProbeScriptTests {
    /// Runs a script with `/bin/sh -s`; scripts that keep running (the stream) are stopped, with
    /// everything they started, after `seconds`.
    func run(_ script: String, _ args: [String], seconds: Double, environment: [String: String]? = nil) throws -> String {
        var env = environment ?? ProcessInfo.processInfo.environment
        env["TMUX"] = nil   // never the tmux server this test run may be inside
        let r = BoundedProcess.run("/bin/sh", ["-s", "--"] + args, environment: env, input: script + "\n", timeout: seconds)
        #expect(!r.errorOutput.contains("syntax error"), "stderr: \(r.errorOutput)")
        return r.output
    }

    @Test func streamProducesFrames() throws {
        let out = try run(ProbeScripts.systemStream, ["1"], seconds: 5)
        let frames = out.components(separatedBy: "@@end\n").filter { !$0.isEmpty }
        #expect(frames.count >= 2, "output: \(out.prefix(400))")
        let snap = ProbeParser.system(frames.first ?? "", previous: nil)
        #expect(!snap.hostname.isEmpty)
        #expect(snap.memTotal > 0)
        #expect(!snap.disks.isEmpty)
        #expect(!snap.interfaces.isEmpty)
        #expect(snap.osInfo["kernelbuild"] != nil)
        #expect(snap.osInfo["hardware"] != nil)
    }

    @Test func otherScriptsRun() throws {
        _ = try run(ProbeScripts.processes, [], seconds: 1)
        _ = try run(ProbeScripts.connections, [], seconds: 1)
        _ = try run(ProbeScripts.services, [], seconds: 2)
        _ = try run(ProbeScripts.containers, [], seconds: 1)
        _ = try run(ProbeScripts.gpuProcesses, [], seconds: 1)
        _ = try run(ProbeScripts.listening, [], seconds: 3)
    }

    /// tmux sessions on a private server (never the user's) show their panes' full command lines and the
    /// session names of fake coding agents, read from private stand-ins for their config folders.
    @Test func remoteSessionsReportPaneCommands() throws {
        guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        let fm = FileManager.default
        let made = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tether-pr-\(UUID().uuidString.prefix(6))")
        try fm.createDirectory(at: made, withIntermediateDirectories: true)
        // lsof and /proc report resolved paths (/private/var/… on macOS).
        let resolved = realpath(made.path, nil)
        let dir = URL(fileURLWithPath: resolved.map { String(cString: $0) } ?? made.path)
        free(resolved)
        defer { try? fm.removeItem(at: dir) }
        for sub in ["bin", "claude/sessions", "codex", "data/opencode", "app", "api", "docs"] {
            try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        func script(_ name: String, _ body: String) throws {
            let url = dir.appendingPathComponent("bin/\(name)")
            try ("#!/bin/sh\n" + body + "\nsleep 300\n").write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try script("claude", #"printf '{"pid":%s,"name":"Fix login","nameSource":"user","status":"idle","peerToken":"t"}' $$ > "$CLAUDE_CONFIG_DIR/sessions/$$.json""#)
        try script("codex", "")
        try script("opencode", "")
        let sqlite = fm.isExecutableFile(atPath: "/usr/bin/sqlite3")
        func sql(_ db: String, _ statements: String) {
            BoundedProcess.run("/usr/bin/sqlite3", [dir.appendingPathComponent(db).path, statements], timeout: 10)
        }
        if sqlite {
            sql("codex/state_5.sqlite", """
                CREATE TABLE threads(id TEXT, name TEXT, title TEXT, cwd TEXT, archived INT, updated_at INT);
                INSERT INTO threads VALUES('a', NULL, 'Old thread', '\(dir.path)/api', 0, 1), ('b', NULL, 'Refactor parser', '\(dir.path)/api', 0, 2);
                """)
            sql("data/opencode/opencode.db", """
                CREATE TABLE session(id TEXT, title TEXT, directory TEXT, parent_id TEXT, time_archived INT, time_updated INT);
                INSERT INTO session VALUES('ses_1', 'Write the changelog', '\(dir.path)/docs', NULL, NULL, 1);
                """)
        }
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "TMUX")
        env["TMUX_TMPDIR"] = dir.path
        env["CLAUDE_CONFIG_DIR"] = dir.appendingPathComponent("claude").path
        env["CODEX_HOME"] = dir.appendingPathComponent("codex").path
        env["XDG_DATA_HOME"] = dir.appendingPathComponent("data").path
        env["PATH"] = URL(fileURLWithPath: tmux).deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        func tmuxRun(_ args: [String]) {
            BoundedProcess.run(tmux, args, environment: env, timeout: 10)
        }
        defer { tmuxRun(["kill-server"]) }
        let bin = dir.appendingPathComponent("bin").path
        tmuxRun(["new-session", "-d", "-s", "probe", "-c", dir.path, "sleep 300"])
        tmuxRun(["new-session", "-d", "-s", "agents", "-c", dir.appendingPathComponent("app").path, "\(bin)/claude"])
        tmuxRun(["new-window", "-t", "agents", "-c", dir.appendingPathComponent("api").path, "\(bin)/codex"])
        tmuxRun(["new-window", "-t", "agents", "-c", dir.appendingPathComponent("docs").path, "\(bin)/opencode"])
        Thread.sleep(forTimeInterval: 0.8)
        let out = try run(ProbeScripts.remoteSessions, [], seconds: 20, environment: env)
        #expect(!out.contains("peerToken"))
        let sessions = ProbeParser.remoteSessions(out)
        let session = sessions.first { $0.name == "probe" }
        #expect(session != nil, "output: \(out.prefix(400))")
        #expect(session?.activePane?.command == "sleep")
        #expect(session?.activePane?.commandLine == "sleep 300")
        #expect(session?.activePane?.path == dir.path)
        let agents = sessions.first { $0.name == "agents" }?.panes.compactMap(\.agent) ?? []
        #expect(agents.map(\.kind) == [.claude, .codex, .opencode], "output: \(out.suffix(600))")
        #expect(agents.first?.sessionName == "Fix login" && agents.first?.namedByUser == true)
        if sqlite && agents.count == 3 {
            #expect(agents[1].sessionName == "Refactor parser")
            #expect(agents[2].sessionName == "Write the changelog")
        }
    }
}
