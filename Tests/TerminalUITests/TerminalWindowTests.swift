import AppKit
import SwiftUI
import Testing
import SwiftTerm
import SearchKit
import TetherCore
@testable import SessionKit
@testable import TerminalUI

/// Runs a real terminal view in an offscreen window against a local fake ssh, then inspects
/// the rendered screen. Reproduces layout/size problems that headless tests cannot.
@MainActor
@Suite(.serialized) struct TerminalWindowTests {
    let dir: URL
    let fakeSSH: URL

    init() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tether-ui-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fakeSSH = dir.appendingPathComponent("ssh")
        let script = """
        #!/bin/sh
        for a in "$@"; do case "$a" in -O) exit 1;; esac; done
        for last in "$@"; do :; done
        export TMUX_TMPDIR="\(dir.path)"
        unset TMUX
        export SHELL=/bin/sh PS1='$ '
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        exec /bin/sh -c "$last"
        """
        try script.write(to: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSSH.path)
        _ = NSApplication.shared
    }

    func config() -> SessionConfiguration {
        var s = AppSettings()
        s.sshBinary = fakeSSH.path
        s.useControlMaster = false
        s.recordingEnabled = false
        s.autoReconnect = false
        return SessionConfiguration(settings: s)
    }

    func pump(_ seconds: Double, until condition: () -> Bool = { false }) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !condition() {
            spinRunLoop()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Lets AppKit lay out and draw (synchronous wrapper so it can be used from async tests).
    func spinRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    func screen(_ view: TerminalView) -> [String] {
        let t = view.getTerminal()
        return (0..<t.rows).map { row in
            guard let line = t.getLine(row: row) else { return "" }
            return line.translateToString(trimRight: true)
        }
    }

    func run(mode: PersistenceMode) async throws -> (cols: Int, rows: Int, remoteCols: String, screen: [String]) {
        let cfg = config()
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("local"), persistence: mode)) { cfg }
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1100, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: TerminalHost(session: session))
        window.contentView = host
        window.alphaValue = 0
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try await pump(0.3)
        session.start()
        try await pump(10) { session.phase.isOnline }
        #expect(session.phase.isOnline)
        try await pump(0.5)
        // Simulate switching tabs: the view is re-hosted in a fresh (initially zero-sized) container.
        let host2 = NSHostingView(rootView: TerminalHost(session: session))
        window.contentView = host2
        host2.layoutSubtreeIfNeeded()
        try await pump(1)
        session.send(Array("clear; stty size; ls /bin\r".utf8)[...])
        try await pump(2)
        let view = TerminalRegistry.shared.existingView(for: session.id)!
        let lines = screen(view)
        let sizeLine = lines.first { $0.range(of: #"^\d+ \d+$"#, options: .regularExpression) != nil } ?? "?"
        // Ctrl+L must leave the prompt on the first row.
        session.send(Array("printf 'a\\nb\\nc\\n'\r".utf8)[...])
        try await pump(0.5)
        session.send([0x0c][...])
        try await pump(1)
        let afterClear = screen(view)
        #expect(afterClear.first?.hasPrefix("$") == true || afterClear.first?.contains("$") == true,
                "after Ctrl+L the prompt should be on top, got: \(afterClear.prefix(3))")
        session.close(killRemote: true)
        window.orderOut(nil)
        killTmuxServer()
        return (view.getTerminal().cols, view.getTerminal().rows, sizeLine, lines)
    }

    @Test func plainShellSizeMatchesView() async throws {
        let r = try await run(mode: .off)
        print("PLAIN cols=\(r.cols) remote=\(r.remoteCols)\n" + r.screen.joined(separator: "\n"))
        #expect(r.remoteCols == "\(r.rows) \(r.cols)", "remote size must match the view exactly")
    }

    @Test func tmuxSizeMatchesView() async throws {
        let r = try await run(mode: .tmux)
        print("TMUX cols=\(r.cols) remote=\(r.remoteCols)\n" + r.screen.joined(separator: "\n"))
        #expect(r.remoteCols == "\(r.rows) \(r.cols)", "remote size must match the view exactly")
    }

    @Test func shiftCommandUpSelectsWholeCommands() async throws {
        let cfg = config()
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("local"), persistence: .tmux)) { cfg }
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: TerminalHost(session: session))
        window.contentView = host
        window.alphaValue = 0
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try await pump(0.3)
        session.start()
        try await pump(10) { session.phase.isOnline }
        let view = TerminalRegistry.shared.existingView(for: session.id)!
        for cmd in ["echo one", "echo two; echo 2b", "echo three"] {
            view.send(source: view, data: Array((cmd + "\r").utf8)[...])
            try await pump(0.6)
        }
        view.selectToMark(up: true)
        let last = view.getSelection()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(last.hasSuffix("echo three\nthree"), "got: \(last)")
        view.selectToMark(up: true)
        let two = view.getSelection()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(two.contains("echo two; echo 2b\ntwo\n2b") && two.hasSuffix("three"), "got: \(two)")
        // ⌘↑ twice jumps to "echo two"; ⇧⌘↓ selects that command, again extends to the next one.
        view.jumpToMark(up: true)
        view.jumpToMark(up: true)
        view.selectToMark(up: false)
        let jumped = view.getSelection()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(jumped.hasSuffix("echo two; echo 2b\ntwo\n2b") && !jumped.contains("three"), "got: \(jumped)")
        view.selectToMark(up: false)
        let extended = view.getSelection()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        #expect(extended.contains("2b") && extended.hasSuffix("echo three\nthree"), "got: \(extended)")
        session.close(killRemote: true)
        window.orderOut(nil)
        killTmuxServer()
    }

    /// Stops this suite's private tmux server.
    func killTmuxServer() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["tmux", "kill-server"]
        var env = ProcessInfo.processInfo.environment
        env["TMUX_TMPDIR"] = dir.path
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        p.environment = env
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    /// Long sessions: only the newest lines stay in memory, the rest is searched in the recording,
    /// and nothing is reported twice.
    @Test func searchCoversTrimmedHistoryWithoutDuplicates() async throws {
        setenv("TETHER_SUPPORT_DIR", dir.appendingPathComponent("support").path, 1)
        var settings = AppSettings()
        settings.sshBinary = fakeSSH.path
        settings.useControlMaster = false
        settings.recordingEnabled = true
        settings.scrollbackLines = 1000
        SettingsStore.shared.settings = settings
        let cfg = SessionConfiguration(settings: settings)
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("local"), persistence: .off)) { cfg }
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: TerminalHost(session: session))
        window.contentView = host
        window.alphaValue = 0
        window.orderFrontRegardless()
        try await pump(0.3)
        session.start()
        try await pump(10) { session.phase.isOnline }
        let view = TerminalRegistry.shared.existingView(for: session.id)!
        session.send(Array("i=0; while [ $i -lt 3000 ]; do echo row-$i; i=$((i+1)); done\r".utf8)[...])
        try await pump(15) { view.scrollbackText().lines.contains { $0 == "row-2999" } }
        let (base, lines, logical) = view.scrollbackText()
        #expect(base > 0, "old lines should have been dropped from memory")
        let url = try #require(session.recordingURL)
        try await pump(1.5)   // let the recorder flush
        var earlier = SearchSource(id: "e", kind: .recording(url: url, archiveID: nil), title: "e", host: "h", date: nil, status: "")
        earlier.skipTrailingLines = logical
        let live = SearchSource(id: "l", kind: .live(sessionID: session.id, lineBase: base), title: "l", host: "h",
                                date: nil, status: "", lines: lines)
        var q = SearchQuery(pattern: #"^row-(5|2999)$"#)
        q.isRegex = true
        var found: [String: [String]] = [:]
        for try await p in SearchEngine.search(q, in: [earlier, live]) { found[p.source.id, default: []] += p.matches.map(\.text) }
        #expect(found["e"] == ["row-5"], "got \(found)")
        #expect(found["l"] == ["row-2999"], "got \(found)")
        session.close(killRemote: true)
        window.orderOut(nil)
        unsetenv("TETHER_SUPPORT_DIR")
    }
}
