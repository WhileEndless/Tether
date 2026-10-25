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

    /// The command probe finds the processes below a shell and what they use. The tree runs inside
    /// the bounded shell, so it is stopped with it whatever happens.
    @Test func commandProbeReadsProcessTree() throws {
        let driver = """
        sh -c 'sleep 30 & yes >/dev/null & wait' &
        P=$!
        sleep 1
        sh -s -- pid "$P" <<'TETHER_PROBE'
        \(ProbeScripts.command)
        TETHER_PROBE
        # Children first: once the parent is gone they would belong to init and be missed.
        pkill -P $P 2>/dev/null
        kill $P 2>/dev/null
        true
        """
        let out = try run(driver, [], seconds: 10)
        let s = ProbeParser.sections(out)
        let root = try #require(s["root"]?.first.flatMap { Int($0) })
        let procs = s["procs"] ?? []
        #expect(procs.count == 3, "output: \(out.prefix(600))")
        // Without a terminal there is no foreground job: the parser sees an idle shell, not an error.
        let frame = ProbeParser.command(out, anchor: .posix(pid: root))
        #expect(frame.problem == nil)
        #expect(frame.shellPid == root)
        #expect(ProbeParser.command(try run(ProbeScripts.command, ["pid", "999999"], seconds: 5), anchor: .posix(pid: 999_999)).problem == .noShell)
    }

    /// Two terminals (shells in panes of a private tmux server, never the user's): one watcher says
    /// when a command starts and ends in either, and one look measures both. The watcher ends when
    /// it is stopped; nothing of it stays behind.
    @Test func watcherAndBatchedLookOnTwoShells() throws {
        guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("tether-w-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "TMUX")
        env["TMUX_TMPDIR"] = dir.path
        env["PATH"] = URL(fileURLWithPath: tmux).deletingLastPathComponent().path + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        defer { BoundedProcess.run(tmux, ["kill-server"], environment: env, timeout: 10) }
        let watch = dir.appendingPathComponent("watch.sh")
        let look = dir.appendingPathComponent("look.sh")
        try ProbeScripts.commandWatch.write(to: watch, atomically: true, encoding: .utf8)
        try ProbeScripts.command.write(to: look, atomically: true, encoding: .utf8)
        let driver = """
        tmux new-session -d -s a /bin/sh; tmux new-session -d -s b /bin/sh
        sleep 0.5
        A=$(tmux display -p -t a '#{pane_pid}'); B=$(tmux display -p -t b '#{pane_pid}')
        sh '\(watch.path)' -i 0.5 pid "$A" pid "$B" > '\(dir.path)/w.out' 2>&1 & W=$!
        sleep 1
        tmux send-keys -t b 'sleep 3' Enter
        sleep 1.5
        sh '\(look.path)' pid "$A" pid "$B" > '\(dir.path)/l.out' 2>&1
        sleep 3
        kill $W; sleep 0.3
        echo "@@watch"; cat '\(dir.path)/w.out'
        echo "@@left"; ps -A -o args= | grep -F 'sh \(watch.path)' | grep -v grep || true
        cat '\(dir.path)/l.out'
        """
        let out = try run(driver, [], seconds: 20, environment: env)
        let watched = ProbeParser.sections(out)["watch"] ?? []
        #expect(watched.contains("0 idle") && watched.contains("1 idle"), "output: \(out.prefix(800))")
        #expect(watched.contains { $0.hasPrefix("1 busy ") && $0.hasSuffix("sleep 3") })
        #expect(watched.filter { $0 == "1 idle" }.count == 2)   // idle, busy, idle again
        #expect((ProbeParser.sections(out)["left"] ?? []).isEmpty)
        let lookText = out.components(separatedBy: "@@now").dropFirst().joined(separator: "@@now")
        let frames = ProbeParser.commandBatch("@@now" + lookText, anchors: [.posix(pid: 1), .posix(pid: 2)])
        #expect(frames.count == 2)
        #expect(frames[0].problem == nil && frames[0].isIdle)
        #expect(frames[1].leader?.name == "sleep", "output: \(lookText.prefix(800))")
    }

    /// The traffic stream names its source first, then sends records until it is stopped.
    @Test func processTrafficStreams() throws {
        let out = try run(ProbeScripts.processTraffic, ["1"], seconds: 4)
        let records = out.components(separatedBy: "@@end\n").filter { !$0.isEmpty }
        #expect(records.first?.hasPrefix("@@source\n") == true, "output: \(out.prefix(300))")
        #expect(records.count >= 2)
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
