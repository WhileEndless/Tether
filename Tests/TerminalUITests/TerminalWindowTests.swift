import AppKit
import SwiftUI
import Testing
import TestSupport
import SwiftTerm
import SearchKit
import TetherCore
@testable import SessionKit
@testable import TerminalUI

/// Runs a real terminal view in an offscreen window against a local fake ssh, then inspects
/// the rendered screen. Reproduces layout/size problems that headless tests cannot.
@MainActor
@Suite(.serialized) final class TerminalWindowTests {
    let dir: URL
    let fakeSSH: URL

    /// Each test leaves nothing behind: its tmux server and its folder (with the fake ssh) go.
    deinit {
        PrivateTmux.killServer(in: dir)     // by its socket: never the user's server
        try? FileManager.default.removeItem(at: dir)
    }

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
        view.sendsAreTyping = true        // the test types as the user would
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
        view.sendsAreTyping = true        // the test types as the user would
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

        // ⌘↓ past the last command stops on the line being typed on, and the flash covers that row:
        // rows are drawn at the font's height from the top (the view is a little taller than them).
        view.selection.selectNone()
        view.jumpToMark(up: true)
        for _ in 0..<3 { view.jumpToMark(up: false) }
        #expect(view.jumpCursor == nil)
        let t = view.getTerminal()
        let cell = view.caretFrame.size.height
        let flash = try #require(view.layer?.sublayers?.last { $0.cornerRadius == 3 })
        let v = CGFloat(t.getCursorLocation().y)
        #expect(cell > 0 && view.bounds.height - CGFloat(t.rows) * cell >= 0)
        #expect(abs(flash.frame.minY - (view.bounds.maxY - (v + 1) * cell)) < 0.5, "on the prompt's row: \(flash.frame) cell \(cell)")
        #expect(abs(flash.frame.height - cell) < 0.5)
        session.close(killRemote: true)
        window.orderOut(nil)
        killTmuxServer()
    }

    /// After a re-attach that could not find its place (tmux's history was cleared meanwhile, so
    /// everything it kept is added under a note), ⌘↑ from the prompt goes to the commands run since
    /// and then to those before — always onto a command's line.
    @Test func commandMarksStayOnTheirLinesAfterAReattachAddsOutput() async throws {
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
        view.sendsAreTyping = true
        func run(_ cmd: String) async throws {
            view.send(source: view, data: Array((cmd + "\r").utf8)[...])
            try await pump(0.6)
        }
        func rowText(_ row: Int) -> String {
            view.getTerminal().getLine(row: row - view.getTerminal().getTopVisibleRow())?.translateToString(trimRight: true) ?? ""
        }
        func jumped() -> String { view.jumpCursor.map(rowText) ?? "-" }
        try await run("echo before-one")
        try await run("echo before-two")
        // Away: the tab lets go of tmux; meanwhile the session's history is cleared and more is printed.
        session.prepareForSleep()
        try await pump(5) { !session.phase.isOnline }
        let name = session.descriptor.remoteSessionName
        _ = BoundedProcess.run("/bin/sh", ["-c", "TMUX= TMUX_TMPDIR=\"$0\" tmux send-keys -t \"$1\" 'clear; tmux clear-history; echo away-1; echo away-2' Enter",
                                           dir.path, name],
                               environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"], timeout: 5)
        try await pump(1)
        // Typed while away: sent once the tab is back, and marked as a command then.
        view.send(source: view, data: Array("echo typed-away\r".utf8)[...])
        session.restartAttempt()
        try await pump(10) { session.phase.isOnline }
        try await pump(1)
        try await run("echo after-one")
        try await run("echo after-two")
        // tmux's own words as the tab let go of it are not output.
        #expect(!view.scrollbackText().lines.contains { $0.contains("%exit") })
        view.jumpToMark(up: true)
        #expect(jumped().hasSuffix("echo after-two"), "the last command (\(jumped()))")
        view.jumpToMark(up: true)
        #expect(jumped().hasSuffix("echo after-one"), "then the one before (\(jumped()))")
        view.jumpToMark(up: true)
        #expect(jumped().hasSuffix("echo typed-away"), "then the one typed while away (\(jumped()))")
        view.jumpToMark(up: true)
        #expect(jumped().contains("before-two") || jumped().contains("clear;"), "then those before the re-attach (\(jumped()))")
        session.close(killRemote: true)
        window.orderOut(nil)
    }

    /// Tether quit and opened again: the tab shows its earlier output from the recording, re-attaches
    /// (here after tmux's history was cleared, so everything it kept is added under a note), and
    /// ⌘↑ from the prompt goes to the commands — onto their lines, whether they are in memory or
    /// only in the recording.
    @Test func commandsOfARestoredTabAreJumpedToOnTheirLines() async throws {
        setenv("TETHER_SUPPORT_DIR", dir.appendingPathComponent("support").path, 1)
        defer { unsetenv("TETHER_SUPPORT_DIR") }
        var settings = AppSettings()
        settings.sshBinary = fakeSSH.path
        settings.useControlMaster = false
        settings.recordingEnabled = true
        settings.autoReconnect = false
        SettingsStore.shared.settings = settings
        let cfg = SessionConfiguration(settings: settings)
        let descriptor = SessionDescriptor(target: .alias("local"), persistence: .tmux)
        func open(_ session: TerminalSession) async throws -> (TetherTerminalView, NSWindow) {
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 500),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: TerminalHost(session: session))
            window.contentView = host
            window.alphaValue = 0
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            try await pump(0.3)
            let view = TerminalRegistry.shared.existingView(for: session.id)!
            view.sendsAreTyping = true
            return (view, window)
        }
        let first = TerminalSession(descriptor: descriptor) { cfg }
        let (v1, w1) = try await open(first)
        first.start()
        try await pump(10) { first.phase.isOnline }
        for cmd in ["echo before-one", "echo before-two"] {
            v1.send(source: v1, data: Array((cmd + "\r").utf8)[...])
            try await pump(0.7)
        }
        let url = try #require(first.recordingURL)
        first.abandon()                   // Tether quits; the session goes on on the server
        w1.orderOut(nil)
        TerminalRegistry.shared.remove(first.id)
        try await pump(0.5)
        _ = BoundedProcess.run("/bin/sh", ["-c", "TMUX= TMUX_TMPDIR=\"$0\" tmux send-keys -t \"$1\" 'clear; tmux clear-history; echo away-1' Enter",
                                           dir.path, descriptor.remoteSessionName],
                               environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"], timeout: 5)
        try await pump(1)

        let second = TerminalSession(descriptor: descriptor) { cfg }
        let (view, w2) = try await open(second)
        defer { w2.orderOut(nil) }
        var ready = false
        second.continueRecording(url) { ready = true }
        try await pump(5) { ready }
        second.restore(previous: .tmux)
        try await pump(10) { second.phase.isOnline }
        try await pump(1)
        func shownLine() -> String {
            if view.isBrowsingHistory, let h = view.history {
                let t = h.getTerminal()
                let rows = (0..<t.rows).compactMap { t.getLine(row: $0)?.translateToString(trimRight: true) }
                return "history: " + rows.prefix(4).joined(separator: " | ")
            }
            return view.jumpCursor.map { view.getTerminal().getLine(row: $0 - view.getTerminal().getTopVisibleRow())?.translateToString(trimRight: true) ?? "?" } ?? "-"
        }
        // The commands are on screen (shown again from the recording): jumped to there, on their lines.
        view.jumpToMark(up: true)
        try await pump(2) { view.history?.loading != true }
        #expect(!view.isBrowsingHistory, "in memory, not the recording (\(shownLine()))")
        #expect(shownLine().hasSuffix("echo before-two"), "the last command (\(shownLine()))")
        view.jumpToMark(up: true)
        try await pump(2) { view.history?.loading != true }
        #expect(shownLine().hasSuffix("echo before-one"), "the one before (\(shownLine()))")
        // A command run now comes first.
        view.send(source: view, data: Array("echo after-one\r".utf8)[...])
        // Until the shell has printed it (a fixed wait is too short on a busy Mac).
        try await pump(10) { view.scrollbackText().lines.contains { $0.hasSuffix("echo after-one") } }
        try await pump(0.3)
        view.jumpToMark(up: true)
        #expect(shownLine().hasSuffix("echo after-one"), "the new command (\(shownLine()))")
        view.jumpToMark(up: true)
        #expect(shownLine().hasSuffix("echo before-two"), "then the earlier ones (\(shownLine()))")
        second.close(killRemote: true)
    }

    /// Ctrl+L moves the screen into the scrollback; ⇧⌘↑ and ⌘↑ must still reach the commands before it.
    @Test func commandMarksSurviveCtrlL() async throws {
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
        view.sendsAreTyping = true        // the test types as the user would
        for cmd in ["echo one", "echo two"] {
            view.send(source: view, data: Array((cmd + "\r").utf8)[...])
            try await pump(0.6)
        }
        view.send(source: view, data: [0x0c][...])          // Ctrl+L
        try await pump(0.8)
        view.send(source: view, data: Array("echo three\r".utf8)[...])
        try await pump(0.6)
        var seen: [String] = []
        for _ in 0..<3 {
            view.selectToMark(up: true)
            seen.append(view.getSelection()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }
        #expect(seen[0].hasSuffix("echo three\nthree"), "got: \(seen)")
        #expect(seen.last?.contains("echo one") == true && seen.last?.contains("echo two") == true, "got: \(seen)")
        // ⌘↑ walks back past the clear too.
        view.selection.selectNone()
        view.jumpCursor = nil
        var jumps: [String] = []
        for _ in 0..<3 {
            view.jumpToMark(up: true)
            if let row = view.jumpCursor, let line = view.getTerminal().getLine(row: row - view.getTerminal().getTopVisibleRow()) {
                jumps.append(line.translateToString(trimRight: true))
            }
        }
        #expect(jumps.contains { $0.contains("echo one") }, "jumps: \(jumps)")
        session.close(killRemote: true)
        window.orderOut(nil)
        killTmuxServer()
    }

    /// The foreground process is read with its real user and arguments (what tells sudo's caller and
    /// su's target user apart when a prompt only says "Password:").
    @Test func readsTheForegroundProcess() async throws {
        // A local session: give it this suite's private tmux server, never the user's.
        setenv("TMUX_TMPDIR", dir.path, 1)
        defer { unsetenv("TMUX_TMPDIR") }
        let cfg = config()
        let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .tmux)) { cfg }
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
        session.send(Array("sleep 7\r".utf8)[...])
        try await pump(1.0)
        let p = await session.foregroundProcess()
        #expect(p?.command == "sleep" && p?.user == NSUserName() && p?.arguments == ["7"], "got: \(String(describing: p))")
        session.close(killRemote: true)
        window.orderOut(nil)
        killTmuxServer()
    }

    /// Stops this suite's private tmux server.
    func killTmuxServer() {
        PrivateTmux.killServer(in: dir)
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
        view.sendsAreTyping = true        // the test types as the user would
        session.send(Array("i=0; while [ $i -lt 3000 ]; do echo row-$i; i=$((i+1)); done\r".utf8)[...])
        try await pump(15) { view.scrollbackText().lines.contains { $0 == "row-2999" } }
        let (base, lines, logical) = view.scrollbackText()
        #expect(base > 0, "old lines should have been dropped from memory")
        let url = try #require(session.flushedRecordingURL())   // writes out the batched output
        var earlier = SearchSource(id: "e", kind: .recording(url: url, archiveID: nil), title: "e", host: "h", date: nil, status: "")
        // As the search does: the seam is found by the first logical lines in memory.
        let memory = view.logicalText().lines
        earlier.skipTrailingLines = memory.count
        earlier.memoryHead = Array(memory.prefix(64))
        _ = logical
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

    /// Scrolling up past what is in memory keeps going into the recording, as the user does it:
    /// wheel steps up to the top, and on.
    @Test func scrollingUpReadsEarlierOutputFromTheRecording() async throws {
        setenv("TETHER_SUPPORT_DIR", dir.appendingPathComponent("support").path, 1)
        defer { unsetenv("TETHER_SUPPORT_DIR") }
        var settings = AppSettings()
        settings.sshBinary = fakeSSH.path
        settings.useControlMaster = false
        settings.recordingEnabled = true
        settings.scrollbackLines = 2000
        SettingsStore.shared.settings = settings
        let cfg = SessionConfiguration(settings: settings)
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("local"), persistence: .off)) { cfg }
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: TerminalHost(session: session))
        window.alphaValue = 0
        window.orderFrontRegardless()
        try await pump(0.3)
        session.start()
        try await pump(10) { session.phase.isOnline }
        let view = TerminalRegistry.shared.existingView(for: session.id)!
        view.sendsAreTyping = true        // the test types as the user would
        session.send(Array("i=1; while [ $i -le 9000 ]; do echo $i; i=$((i+1)); done\r".utf8)[...])
        try await pump(20) { view.scrollbackText().lines.contains { $0 == "9000" } }
        func top() -> Int {
            let t = view.displayedTerminal.getTerminal()
            for r in 0..<t.rows {
                if let n = Int(t.getLine(row: r)?.translateToString(trimRight: true).trimmingCharacters(in: .whitespaces) ?? "") { return n }
            }
            return -1
        }
        // Wheel steps up, with time between them as a hand gives.
        var lowest = Int.max
        for _ in 0..<400 {
            view.displayedTerminal.scrollUp(lines: 40)
            view.requestOlderHistory()
            try await pump(0.02)
            lowest = min(lowest, top())
            if lowest == 1 { break }
        }
        print("SCROLL lowest line reached: \(lowest)")
        #expect(lowest < 9000 - 2000 - 500, "scrolling stopped at the memory limit (\(lowest))")

        // Back down (memory shrinks again), then up to the top while no load can start (as with
        // the scroller held by the mouse): further steps up at the top still bring it in.
        view.returnToLive()
        try await pump(0.3)
        #expect(!view.isBrowsingHistory)
        let reader = view.historyReader
        view.historyReader = nil
        for _ in 0..<200 where view.getTerminal().buffer.yDisp > 0 { view.scrollUp(lines: 200) }
        try await pump(0.3)
        let stuck = top()
        #expect(stuck > 9000 - 2000 - 100, "nothing loaded without a reader (\(stuck))")
        view.historyReader = reader
        view.displayedTerminal.scrollUp(lines: 5)                // at the top: SwiftTerm reports nothing
        view.requestOlderHistory()             // what the wheel watcher does for each step up
        // The line looked at stays put while earlier output comes in above it; scrolling goes on.
        var reached = stuck
        for _ in 0..<100 where reached >= stuck - 1000 {
            try await pump(0.05)
            view.displayedTerminal.scrollUp(lines: 40)
            view.requestOlderHistory()
            reached = min(reached, top())
        }
        #expect(reached < stuck - 1000, "a later step up loaded nothing (\(reached))")

        // Past as much as a terminal may hold: scrolling goes on, through the recording.
        view.returnToLive()
        view.discardHistory()
        try await pump(0.3)
        view.historyMaxLines = 4000
        var lowest2 = Int.max
        for _ in 0..<300 where lowest2 > 1 {
            view.displayedTerminal.scrollUp(lines: 200)
            view.requestOlderHistory()
            try await pump(0.05)
            lowest2 = min(lowest2, top())
        }
        #expect(lowest2 == 1, "the first line is reached past the memory limit (\(lowest2))")
        #expect((view.history?.bufferRows ?? 0) <= 4000 + 1200)
        view.returnToLive()
        #expect(!view.isBrowsingHistory)
        session.close(killRemote: true)
        window.orderOut(nil)
    }

    /// A session far longer than a terminal holds at once scrolls through whole, both ways: the
    /// view moves through the recording a chunk at a time, never jumps, and memory stays bounded.
    @Test func scrollingThroughALongSessionMovesThroughTheRecording() async throws {
        setenv("TETHER_SUPPORT_DIR", dir.appendingPathComponent("support").path, 1)
        defer { unsetenv("TETHER_SUPPORT_DIR") }
        var settings = AppSettings()
        settings.sshBinary = fakeSSH.path
        settings.useControlMaster = false
        settings.recordingEnabled = true
        settings.scrollbackLines = 2000
        SettingsStore.shared.settings = settings
        let cfg = SessionConfiguration(settings: settings)
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("local"), persistence: .off)) { cfg }
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: TerminalHost(session: session))
        window.alphaValue = 0
        window.orderFrontRegardless()
        try await pump(0.3)
        session.start()
        try await pump(10) { session.phase.isOnline }
        let view = TerminalRegistry.shared.existingView(for: session.id)!
        view.sendsAreTyping = true        // the test types as the user would
        view.historyMaxLines = 5000
        view.historyChunkLines = 2000
        let total = 30_000
        let made = Date()
        session.send(Array("seq 1 \(total)\r".utf8)[...])
        try await pump(60) { view.scrollbackText().lines.contains { $0 == "\(total)" } }
        print("SLIDE output took \(Date().timeIntervalSince(made))")
        var slides = 0, slideTime = 0.0, slideStart = Date()
        view.onHistoryLoaded = { _ in slides += 1; slideTime += Date().timeIntervalSince(slideStart) }
        func top() -> Int {
            let t = view.displayedTerminal.getTerminal()
            for r in 0..<t.rows {
                if let n = Int(t.getLine(row: r)?.translateToString(trimRight: true).trimmingCharacters(in: .whitespaces) ?? "") { return n }
            }
            return -1
        }
        // Up to the very first line, a few lines per step; each step moves by about that much.
        var previous = top(), largestJump = 0, mostLines = 0
        let upStart = Date()
        for _ in 0..<5000 {
            view.displayedTerminal.scrollUp(lines: 80)
            slideStart = Date()
            view.requestOlderHistory()
            try await pump(0.01)
            let now = top()
            largestJump = max(largestJump, abs(previous - now))
            previous = now
            mostLines = max(mostLines, view.history?.bufferRows ?? view.bufferLineCount)
            if now == 1 { break }
        }
        print("SLIDE up took \(Date().timeIntervalSince(upStart)) s, \(slides) loads, \(slideTime / Double(max(slides, 1))) s each")
        #expect(previous == 1, "reached the first line (stopped at \(previous))")
        #expect(view.isBrowsingHistory)
        #expect(largestJump <= 160, "no jumps while scrolling up (largest \(largestJump))")
        #expect(mostLines <= 5000 + 1300, "memory stayed bounded (\(mostLines) rows)")

        // And down again to the live end.
        previous = top(); largestJump = 0
        slides = 0; slideTime = 0
        var failed = 0
        view.onHistoryLoaded = { ok in slides += 1; if !ok { failed += 1 } }
        let downStart = Date()
        var steps = 0
        for _ in 0..<5000 where view.isBrowsingHistory || top() < total - view.getTerminal().rows - 5 {
            steps += 1
            view.displayedTerminal.scrollDown(lines: 80)
            view.requestNewerHistory()
            try await pump(0.01)
            let now = top()
            largestJump = max(largestJump, abs(now - previous))
            previous = now
        }
        print("SLIDE down took \(Date().timeIntervalSince(downStart)) s, \(steps) steps, \(slides) loads, \(failed) given up, top \(top())")
        #expect(!view.isBrowsingHistory, "back at the live end")
        #expect(largestJump <= 160, "no jumps while scrolling down (largest \(largestJump))")
        #expect(view.scrollbackText().lines.contains("\(total)"))

        // A search result far back in the recording opens in the terminal, at that line.
        let url = try #require(session.flushedRecordingURL())
        var offset: Int?
        try SearchEngine.forEachLine(url) { line, at in
            if line == "1234" { offset = at; return false }
            return true
        }
        let found = try #require(offset)
        let row = await withCheckedContinuation { done in
            view.showRecording(at: max(found - SearchEngine.offsetPiece, 0)) { done.resume(returning: $0) }
        }
        #expect(view.isBrowsingHistory)
        let t = view.displayedTerminal.getTerminal()
        var rowOf1234: Int?
        for r in row..<(row + 3000) where t.getScrollInvariantLine(row: r)?.translateToString(trimRight: true) == "1234" { rowOf1234 = r; break }
        #expect(rowOf1234 != nil, "the line is in the terminal, after where the find starts")
        view.returnToLive()
        try await pump(5) { !view.isBrowsingHistory }

        // The scroller stands for the whole session: dragged to a line, it shows that line.
        view.updateHistoryScroller()
        #expect(view.historyScroller.total >= total, "the scroller holds every line (\(view.historyScroller.total))")
        for target in [5_000, 17_000, 2_000] {
            view.scrollHistory(toLine: target)
            try await pump(5) { view.isBrowsingHistory && view.history?.loading == false && abs(top() - target) < 20 }
            #expect(abs(top() - target) < 20, "dragged to \(target), shows \(top())")
        }
        // Dragged into what is in memory: the live terminal.
        view.scrollHistory(toLine: view.historyScroller.total - 30)
        try await pump(2) { !view.isBrowsingHistory }
        #expect(!view.isBrowsingHistory)

        // Scrolled back far, then typing: the live end at once.
        for _ in 0..<400 where !view.isBrowsingHistory {
            view.displayedTerminal.scrollUp(lines: 200)
            view.requestOlderHistory()
            try await pump(0.02)
        }
        #expect(view.isBrowsingHistory)
        view.sendsAreTyping = true
        view.send(source: view, data: Array("echo after-browsing\r".utf8)[...])
        try await pump(5) { view.scrollbackText().lines.contains("after-browsing") }
        #expect(!view.isBrowsingHistory)
        #expect(view.scrollbackText().lines.contains("after-browsing"))
        session.close(killRemote: true)
        window.orderOut(nil)
    }

    /// ⌘↑ lands on the command's own line (the prompt and what was typed), also after the window
    /// was made narrower or wider (lines wrap differently then), and the place being looked at stays.
    @Test func commandMarksAndThePlaceLookedAtSurviveResizing() async throws {
        setenv("TETHER_SUPPORT_DIR", dir.appendingPathComponent("support").path, 1)
        defer { unsetenv("TETHER_SUPPORT_DIR") }
        var settings = AppSettings()
        settings.sshBinary = fakeSSH.path
        settings.useControlMaster = false
        settings.recordingEnabled = true
        SettingsStore.shared.settings = settings
        let cfg = SessionConfiguration(settings: settings)
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("local"), persistence: .off)) { cfg }
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: TerminalHost(session: session))
        window.alphaValue = 0
        window.orderFrontRegardless()
        try await pump(0.3)
        session.start()
        try await pump(10) { session.phase.isOnline }
        let view = TerminalRegistry.shared.existingView(for: session.id)!
        view.sendsAreTyping = true
        func type(_ text: String) { view.send(source: view, data: Array(text.utf8)[...]) }
        // Long lines that wrap differently at another width, then a command, then more output.
        type("i=0; while [ $i -lt 40 ]; do printf '%0200d\\n' $i; i=$((i+1)); done\r")
        try await pump(10) { view.scrollbackText().lines.contains { $0.hasSuffix("39") && $0.count > 150 } }
        type("echo the-command-line\r")
        try await pump(5) { view.scrollbackText().lines.contains("the-command-line") }
        type("i=0; while [ $i -lt 30 ]; do echo after-$i; i=$((i+1)); done\r")
        try await pump(5) { view.scrollbackText().lines.contains("after-29") }
        try await pump(0.3)
        func markedLine() -> String {
            guard let row = view.jumpCursor else { return "" }
            return view.getTerminal().getLine(row: row - view.getTerminal().getTopVisibleRow())?.translateToString(trimRight: true) ?? ""
        }
        view.jumpToMark(up: true)       // the loop's command
        view.jumpToMark(up: true)       // echo the-command-line
        #expect(markedLine().contains("echo the-command-line"), "⌘↑ shows the command's line (\(markedLine()))")
        for width in [520.0, 1300.0, 700.0] {
            view.jumpCursor = nil
            window.setContentSize(NSSize(width: width, height: 500))
            try await pump(0.5)
            view.scrollToBottom()           // from the prompt: the loop's command, then the one before
            view.jumpToMark(up: true)
            view.jumpToMark(up: true)
            #expect(markedLine().contains("echo the-command-line"), "at \(width) pt wide (\(markedLine()))")
        }
        // Scrolled to a line, then resized: that line is still the one at the top.
        view.scrollTo(row: 3)
        let top = view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true) ?? ""
        window.setContentSize(NSSize(width: 600, height: 500))
        try await pump(0.5)
        let after = view.getTerminal().getLine(row: 0)?.translateToString(trimRight: true) ?? ""
        #expect(!top.isEmpty && (after.hasPrefix(String(top.prefix(10))) || top.hasPrefix(String(after.prefix(10)))),
                "the line looked at stays at the top (\(top.prefix(20)) → \(after.prefix(20)))")
        session.close(killRemote: true)
        window.orderOut(nil)
    }
}
