#if DEBUG
import AppKit
import SwiftUI
import TetherCore
import SessionKit
import KeySetupKit
import SearchKit
import RecordingKit
import SSHTransport
import TerminalUI
import FileTransferKit

/// Debug-only scripted UI run used to reproduce window/tab problems without a person at the keyboard.
/// Enabled with TETHER_SELFTEST=<log file> and TETHER_SSH_BINARY=<fake ssh>; always combine with
/// TETHER_SUPPORT_DIR and TETHER_DEFAULTS_SUITE so real user data is never touched.
@MainActor
enum SelfTest {
    private static var started = false

    /// A terminal's row in the sidebar and where it is (window coordinates, top-left origin).
    static func sidebarRow(in window: NSWindow, workspace: UUID) -> (UUID, CGRect)? {
        guard let content = window.contentView else { return nil }
        func search(_ view: NSView) -> (UUID, CGRect)? {
            if let m = view as? SidebarRowMarker.MarkerView, m.workspace == workspace, case .session(let id)? = m.item, !m.isHiddenOrHasHiddenAncestor {
                let r = m.convert(m.bounds, to: nil)
                return (id, CGRect(x: r.minX, y: content.frame.height - r.maxY, width: r.width, height: r.height))
            }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        return search(content)
    }

    /// Saves a picture of the window (TETHER_SELFTEST_SNAPSHOT=<dir>) so layouts can be checked
    /// without screen-recording permission.
    static func snapshot(_ window: NSWindow?, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["TETHER_SELFTEST_SNAPSHOT"],
              let view = window?.contentView?.superview ?? window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Waits for a process it started, for a few seconds at most (a hung tmux or ssh must not hold
    /// the run, or quitting, up): then it is ended.
    nonisolated static func wait(for process: Process, seconds: Double = 5) {
        let end = Date().addingTimeInterval(seconds)
        while process.isRunning, Date() < end { usleep(20_000) }
        guard process.isRunning else { return }
        process.terminate()
        // Gone before anyone reads how it ended (reading that of a running process raises).
        let killAt = Date().addingTimeInterval(2)
        while process.isRunning, Date() < killAt { usleep(20_000) }
        if process.isRunning, process.processIdentifier > 1 { kill(process.processIdentifier, SIGKILL) }
        while process.isRunning { usleep(20_000) }
    }

    static func runIfRequested(state: WindowState) {
        let env = ProcessInfo.processInfo.environment
        guard !started, let logPath = env["TETHER_SELFTEST"], let ssh = env["TETHER_SSH_BINARY"],
              env["TETHER_SUPPORT_DIR"] != nil, env["TETHER_DEFAULTS_SUITE"] != nil else { return }
        started = true
        // Local sessions of a test run get their own tmux server, never the user's.
        // (A short path: tmux's socket path must fit in about 104 bytes.)
        let tmuxDir = URL(fileURLWithPath: "/tmp/tether-\(getuid())-tmux-\(getpid())", isDirectory: true)
        AppPaths.ensure(tmuxDir, permissions: 0o700)
        setenv("TMUX_TMPDIR", tmuxDir.path, 1)
        unsetenv("TMUX")
        // Whatever the run did, its tmux server (by its own socket) and folder go when Tether quits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            let socket = tmuxDir.appendingPathComponent("tmux-\(getuid())/default").path
            if FileManager.default.fileExists(atPath: socket) {
                let end = Process()
                end.executableURL = URL(fileURLWithPath: "/bin/sh")
                end.arguments = ["-c", "unset TMUX; exec tmux -S \"$1\" kill-server", "sh", socket]
                end.environment = ["PATH": ChildEnvironment.local["PATH"] ?? "/usr/bin:/bin:/opt/homebrew/bin"]
                end.standardError = FileHandle.nullDevice
                try? end.run()
                SelfTest.wait(for: end)
            }
            // Only this run's own folder (named after its process).
            if tmuxDir.path.hasPrefix("/tmp/tether-\(getuid())-tmux-") { try? FileManager.default.removeItem(at: tmuxDir) }
        }
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let log = FileHandle(forWritingAtPath: logPath)
        func say(_ s: String) {
            log?.write(Data("\(Date().timeIntervalSince1970) \(s)\n".utf8))
        }
        let model = AppModel.shared
        model.settings.sshBinary = ssh
        model.settings.useControlMaster = env["TETHER_SELFTEST_MASTER"] != nil
        model.settings.recordingEnabled = false
        model.settings.confirmCloseOnlineSessions = env["TETHER_SELFTEST_CONFIRM"] != nil
        // A run ends by quitting by itself: never held up by the question about what would end.
        model.settings.confirmQuitWhenWorkWouldEnd = false
        if env["TETHER_SELFTEST_NOBLINK"] != nil { model.settings.cursorBlink = false }
        model.settings.showStatusStrip = env["TETHER_SELFTEST_NOSTRIP"] == nil
        model.settings.cursorBlink = env["TETHER_SELFTEST_NOBLINK"] == nil ? model.settings.cursorBlink : false
        model.settings.showSidebarArchive = false
        model.settings.requireAuthForSavedPasswords = false
        if env["TETHER_SELFTEST_NOINSPECTOR"] != nil { state.sidebarSelection = nil; state.showInspectorRequest = false }
        let target = ConnectionTarget.adhoc(user: nil, host: "selftest.local", port: nil, jump: nil)

        // A server that cannot be reached at all (every ssh hangs, as on a network that went away):
        // tabs and a file window to it, then quitting. The app must stay responsive the whole time
        // and quit at once (checked from outside). TETHER_SELFTEST_OFFLINE=1.
        if env["TETHER_SELFTEST_OFFLINE"] != nil {
            Task { @MainActor in
                let host = ConnectionTarget.adhoc(user: "user", host: "unreachable.example.com", port: nil, jump: nil)
                let tabs = (0..<3).map { _ in state.connect(host, persistence: .tmux) }
                state.browse(host, path: "/srv/app")
                // How late the main thread answers, while everything waits on the server.
                var worst = 0.0
                for _ in 0..<40 {
                    let asked = ProcessInfo.processInfo.systemUptime
                    try? await Task.sleep(for: .milliseconds(200))
                    worst = max(worst, ProcessInfo.processInfo.systemUptime - asked - 0.2)
                }
                say(worst < 1 ? "PASS the app stayed responsive while the server did not answer (worst delay \(Int(worst * 1000)) ms)"
                              : "FAIL the main thread was held up for \(Int(worst * 1000)) ms")
                say("tabs: " + tabs.map { "\($0.phase.label)" }.joined(separator: ", "))
                say("QUITTING")
                if env["TETHER_SELFTEST_KEEP"] == nil { NSApp.terminate(nil) }
            }
            return
        }

        // The sign-in panel: showing it makes it key, which posts the notifications that ask for it
        // again; that once recursed until the stack ran out (a frozen app, then a crash). One panel,
        // shown once, however often it is asked for — new, hidden and shown again, and from inside
        // the notifications. TETHER_SELFTEST_PROMPTPANEL=1.
        if env["TETHER_SELFTEST_PROMPTPANEL"] != nil {
            Task { @MainActor in
                let panel = AskPassPanel.shared
                func question(_ n: Int) -> PendingPrompt {
                    PendingPrompt(request: AskPassRequest(token: "selftest-\(n)", targetKey: "selftest.local", purpose: "connect",
                                                          prompt: "user@selftest.local's password: ", sequence: n))
                }
                // Every key change asks again from inside the notification, as a busy app would.
                var reentered = 0
                let watcher = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { _ in
                    MainActor.assumeIsolated {
                        if panel.isPresenting { reentered += 1 }
                        panel.update(model.promptInFront)
                        model.refreshPromptPanel()
                    }
                }
                let first = question(1)
                model.setPrompts([first])
                try? await Task.sleep(for: .seconds(1))
                let shown = NSApp.windows.filter { $0 is NSPanel && $0.isVisible && !$0.isSheet }
                say(panel.panelsMade == 1 && shown.count == 1
                    ? "PASS a new question shows one panel (asked again \(reentered) times while showing)"
                    : "FAIL new question: \(panel.panelsMade) panels made, \(shown.count) visible")
                // Hidden (its tab went to the background) and shown again: the same panel.
                for window in shown { window.orderOut(nil) }
                for _ in 0..<5 {
                    model.refreshPromptPanel()
                    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: state.window)
                }
                try? await Task.sleep(for: .seconds(1))
                let again = NSApp.windows.filter { $0 is NSPanel && $0.isVisible && !$0.isSheet }
                if !NSApp.isActive {
                    // Another app is in front (a run started in the background): the panel is not
                    // pulled forward over it — it comes back when Tether is active again.
                    say(panel.panelsMade == 1 && again.isEmpty
                        ? "PASS a hidden question waits while another app is in front (and is not made twice)"
                        : "FAIL while inactive: \(panel.panelsMade) panels made, \(again.count) visible")
                } else {
                    say(panel.panelsMade == 1 && again.count == 1 ? "PASS a hidden question comes back in the same panel"
                                                                  : "FAIL shown again: \(panel.panelsMade) panels made, \(again.count) visible")
                }
                // Another question while one is up, then none: the panel follows, and goes.
                model.setPrompts([question(2)])
                try? await Task.sleep(for: .milliseconds(500))
                model.setPrompts([])
                try? await Task.sleep(for: .milliseconds(500))
                let gone = !NSApp.windows.contains { $0 is NSPanel && $0.isVisible && !$0.isSheet }
                say(panel.panelsMade == 1 && gone ? "PASS the panel follows the questions and goes with the last"
                                                  : "FAIL after questions: \(panel.panelsMade) panels made, gone=\(gone)")
                NotificationCenter.default.removeObserver(watcher)
                say("DONE")
                if env["TETHER_SELFTEST_KEEP"] == nil { NSApp.terminate(nil) }
            }
            return
        }

        // The menus while typing in a terminal: which item a ⌘ key reaches, and whether it is on.
        // TETHER_SELFTEST_MENUS=1.
        if env["TETHER_SELFTEST_MENUS"] != nil {
            Task { @MainActor in
                let s = state.connect(.local, persistence: .off)
                for _ in 0..<100 where !s.phase.isOnline { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(1))
                let view = TerminalRegistry.shared.view(for: s)
                view.window?.makeKeyAndOrderFront(nil)
                view.window?.makeFirstResponder(view)
                try? await Task.sleep(for: .milliseconds(500))
                say("first responder: \(String(describing: view.window?.firstResponder.map { type(of: $0) }))")
                @MainActor func walk(_ menu: NSMenu, _ path: String) {
                    for item in menu.items {
                        if item.keyEquivalent == "s" || item.title.contains("Save") {
                            say("item \(path) ▸ \(item.title) key=\(item.keyEquivalent) mods=\(item.keyEquivalentModifierMask.rawValue) enabled=\(item.isEnabled)")
                        }
                        if let sub = item.submenu { walk(sub, path + " ▸ " + item.title) }
                    }
                }
                if let main = NSApp.mainMenu { walk(main, "") }
                if let file = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu {
                    say("File menu: " + file.items.map { $0.isSeparatorItem ? "—" : "\($0.title)[\($0.keyEquivalent)]" }.joined(separator: " | "))
                }
                if let window = view.window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                                                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                                           context: nil, characters: "s", charactersIgnoringModifiers: "s",
                                                                           isARepeat: false, keyCode: 1) {
                    NSApp.mainMenu?.update()
                    let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
                    say("menu took ⌘S: \(handled)")
                    try? await Task.sleep(for: .seconds(1))
                    let sheet = window.attachedSheet.map { "\(type(of: $0)) \($0.title)" } ?? "none"
                    say("sheet after ⌘S: \(sheet)")
                    window.attachedSheet.map { window.endSheet($0) }
                }
                say("DONE")
                if env["TETHER_SELFTEST_KEEP"] == nil { NSApp.terminate(nil) }
            }
            return
        }

        // Quitting with local tmux tabs that print and record: Tether ends at once and the tmux
        // sessions outlive it (checked from outside). TETHER_SELFTEST_QUIT=1; with
        // TETHER_SELFTEST_KEEP it stays up instead (to be killed from outside).
        if env["TETHER_SELFTEST_QUIT"] != nil {
            Task { @MainActor in
                model.settings.recordingEnabled = true
                let tabs = [state.connect(.local, persistence: .tmux), state.connect(.local, persistence: .tmux)]
                for _ in 0..<150 where tabs.contains(where: { !$0.phase.isOnline }) { try? await Task.sleep(for: .milliseconds(100)) }
                for t in tabs { t.send(Array("i=0; while [ $i -lt 3000 ]; do echo line $i; i=$((i+1)); done\r".utf8)[...]) }
                try? await Task.sleep(for: .seconds(3))
                say("sessions \(tabs.map { "\($0.descriptor.remoteSessionName) \($0.persistence) \($0.phase.label)" })")
                say("QUITTING")
                if env["TETHER_SELFTEST_KEEP"] == nil { NSApp.terminate(nil) }
            }
            return
        }

        // Finder files dropped on a local terminal: their paths are typed. TETHER_SELFTEST_DROP=1.
        if env["TETHER_SELFTEST_DROP"] != nil {
            Task { @MainActor in
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-selftest-\(UUID().uuidString)")
                let folder = dir.appendingPathComponent("a folder", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = dir.appendingPathComponent("it's here.txt")
                try? Data("x".utf8).write(to: file)
                defer { try? FileManager.default.removeItem(at: dir) }
                for persistence in [PersistenceMode.tmux, .off] {
                    let s = state.connect(.local, persistence: persistence)
                    for _ in 0..<100 where !s.phase.isOnline { try? await Task.sleep(for: .milliseconds(100)) }
                    try? await Task.sleep(for: .seconds(1.5))
                    let view = TerminalRegistry.shared.view(for: s)
                    let pb = NSPasteboard(name: NSPasteboard.Name("tether-selftest-drop"))
                    pb.clearContents()
                    pb.writeObjects([file as NSURL, folder as NSURL])
                    let drag = SelfTestDrag(pasteboard: pb)
                    let entered = view.draggingEntered(drag)
                    let performed = view.performDragOperation(drag)
                    // Until the shell has shown it (a tmux pane's echo comes back through tmux).
                    var lines: [String] = []
                    for _ in 0..<30 {
                        try? await Task.sleep(for: .milliseconds(200))
                        lines = view.scrollbackText().lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        if lines.joined().contains("a folder") { break }
                    }
                    let typed = lines.joined().contains("here.txt") && lines.joined().contains("a folder")
                    // What a real drag over the middle of the terminal reaches: the deepest view
                    // there, and the views on the way up that take dragged files.
                    if let content = view.window?.contentView {
                        let mid = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                        var hit = content.hitTest(content.convert(mid, from: nil))
                        var chain: [String] = []
                        while let h = hit {
                            let takes = h.registeredDraggedTypes.contains(.fileURL)
                            chain.append("\(type(of: h))\(takes ? "[files]" : "")\(h === view ? "<TERMINAL" : "")")
                            hit = h.superview
                        }
                        say("hit chain: \(chain.prefix(8).joined(separator: " > "))")
                    }
                    say("\(typed ? "PASS" : "FAIL") drop on local \(persistence) entered=\(entered.rawValue) performed=\(performed) callbacks=\(view.onFiles != nil)")
                    for l in lines.suffix(4) { say("  | \(l)") }
                    say("  phase=\(s.phase.label) persistence=\(s.persistence)")
                    pb.releaseGlobally()
                    // Rows of this Mac's own file manager dropped here: their paths, nothing copied.
                    let clip = RemoteClip(target: .local, items: [.init(path: folder.path, name: "a folder", isDirectory: true)])
                    s.send(Array("\u{3}clear\r".utf8)[...])
                    try? await Task.sleep(for: .seconds(0.8))
                    _ = model.pasteRemoteClip(into: s, in: state, dropped: clip)
                    try? await Task.sleep(for: .seconds(0.8))
                    let rows = view.scrollbackText().lines.joined()
                    say("\(rows.contains("a folder") && model.uploadBatches[s.id] == nil ? "PASS" : "FAIL") Mac file manager rows on local \(persistence)")
                    // A full-screen program that takes pastes as pastes (vim, an agent's prompt): typed.
                    s.send(Array("\u{3}printf '\\033[?1049h\\033[?2004h'; sleep 4; printf '\\033[?2004l\\033[?1049l'\r".utf8)[...])
                    try? await Task.sleep(for: .seconds(1))
                    let full = view.showsAlternateScreen && view.getTerminal().bracketedPasteMode
                    let typedThere = model.typePaths([file.path], into: s, now: true)
                    say("\(full && typedThere ? "PASS" : "FAIL") full-screen bracketed: fullScreen=\(full) typed=\(typedThere)")
                    try? await Task.sleep(for: .seconds(4))
                }
                // A server's files saved for a terminal here: next to what is there, never over it.
                let into = dir.appendingPathComponent("into", isDirectory: true)
                try? FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
                try? Data("old".utf8).write(to: into.appendingPathComponent("it's here.txt"))
                let placed = await AppModel.place([file, folder], in: into, moving: false)
                let old = (try? String(contentsOf: into.appendingPathComponent("it's here.txt"), encoding: .utf8)) == "old"
                say("\(old && placed.map(\.lastPathComponent) == ["it's here 2.txt", "a folder"] ? "PASS" : "FAIL") saved beside: \(placed.map(\.lastPathComponent)) old kept=\(old)")
                // This run's own tmux server ends with it (by its socket: never the user's).
                let end = Process()
                end.executableURL = URL(fileURLWithPath: "/bin/sh")
                end.arguments = ["-c", "unset TMUX; exec tmux -S \"$1\" kill-server", "sh", tmuxDir.appendingPathComponent("tmux-\(getuid())/default").path]
                end.environment = ["PATH": ChildEnvironment.local["PATH"] ?? "/usr/bin:/bin:/opt/homebrew/bin"]
                try? end.run()
                SelfTest.wait(for: end)
                say("DONE")
                if env["TETHER_SELFTEST_KEEP"] == nil { NSApp.terminate(nil) }
            }
            return
        }

        // What a local terminal runs: shell, directory, persistence. TETHER_SELFTEST_LOCALSHELL=1.
        if env["TETHER_SELFTEST_LOCALSHELL"] != nil {
            Task { @MainActor in
                say("app env SHELL=\(ProcessInfo.processInfo.environment["SHELL"] ?? "-") cwd=\(FileManager.default.currentDirectoryPath)")
                let s = state.connect(.local)
                for _ in 0..<100 where !s.phase.isOnline { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(1.5))
                s.send(Array("echo PROBE shell=$0 pwd=$(pwd) SHELL=$SHELL\r".utf8)[...])
                try? await Task.sleep(for: .seconds(1.5))
                let lines = TerminalRegistry.shared.view(for: s).scrollbackText().lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                say("persistence=\(s.persistence) phase=\(s.phase.label)")
                for l in lines.suffix(6) { say("  | \(l)") }
                say("DONE")
                if env["TETHER_SELFTEST_KEEP"] == nil { NSApp.terminate(nil) }
            }
            return
        }

        // The running command: found in a local tmux pane and in a plain shell, shown below the
        // terminal and in the host panel, and kept in the history when it ends. TETHER_SELFTEST_COMMANDS=1.
        if env["TETHER_SELFTEST_COMMANDS"] != nil {
            Task { @MainActor in
                model.settings.keepCommandHistory = true
                model.settings.showCommandStats = true
                model.commandHistory.load()
                // Every process the test saw: none may be left running when it ends.
                var seenPids = Set<Int32>()
                for mode in [PersistenceMode.tmux, .off] {
                    let s = state.connect(.local, persistence: mode)
                    for _ in 0..<100 where !s.phase.isOnline { try? await Task.sleep(for: .milliseconds(100)) }
                    try? await Task.sleep(for: .seconds(1.5))
                    s.send(Array("sh -c 'yes > /dev/null'\r".utf8)[...])
                    try? await Task.sleep(for: .seconds(8))
                    let sampler = model.commandSamplers[s.id]
                    let leader = sampler?.frame?.leader
                    say("\(mode) persistence=\(s.persistence) status=\(String(describing: sampler?.status)) leader=\(leader?.name ?? "-") pid=\(leader?.pid ?? 0) cpu=\(sampler?.latest?.cpu ?? -1) mem=\(sampler?.latest?.memory ?? -1) procs=\(sampler?.frame?.processes.count ?? 0)")
                    say(sampler?.status == .running && (sampler?.latest?.cpu ?? 0) > 30 ? "PASS \(mode) command found with CPU use" : "FAIL \(mode) command not found")
                    snapshot(state.window, "command-pill-\(mode)")
                    state.showRunningCommand(s)
                    try? await Task.sleep(for: .seconds(3))
                    snapshot(state.window, "command-panel-\(mode)")
                    let id = sampler?.recordID
                    let procs = sampler?.frame?.processes ?? []
                    procs.forEach { seenPids.insert(Int32($0.pid)) }
                    if mode == .tmux {
                        s.send(Array("\u{03}".utf8)[...])
                    } else {
                        // The Kill button: the command and everything it started (sh and yes here).
                        let err = await model.monitor(for: .local).stopCommand(procs, shellPid: sampler?.frame?.shellPid, signal: "KILL")
                        let alive = procs.filter { kill(Int32($0.pid), 0) == 0 }
                        say(err == nil && alive.isEmpty ? "PASS Kill ended the whole command (\(procs.count) processes)"
                                                        : "FAIL Kill left \(alive.map(\.pid)) \(err ?? "")")
                    }
                    try? await Task.sleep(for: .seconds(7))
                    let r = id.flatMap { model.commandHistory.record($0) }
                    say("record status=\(String(describing: r?.status)) duration=\(r?.duration ?? -1) cpu avg=\(r?.cpu?.mean ?? -1) peak=\(r?.cpu?.max ?? -1) mem peak=\(r?.memory?.max ?? -1) cmd=\(r?.commandLine ?? "-")")
                    say(r?.status == .finished && (r?.cpu?.mean ?? 0) > 30 ? "PASS \(mode) history record finished" : "FAIL \(mode) history record")
                    say(sampler?.status == .idle ? "PASS \(mode) idle after Control-C" : "FAIL \(mode) status \(String(describing: sampler?.status))")
                    state.inspectorTab = .command
                    snapshot(state.window, "command-history-\(mode)")
                    model.sessions.close(s.id, killRemote: true)
                    try? await Task.sleep(for: .seconds(1))
                }
                // Network: a local TCP transfer is measured per process and per connection.
                let s = state.connect(.local, persistence: .tmux)
                for _ in 0..<100 where !s.phase.isOnline { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(1.5))
                s.send(Array("sh -c '(yes | nc -l 127.0.0.1 45679 >/dev/null &); sleep 1; nc 127.0.0.1 45679 >/dev/null'\r".utf8)[...])
                try? await Task.sleep(for: .seconds(9))
                let sampler = model.commandSamplers[s.id]
                let fast = sampler?.connections.filter { $0.rate > 0 } ?? []
                say("network rx=\(sampler?.latest?.received ?? -1) tx=\(sampler?.latest?.sent ?? -1) connections=\(sampler?.connections.count ?? 0) moving=\(fast.count) diagnostics=\(sampler?.diagnostics.text ?? "")")
                say((sampler?.latest?.received ?? 0) > 0 && !fast.isEmpty ? "PASS network measured per process and connection" : "FAIL network not measured")
                state.showRunningCommand(s)
                try? await Task.sleep(for: .seconds(2))
                snapshot(state.window, "command-network")
                s.send(Array("\u{03}".utf8)[...])
                try? await Task.sleep(for: .seconds(2))

                // A one-second command is seen by the watcher and kept, with its command line.
                s.send(Array("sleep 1\r".utf8)[...])
                try? await Task.sleep(for: .seconds(4))
                let short = model.commandHistory.records(sessionID: s.id).first { $0.commandLine == "sleep 1" }
                say("short duration=\(short?.duration ?? -1) short=\(String(describing: short?.short)) recent=\(model.commandHistory.records(sessionID: s.id).prefix(4).map { "\($0.commandLine)|\($0.short == true)|\($0.status.rawValue)" }) diagnostics=\(model.commandSamplers[s.id]?.diagnostics.text ?? "")")
                say(short != nil ? "PASS a one-second command is in the history" : "FAIL the one-second command was missed")

                // ping: its ICMP socket and target appear among the connections.
                s.send(Array("ping -c 6 127.0.0.1\r".utf8)[...])
                try? await Task.sleep(for: .seconds(4))
                let icmp = model.commandSamplers[s.id]?.connections.first { $0.proto == "ICMP" }
                say("icmp \(icmp.map { "\($0.peer) \($0.state)" } ?? "none")")
                say(icmp?.peer == "127.0.0.1" ? "PASS ping shows as an ICMP connection to its target" : "FAIL ping not shown")
                s.send(Array("\u{03}".utf8)[...])

                // Three terminals on one host share one watcher.
                let more = [state.connect(.local, persistence: .tmux), state.connect(.local, persistence: .tmux)]
                for _ in 0..<100 where more.contains(where: { !$0.phase.isOnline }) { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(4))
                let ps = Process()
                ps.executableURL = URL(fileURLWithPath: "/bin/ps")
                ps.arguments = ["-A", "-o", "ppid=,args="]
                let pipe = Pipe()
                ps.standardOutput = pipe
                try? ps.run()
                let list = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                SelfTest.wait(for: ps)
                let mine = String(getpid())
                let watchers = list.split(separator: "\n").filter { $0.contains("sh -s -- -i ") && $0.trimmingCharacters(in: .whitespaces).hasPrefix(mine + " ") }
                say("watchers=\(watchers.count) for \(model.commandSamplers.count) terminals")
                say(watchers.count == 1 ? "PASS one watcher for all terminals of the host" : "FAIL \(watchers.count) watchers")
                for t in more { model.sessions.close(t.id, killRemote: true) }
                model.sessions.close(s.id, killRemote: true)
                try? await Task.sleep(for: .seconds(3))
                // Nothing the test started is left behind (killed here only if it was).
                let left = seenPids.filter { kill($0, 0) == 0 }
                left.forEach { kill($0, SIGKILL) }
                say(left.isEmpty ? "PASS no test process left running" : "FAIL left running: \(left.sorted())")
                say("DONE")
                if env["TETHER_SELFTEST_KEEP"] == nil { NSApp.terminate(nil) }
            }
            return
        }

        // Real sshd, a key with a passphrase saved in Tether: ssh asks through askpass and only the ssh
        // the token was given to gets an answer. TETHER_SELFTEST_PASSPHRASE=<sshd test dir>.
        if let rig = env["TETHER_SELFTEST_PASSPHRASE"] {
            Task { @MainActor in
                // A short path: ssh shortens long key paths in its prompt (which then names no file).
                let dir = URL(fileURLWithPath: "/tmp/tpp-\(getpid())", isDirectory: true)
                AppPaths.ensure(dir, permissions: 0o700)
                let keyURL = dir.appendingPathComponent("id_pp")
                do { _ = try await KeySetup.generate(at: keyURL, comment: "tether-selftest-pp", passphrase: "pp-secret-456") }
                catch { say("FAIL keygen \(error.localizedDescription)"); return }
                let pub = (try? String(contentsOf: keyURL.appendingPathExtension("pub"), encoding: .utf8)) ?? ""
                let auth = URL(fileURLWithPath: rig).appendingPathComponent("authorized_keys")
                let before = (try? String(contentsOf: auth, encoding: .utf8)) ?? ""
                try? (before + pub).write(to: auth, atomically: true, encoding: .utf8)
                let config = dir.appendingPathComponent("ssh_config")
                try? """
                Host pptest
                    HostName 127.0.0.1
                    Port 22222
                    IdentityFile \(keyURL.path)
                    IdentitiesOnly yes
                    IdentityAgent none
                    UseKeychain no
                    AddKeysToAgent no
                    UserKnownHostsFile \(rig)/known_hosts
                    StrictHostKeyChecking no
                """.write(to: config, atomically: true, encoding: .utf8)
                model.settings.sshConfigPath = config.path
                model.settings.useControlMaster = true
                model.settings.requireAuthForSavedPasswords = false
                Credentials.save("pp-secret-456", for: CredentialKey.passphrase(keyPath: keyURL.path))
                let s = state.connect(.alias("pptest"), persistence: .off)
                for _ in 0..<150 where !s.phase.isOnline && !s.phase.isDead { try? await Task.sleep(for: .milliseconds(100)) }
                say(s.phase.isOnline ? "PASS signed in with the saved passphrase (token bound to its ssh)"
                                     : "FAIL \(s.phase.label) \(s.progress?.failure ?? "") prompts=\(model.prompts.map(\.request.prompt))")
                // A token used by a Tether child it was not given to: refused.
                let stolen = AskPassBridge.shared.environment(targetKey: "pptest", purpose: "connect", mode: "force")
                var e = ProcessInfo.processInfo.environment
                e.merge(stolen) { $1 }
                let r = await ProcessRunner.run(AskPassBridge.shared.helperPath ?? "/usr/bin/false",
                                                arguments: ["Enter passphrase for key '\(keyURL.path)': "], timeout: 10)
                _ = e
                let direct = Process()
                direct.executableURL = URL(fileURLWithPath: AskPassBridge.shared.helperPath ?? "/usr/bin/false")
                direct.arguments = ["Enter passphrase for key '\(keyURL.path)': "]
                direct.environment = e
                let out = Pipe(); direct.standardOutput = out
                try? direct.run(); SelfTest.wait(for: direct)
                let answer = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                AskPassBridge.shared.revoke(environment: stolen)
                say(direct.terminationStatus != 0 && !answer.contains("pp-secret") && !r.succeeded
                    ? "PASS a token used by another process gets nothing" : "FAIL stolen token answered: \(answer)")
                model.sessions.close(s.id, killRemote: true)
                try? await Task.sleep(for: .seconds(1))

                // From here every sign-in starts its own ssh with nothing loaded, as after a restart.
                model.settings.useControlMaster = false
                let account = CredentialKey.passphrase(keyPath: keyURL.path)
                /// Connects, hands each prompt to `reply` (none: cancelled), and closes again.
                @MainActor func signIn(_ alias: String, reply: ((PendingPrompt) -> Void)? = nil) async -> (online: Bool, asked: [PendingPrompt]) {
                    let t = state.connect(.alias(alias), persistence: .off)
                    var asked: [PendingPrompt] = []
                    for _ in 0..<150 where !t.phase.isOnline && !t.phase.isDead {
                        if let p = model.prompts.first(where: { p in !asked.contains { $0.id == p.id } }) {
                            asked.append(p)
                            if let reply { reply(p) } else { model.resolvePrompt(p, answer: nil, save: false) }
                        }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    let online = t.phase.isOnline
                    model.sessions.close(t.id, killRemote: true)
                    try? await Task.sleep(for: .seconds(1))
                    return (online, asked)
                }
                let fresh = await signIn("pptest")
                say(fresh.online && fresh.asked.isEmpty ? "PASS a new ssh signs in with the kept passphrase, nothing asked"
                                                        : "FAIL fresh sign-in online=\(fresh.online) asked=\(fresh.asked.map(\.request.prompt))")

                // Not kept: asked once; with "remember" the answer is kept and the next sign-in asks nothing.
                Credentials.remove(account)
                let typed = await signIn("pptest") { model.resolvePrompt($0, answer: "pp-secret-456", save: true) }
                let kept = PasswordVault.password(for: account) == "pp-secret-456"
                let after = await signIn("pptest")
                say(typed.online && typed.asked.count == 1 && kept && after.online && after.asked.isEmpty
                    ? "PASS a typed passphrase is remembered and used next time"
                    : "FAIL remember typed=\(typed.online)/\(typed.asked.count) kept=\(kept) after=\(after.online)/\(after.asked.count)")

                // A kept passphrase that is wrong (the key was changed elsewhere): sent once, then asked.
                Credentials.save("not-the-passphrase", for: account)
                let wrong = await signIn("pptest") { model.resolvePrompt($0, answer: "pp-secret-456", save: true) }
                say(wrong.online && wrong.asked.count == 1 && wrong.asked.first?.savedWasRejected == true
                    && PasswordVault.password(for: account) == "pp-secret-456"
                    ? "PASS a wrong kept passphrase is noticed, asked for and replaced"
                    : "FAIL wrong kept online=\(wrong.online) asked=\(wrong.asked.count) rejected=\(wrong.asked.first?.savedWasRejected == true)")

                // A key path longer than ssh shows in its prompt (it cuts it at 100 characters).
                let deep = dir.appendingPathComponent(String(repeating: "deep-folder-", count: 8), isDirectory: true)
                AppPaths.ensure(deep, permissions: 0o700)
                let longURL = deep.appendingPathComponent("id_pp_long")
                do { _ = try await KeySetup.generate(at: longURL, comment: "tether-selftest-long", passphrase: "pp-long-789") }
                catch { say("FAIL keygen long \(error.localizedDescription)") }
                let longPub = (try? String(contentsOf: longURL.appendingPathExtension("pub"), encoding: .utf8)) ?? ""
                try? (before + pub + longPub).write(to: auth, atomically: true, encoding: .utf8)
                let text = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
                try? (text + "\n" + text.replacingOccurrences(of: "Host pptest", with: "Host pplong")
                    .replacingOccurrences(of: keyURL.path, with: longURL.path)).write(to: config, atomically: true, encoding: .utf8)
                model.reloadConfig()
                Credentials.save("pp-long-789", for: CredentialKey.passphrase(keyPath: longURL.path))
                let long = await signIn("pplong")
                say(long.online && long.asked.isEmpty ? "PASS a long key path (\(longURL.path.count) characters) finds its kept passphrase"
                                                      : "FAIL long path online=\(long.online) asked=\(long.asked.map(\.request.prompt))")
                try? before.write(to: auth, atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: dir)
                try? await Task.sleep(for: .seconds(1))
                say("DONE")
                if env["TETHER_SELFTEST_KEEP"] == nil { NSApp.terminate(nil) }
            }
            return
        }

        // A key with a passphrase, handed to ssh-keygen through askpass (never in its arguments).
        // TETHER_SELFTEST_KEYGEN=1.
        if env["TETHER_SELFTEST_KEYGEN"] != nil {
            Task { @MainActor in
                let dir = AppPaths.supportDirectory.appendingPathComponent("keys", isDirectory: true)
                AppPaths.ensure(dir, permissions: 0o700)
                let url = dir.appendingPathComponent("id_test")
                say("socket dir private: \(AppPaths.controlSocketDirectory.path.contains("-dbg-"))")
                do {
                    _ = try await KeySetup.generate(at: url, comment: "selftest", passphrase: "kp-secret-123")
                    @MainActor func opens(_ pw: String) async -> Bool {
                        await ProcessRunner.run("/usr/bin/ssh-keygen", arguments: ["-y", "-P", pw, "-f", url.path], timeout: 20).succeeded
                    }
                    let right = await opens("kp-secret-123"), wrong = await opens("nope"), empty = await opens("")
                    say(right && !wrong && !empty ? "PASS key encrypted with the passphrase" : "FAIL right=\(right) wrong=\(wrong) empty=\(empty)")
                    // Changing it (askpass answers old and new), and a wrong old one leaving the key as it was.
                    if let key = KeySetup.key(at: url) {
                        let changed = try await KeySetup.changePassphrase(key, old: "kp-secret-123", new: "kp-new-789")
                        let newWorks = await opens("kp-new-789"), oldGone = await !opens("kp-secret-123")
                        say(newWorks && oldGone && changed.isEncrypted == true ? "PASS passphrase changed" : "FAIL change new=\(newWorks) oldGone=\(oldGone)")
                        let before = try Data(contentsOf: url)
                        let refused = (try? await KeySetup.changePassphrase(changed, old: "wrong", new: "x")) == nil
                        say(refused && (try? Data(contentsOf: url)) == before ? "PASS wrong old passphrase changes nothing" : "FAIL wrong old passphrase")
                    }
                } catch {
                    say("FAIL \(error.localizedDescription)")
                }
                say("DONE")
                if env["TETHER_SELFTEST_KEEP"] == nil { NSApp.terminate(nil) }
            }
            return
        }

        // App Lock and encrypted recordings. TETHER_SELFTEST_LOCK=1 (keychain items stay in memory).
        if env["TETHER_SELFTEST_LOCK"] != nil {
            Task { @MainActor in
                let lock = AppLock.shared
                model.settings.recordingEnabled = true
                // A plain recording from before encryption was switched on.
                let old = state.connect(.local)
                for _ in 0..<100 where !old.phase.isOnline { try? await Task.sleep(for: .milliseconds(100)) }
                old.send(Array("echo plain-before-\(42 * 1000)\r".utf8)[...])
                try? await Task.sleep(for: .seconds(1.5))
                let oldURL = old.flushedRecordingURL()
                model.sessions.close(old.id, killRemote: true)
                try? await Task.sleep(for: .seconds(0.5))
                say(oldURL.map { !RecordingCrypto.isEncrypted($0) } == true ? "PASS old recording is plain" : "FAIL old recording state")

                // Tether password + encryption: the old recording is encrypted automatically.
                say(lock.enablePassword("correct horse battery") ? "PASS password set" : "FAIL password")
                model.settings.encryptRecordings = true
                lock.installKey(RecordingCrypto.key)
                if let key = RecordingCrypto.writerKey { _ = RecordingStore.encryptAll(with: key) }
                say(oldURL.map(RecordingCrypto.isEncrypted) == true ? "PASS existing recording encrypted" : "FAIL existing not encrypted")

                let s = state.connect(.local)
                for _ in 0..<100 where !s.phase.isOnline { try? await Task.sleep(for: .milliseconds(100)) }
                s.send(Array("echo secret-marker-\(6 * 7)\r".utf8)[...])
                try? await Task.sleep(for: .seconds(1.5))
                guard let url = s.flushedRecordingURL() else { say("FAIL no recording"); return }
                let raw = (try? Data(contentsOf: url)) ?? Data()
                say(RecordingCrypto.isEncrypted(url) && raw.range(of: Data("secret-marker-42".utf8)) == nil
                    ? "PASS new recording encrypted on disk" : "FAIL new recording readable on disk")

                // An open sheet is closed by locking (and SwiftUI knows it).
                state.showQuickConnect = true
                try? await Task.sleep(for: .seconds(1))
                let sheetBefore = state.window?.attachedSheet != nil
                lock.lock()
                try? await Task.sleep(for: .milliseconds(600))
                say(sheetBefore && lock.isLocked ? "PASS open sheet covered by the lock screen" : "FAIL sheet before=\(sheetBefore)")
                state.showQuickConnect = false
                let firstResponder = state.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                say(lock.isLocked && RecordingCrypto.key == nil && !firstResponder.contains("TerminalView")
                    ? "PASS locked: key dropped, no terminal has the keyboard" : "FAIL lock state responder=\(firstResponder)")
                say((try? SearchEngine.readLines(url)) == nil ? "PASS recordings unreadable while locked" : "FAIL readable while locked")
                // The session keeps running and recording while locked.
                s.send(Array("echo during-lock-$((7*11))\r".utf8)[...])
                try? await Task.sleep(for: .seconds(1.5))
                say(s.phase.isOnline ? "PASS session still running while locked" : "FAIL session \(s.phase.label) while locked")
                let wrong = await lock.unlock(password: "wrong")
                say(!wrong && lock.retryAfter != nil ? "PASS wrong password refused and slowed down" : "FAIL wrong password")
                try? await Task.sleep(for: .seconds(1.2))
                let right = await lock.unlock(password: "correct horse battery")
                let lines = (try? SearchEngine.readLines(url)) ?? []
                let oldLines = oldURL.flatMap { try? SearchEngine.readLines($0) } ?? []
                let duringLock = (try? SearchEngine.readLines(s.flushedRecordingURL() ?? url))?.contains { $0.contains("during-lock-77") } == true
                let stillEncrypted = (try? Data(contentsOf: url)).map { $0.range(of: Data("during-lock-77".utf8)) == nil } == true && RecordingCrypto.isEncrypted(url)
                say(duringLock && stillEncrypted ? "PASS output while locked was recorded, encrypted, and is searchable" : "FAIL during lock found=\(duringLock) encrypted=\(stillEncrypted)")
                say(right && !lock.isLocked && lines.contains { $0.contains("secret-marker-42") } && oldLines.contains { $0.contains("plain-before-42000") }
                    ? "PASS unlocked: search reads new and old recordings"
                    : "FAIL unlock right=\(right) new=\(lines.contains { $0.contains("secret-marker-42") }) old=\(oldLines.contains { $0.contains("plain-before-42000") }) oldTail=\(oldLines.suffix(3))")
                // Turning encryption off and decrypting, then on again: every recording stays readable.
                @MainActor func allReadable() -> Bool {
                    [url, oldURL].compactMap { $0 }.allSatisfy { u in
                        let text = (try? SearchEngine.readLines(u)) ?? []
                        return text.contains { $0.contains("secret-marker-42") || $0.contains("plain-before-42000") }
                    }
                }
                model.settings.encryptRecordings = false
                lock.installKey(RecordingCrypto.key)
                _ = s.flushedRecordingURL()
                model.sessions.close(s.id, killRemote: true)
                try? await Task.sleep(for: .seconds(0.5))
                let decrypted = RecordingStore.decryptAll()
                let plainNow = [url, oldURL].compactMap { $0 }.allSatisfy { !RecordingCrypto.isEncrypted($0) }
                // (The maintenance pass that runs when the session closes may have decrypted them already.)
                say(plainNow && allReadable() ? "PASS encryption off: recordings decrypted, intact" : "FAIL decrypt n=\(decrypted) plain=\(plainNow) readable=\(allReadable())")
                model.settings.encryptRecordings = true
                lock.installKey(RecordingCrypto.key)
                let encrypted = RecordingCrypto.writerKey.map { RecordingStore.encryptAll(with: $0) } ?? 0
                let encryptedNow = [url, oldURL].compactMap { $0 }.allSatisfy { RecordingCrypto.isEncrypted($0) }
                say(encrypted >= 1 && encryptedNow && allReadable() ? "PASS encryption on again: recordings encrypted, intact" : "FAIL re-encrypt n=\(encrypted) encrypted=\(encryptedNow) readable=\(allReadable())")
                // The key is not kept in the keychain in plain form with a Tether password.
                say(RecordingKeyStore.storedKey() == nil ? "PASS key only behind the password" : "FAIL plain key stored")
                say("DONE")
                if env["TETHER_SELFTEST_KEEP"] == nil { NSApp.terminate(nil) }
            }
            return
        }

        // Catch-up against a real sshd: output printed while disconnected reaches the terminal once, in
        // order. TETHER_SELFTEST_CATCHUP=1 (+ _SSHCONFIG, _HOST, _TMUXDIR = the server's TMUX_TMPDIR).
        if env["TETHER_SELFTEST_CATCHUP"] != nil {
            Task { @MainActor in
                if let cfg = env["TETHER_SELFTEST_SSHCONFIG"] { model.settings.sshConfigPath = cfg }
                model.settings.useControlMaster = true
                model.settings.recordingEnabled = true
                model.settings.defaultPersistence = .tmux
                model.settings.reconnectBaseDelay = 3
                let host = ConnectionTarget.alias(env["TETHER_SELFTEST_HOST"] ?? "loadtest")
                @MainActor func tmux(_ args: [String]) async -> String {
                    var e = ProcessInfo.processInfo.environment
                    e["TMUX_TMPDIR"] = env["TETHER_SELFTEST_TMUXDIR"]
                    e["TMUX"] = nil
                    let r = await ProcessRunner.run("/opt/homebrew/bin/tmux", arguments: args, environment: e, timeout: 10)
                    if r.status != 0 { say("tmux \(args.first ?? ""): \(String(decoding: r.stderr, as: UTF8.self))") }
                    return String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let s = state.connect(host, persistence: .tmux)
                for _ in 0..<200 where !s.phase.isOnline { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(1))
                let name = s.descriptor.remoteSessionName
                say("session \(name) persistence=\(s.persistence) phase=\(s.phase.label) server sessions: \(await tmux(["list-sessions", "-F", "#{session_name}"]))")
                let limit = await tmux(["show-options", "-t", "=\(name):", "-v", "history-limit"])
                say(limit == String(model.settings.serverHistoryLines) ? "PASS server keeps \(limit) lines" : "FAIL history-limit=\(limit)")
                let windows = await tmux(["list-windows", "-t", "=\(name)", "-F", "#{window_name}"])
                say(windows.contains("tether-init") ? "FAIL placeholder window left: \(windows)" : "PASS one window")
                _ = await tmux(["send-keys", "-t", "=\(name):", "seq -f before-%g 1 40", "Enter"])
                try? await Task.sleep(for: .seconds(1.5))
                // Start output that happens while disconnected, then cut the connection.
                _ = await tmux(["send-keys", "-t", "=\(name):", "sleep 1; seq -f during-%g 1 3000; echo done-marker", "Enter"])
                try? await Task.sleep(for: .milliseconds(200))
                await model.sessions.closeAllMasters()
                for _ in 0..<100 where s.phase.isOnline { try? await Task.sleep(for: .milliseconds(50)) }
                say("disconnected: \(s.phase.label)")
                for _ in 0..<300 where !s.phase.isOnline { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(2))
                let lines = TerminalRegistry.shared.view(for: s).scrollbackText().lines
                func count(_ t: String) -> Int { lines.filter { $0.trimmingCharacters(in: .whitespaces) == t }.count }
                let order = ["before-40", "during-1", "during-1500", "during-3000", "done-marker"].map { t in lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == t } ?? -1 }
                say("online=\(s.phase.isOnline) counts b40=\(count("before-40")) d1=\(count("during-1")) d1500=\(count("during-1500")) d3000=\(count("during-3000")) done=\(count("done-marker")) order=\(order)")
                let ordered = !order.contains(-1) && order == order.sorted()
                say(ordered && [count("before-40"), count("during-1"), count("during-1500"), count("during-3000"), count("done-marker")] == [1, 1, 1, 1, 1]
                    ? "PASS missed output arrived once, in order" : "FAIL catch-up")
                if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "before-40" }) {
                    for (n, l) in lines[max(0, i - 3)..<min(lines.count, i + 50)].enumerated() { say("  \(max(0, i - 3) + n): \(l)") }
                }
                let missing = (1...3000).filter { count("during-\($0)") != 1 }
                say(missing.isEmpty ? "PASS all 3000 lines" : "FAIL \(missing.count) lines missing or repeated, first \(missing.prefix(5))")
                model.sessions.close(s.id, killRemote: true)
                try? await Task.sleep(for: .seconds(1))
                say("DONE")
                if env["TETHER_SELFTEST_KEEP"] == nil { NSApp.terminate(nil) }
            }
            return
        }

        // Windows: a detached tab can be typed in, merging the last tab into another window closes the empty
        // one, and closing a window offers to move its tabs. TETHER_SELFTEST_WINDOWS=1.
        if env["TETHER_SELFTEST_WINDOWS"] != nil {
            Task { @MainActor in
                let store = model.workspaces
                state.window?.setFrame(NSRect(x: 60, y: 60, width: 1000, height: 650), display: true)
                let a = state.connect(.local), b = state.connect(.local), c = state.connect(.local)
                try? await Task.sleep(for: .seconds(1.5))
                @MainActor func focusOK(_ ws: UUID) -> Bool {
                    guard let w = store.window(of: ws) else { return false }
                    return w.firstResponder.map { String(describing: type(of: $0)).contains("TerminalView") } == true
                }
                say("main focused=\(focusOK(state.workspaceID))")
                // Detach a: new window, typing goes there.
                state.present(a.id, mode: .window)
                try? await Task.sleep(for: .seconds(1.5))
                guard let w2 = store.workspace(containing: a.id), w2 != state.workspaceID else { say("FAIL no new window"); return }
                store.activate(w2)
                try? await Task.sleep(for: .seconds(0.5))
                say(focusOK(w2) ? "PASS detached tab has the keyboard" : "FAIL detached focus: \(String(describing: store.window(of: w2)?.firstResponder))")
                // Drag b and c into w2 (as a drop on its tab bar): the first window is left empty and closes.
                TabBarCenter.shared.beginDrag(b.id)
                TabBarCenter.shared.drop(b.id, into: w2, before: nil)
                TabBarCenter.shared.beginDrag(c.id)
                TabBarCenter.shared.drop(c.id, into: w2, before: nil)
                try? await Task.sleep(for: .seconds(1.5))
                let firstGone = state.window?.isVisible != true
                say(firstGone && store.workspace(w2).tabs.count == 3 ? "PASS empty window closed after merge" : "FAIL merge: first visible=\(!firstGone) tabs=\(store.workspace(w2).tabs.count)")
                say(focusOK(w2) ? "PASS merged window has the keyboard" : "FAIL merged focus: \(String(describing: store.window(of: w2)?.firstResponder))")
                // Real drag paths with screen points: out of every window → its own window at once;
                // onto another window's tab bar → into that window, the empty one closes.
                @MainActor func screenPoint(onBarOf ws: UUID) -> CGPoint? {
                    guard let w = store.window(of: ws), let content = w.contentView, let bar = TabBarCenter.shared.barFrames[ws] else { return nil }
                    let local = CGPoint(x: bar.midX, y: content.bounds.height - bar.midY)
                    return w.convertPoint(toScreen: local)
                }
                let outside = CGPoint(x: (store.window(of: w2)?.frame.maxX ?? 0) + 300, y: (store.window(of: w2)?.frame.midY ?? 300))
                let t0 = Date()
                TabBarCenter.shared.dragChanged(b.id, title: "b", at: outside)
                TabBarCenter.shared.dragEnded(b.id, at: outside)
                try? await Task.sleep(for: .milliseconds(100))
                let w4 = store.workspace(containing: b.id)
                say(w4 != nil && w4 != w2 ? "PASS dropped outside → new window in \(Int(Date().timeIntervalSince(t0) * 1000)) ms" : "FAIL drop outside")
                try? await Task.sleep(for: .seconds(1))
                if let w4, let p = screenPoint(onBarOf: w2) {
                    TabBarCenter.shared.dragChanged(b.id, title: "b", at: p)
                    let lit = TabBarCenter.shared.dropTarget == w2
                    TabBarCenter.shared.dragEnded(b.id, at: p)
                    try? await Task.sleep(for: .seconds(1))
                    say(lit && store.workspace(containing: b.id) == w2 && store.window(of: w4)?.isVisible != true
                        ? "PASS dropped on other tab bar (highlighted, empty window closed)" : "FAIL drop on bar lit=\(lit)")
                } else { say("FAIL no bar point") }
                // Close question: open a third window with one tab, ask to close it, choose Move.
                guard let st2 = store.state(ofWorkspace: w2) else { say("FAIL no state"); return }
                st2.present(c.id, mode: .window)
                try? await Task.sleep(for: .seconds(1.5))
                guard let w3 = store.workspace(containing: c.id), w3 != w2, let st3 = store.state(ofWorkspace: w3), let win3 = st3.window else { say("FAIL third window"); return }
                st3.requestCloseWindow()
                try? await Task.sleep(for: .seconds(0.8))
                guard let sheet = win3.attachedSheet else { say("FAIL no close question"); return }
                let buttons = (sheet.contentView?.subviews ?? []).flatMap { [$0] + $0.subviews }.compactMap { ($0 as? NSButton)?.title }
                say("question buttons \(buttons)")
                win3.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                try? await Task.sleep(for: .seconds(1))
                say(!win3.isVisible && store.workspace(containing: c.id) == w2 ? "PASS moved tabs on close" : "FAIL move on close")
                say("DONE")
                if env["TETHER_SELFTEST_KEEP"] == nil { NSApp.terminate(nil) }
            }
            return
        }

        // Sidebar follows the selected tab, and sessions sort / reorder under their host. TETHER_SELFTEST_SIDEBAR=1.
        if env["TETHER_SELFTEST_SIDEBAR"] != nil {
            Task { @MainActor in
                state.window?.setFrame(NSRect(x: 80, y: 80, width: 1100, height: 700), display: true)
                let a = state.connect(.local), b = state.connect(.local), c = state.connect(.local)
                model.sessions.rename(a.id, to: "charlie"); model.sessions.rename(b.id, to: "alpha"); model.sessions.rename(c.id, to: "bravo")
                try? await Task.sleep(for: .seconds(1))
                @MainActor func check(_ s: TerminalSession, _ label: String) {
                    say(state.sidebarSelection == .session(s.id) ? "PASS \(label)" : "FAIL \(label): \(String(describing: state.sidebarSelection))")
                }
                check(c, "newest tab selected in sidebar")
                state.sidebarSelection = .host("local")          // e.g. the user clicked a host
                SidebarFolding.shared.collapsed.insert("local")    // and folded This Mac
                model.workspaces.select(a.id, in: state.workspaceID)
                try? await Task.sleep(for: .milliseconds(500))
                check(a, "clicking a tab selects it in the sidebar")
                say(SidebarFolding.shared.collapsed.contains("local") ? "FAIL still folded" : "PASS unfolded")
                model.settings.sessionSortOrder = .manual
                model.sessions.reorder([c.id, a.id, b.id])
                let order = model.sessions.sessions(for: "local").map(\.displayTitle)
                say(order == ["bravo", "charlie", "alpha"] ? "PASS manual order" : "FAIL manual order \(order)")
                try? await Task.sleep(for: .milliseconds(500))
                SelfTest.snapshot(state.window, "sidebar-manual")
                model.settings.sessionSortOrder = .name
                try? await Task.sleep(for: .milliseconds(500))
                SelfTest.snapshot(state.window, "sidebar-name")
                let all = model.sessions.sessions(for: "local")
                for order in SessionSortOrder.allCases {
                    say("order \(order.rawValue): \(HostChildren.ordered(all, by: order).map(\.displayTitle))")
                }
                model.settings.sessionSortOrder = .status
                // Tab bar: live reordering while a tab is dragged over the others.
                let center = TabBarCenter.shared
                let ws = state.workspaceID
                @MainActor func titles() -> [String] { model.workspaces.workspace(ws).tabs.compactMap { model.sessions.session($0)?.displayTitle } }
                say("tabs before \(titles())")
                center.beginDrag(a.id)
                center.dragMoved(over: b.id, x: 1, in: ws)        // not past the middle yet: stays
                let early = titles()
                center.dragMoved(over: b.id, x: 500, in: ws)      // past the middle of alpha
                let afterB = titles()
                center.dragMoved(over: c.id, x: 500, in: ws)      // and of bravo
                let afterC = titles()
                center.dragMoved(over: b.id, x: 0, in: ws)        // back to the left of alpha
                let back = titles()
                center.drop(a.id, into: ws, before: nil)          // released over empty bar space
                let dropped = titles()
                say("drag \(early) \(afterB) \(afterC) \(back) \(dropped)")
                say(early == ["charlie", "alpha", "bravo"] && afterB == ["alpha", "charlie", "bravo"]
                    && afterC == ["alpha", "bravo", "charlie"] && back == ["charlie", "alpha", "bravo"] && dropped == back
                    ? "PASS live reorder" : "FAIL live reorder")
                say("DONE")
                if env["TETHER_SELFTEST_KEEP"] == nil { NSApp.terminate(nil) }
            }
            return
        }

        // Host key check against a real sshd whose key differs from the trusted one: the warning, removing
        // the old key, the first-connection question for the new key, and connecting. TETHER_SELFTEST_HOSTKEY=1.
        if env["TETHER_SELFTEST_HOSTKEY"] != nil {
            Task { @MainActor in
                if let cfg = env["TETHER_SELFTEST_SSHCONFIG"] { model.settings.sshConfigPath = cfg }
                model.settings.useControlMaster = true
                let host = ConnectionTarget.alias(env["TETHER_SELFTEST_HOST"] ?? "loadtest")
                state.window?.setFrame(NSRect(x: 80, y: 80, width: 1100, height: 760), display: true)
                let s = state.connect(host)
                for _ in 0..<150 where !s.phase.isDead { try? await Task.sleep(for: .milliseconds(100)) }
                guard let change = s.progress?.hostKeyChange else { say("FAIL no host key change: \(s.phase.label) \(s.lastError ?? "")"); return }
                say("PASS change host=\(change.host) fp=\(change.fingerprint != nil) line=\(change.line ?? -1) ended=\(s.endedByConnectionFailure)")
                try? await Task.sleep(for: .seconds(1))
                SelfTest.snapshot(state.window, "hostkey-changed")
                if let error = await change.removeOldKey() { say("FAIL remove \(error)"); return }
                s.retryAfterFailure()
                for _ in 0..<100 where model.prompts.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
                guard let p = model.prompts.first else { say("FAIL no new-key question"); return }
                say(p.request.isConfirmation && UnknownHostKey.parse(p.request.prompt) != nil ? "PASS new-key question" : "FAIL question: \(p.request.prompt)")
                try? await Task.sleep(for: .seconds(1))
                if let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) { SelfTest.snapshot(panel, "hostkey-new") }
                if env["TETHER_SELFTEST_NOANSWER"] != nil { say("WAITING"); return }
                model.resolvePrompt(p, answer: "yes", save: false)
                for _ in 0..<150 where !s.phase.isOnline { try? await Task.sleep(for: .milliseconds(100)) }
                say(s.phase.isOnline ? "PASS online after trusting" : "FAIL \(s.phase.label)")
                say("DONE")
                if env["TETHER_SELFTEST_KEEP"] == nil { NSApp.terminate(nil) }
            }
            return
        }

        // File manager check against a real sshd: home folder, back/forward, the clickable path, the
        // owner column, and the tab bar once it overflows. TETHER_SELFTEST_FILES=1 (+ _SSHCONFIG, _HOST).
        if env["TETHER_SELFTEST_FILES"] != nil {
            Task { @MainActor in
                if let cfg = env["TETHER_SELFTEST_SSHCONFIG"] { model.settings.sshConfigPath = cfg }
                model.settings.useControlMaster = true
                let host = ConnectionTarget.alias(env["TETHER_SELFTEST_HOST"] ?? "loadtest")
                state.window?.setFrame(NSRect(x: 80, y: 80, width: 1100, height: 700), display: true)
                let term = state.connect(host)
                for _ in 0..<100 where !term.phase.isOnline { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(2))
                SelfTest.snapshot(state.window, "terminal-footer")
                state.openFiles(host)
                guard case .files(let tab)? = state.selectedItem else { say("FAIL no file tab"); return }
                let b = model.fileTabs.browser(for: tab)
                for _ in 0..<100 where b.directory.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
                let home = b.directory
                say("home=\(home.isEmpty ? "?" : "ok") owners=\(b.files.filter { !$0.owner.isEmpty }.count)/\(b.files.count)")
                SelfTest.snapshot(state.window, "files-home")
                await b.load("/usr")
                await b.load("/usr/bin")
                await b.back()
                let afterBack = b.directory
                await b.forward()
                say("back=\(afterBack) forward=\(b.directory) path=\(b.pathComponents.map(\.name).joined(separator: ">"))")
                say(afterBack == "/usr" && b.directory == "/usr/bin" ? "PASS history" : "FAIL history")
                await b.back(); await b.back()
                say(b.directory == home ? "PASS back home" : "FAIL back home \(b.directory)")
                SelfTest.snapshot(state.window, "files-nav")
                state.window?.setFrame(NSRect(x: 40, y: 40, width: 1700, height: 800), display: true)
                try? await Task.sleep(for: .seconds(1))
                SelfTest.snapshot(state.window, "files-wide")
                b.selection = Set(b.files.prefix(1).map(\.id))
                state.window?.setFrame(NSRect(x: 80, y: 80, width: 1100, height: 700), display: true)
                try? await Task.sleep(for: .seconds(1))
                SelfTest.snapshot(state.window, "files-narrow-selected")
                for _ in 0..<25 { state.openFiles(host, path: "/tmp") }
                try? await Task.sleep(for: .seconds(2))
                SelfTest.snapshot(state.window, "tabs-overflow")
                say("DONE")
                if env["TETHER_SELFTEST_KEEP"] == nil { NSApp.terminate(nil) }
            }
            return
        }

        // Load test against a real sshd: open many tabs to one host as fast as possible and watch
        // whether any session (old or new) drops. TETHER_SELFTEST_LOAD=<count>, TETHER_SELFTEST_SSHCONFIG=<file>.
        if let count = env["TETHER_SELFTEST_LOAD"].flatMap(Int.init) {
            Task { @MainActor in
                if let cfg = env["TETHER_SELFTEST_SSHCONFIG"] { model.settings.sshConfigPath = cfg }
                model.settings.useControlMaster = true
                model.settings.recordingEnabled = env["TETHER_SELFTEST_RECORD"] != nil
                model.settings.defaultPersistence = .tmux
                let host = ConnectionTarget.alias(env["TETHER_SELFTEST_HOST"] ?? "loadtest")
                try? await Task.sleep(for: .seconds(1))
                var everLost = Set<UUID>()
                var everDead = Set<UUID>()
                let sampler = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        for s in model.sessions.sessions {
                            if case .waiting = s.phase, s.wasOnline { everLost.insert(s.id) }
                            if s.phase.isDead { everDead.insert(s.id) }
                        }
                    }
                }
                // A first batch, then a burst while those are online.
                for _ in 0..<min(count, 4) { state.connect(host, mode: .tab) }
                for _ in 0..<120 where !model.sessions.sessions.allSatisfy({ $0.phase.isOnline }) {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                say("first batch online=\(model.sessions.sessions.filter(\.phase.isOnline).count)")
                if env["TETHER_SELFTEST_BUSY"] != nil {
                    // The old sessions are busy: a stream of output while the burst connects.
                    for s in model.sessions.sessions {
                        s.send(Array("i=0; while [ $i -lt 400000 ]; do echo \"line $i $(date +%s)\"; i=$((i+1)); done\r".utf8)[...])
                    }
                }
                let t0 = Date()
                for _ in 0..<max(count - 4, 0) { state.connect(host, mode: .tab) }
                for _ in 0..<240 where !model.sessions.sessions.allSatisfy({ $0.phase.isOnline || $0.phase.isDead }) {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                let ready = Date().timeIntervalSince(t0)
                try? await Task.sleep(for: .seconds(15))   // do the old ones survive the burst?
                let fds = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
                var limit = rlimit()
                getrlimit(RLIMIT_NOFILE, &limit)
                say("open file descriptors: \(fds) (limit \(limit.rlim_cur))")
                sampler.invalidate()
                let all = model.sessions.sessions
                let slots = Dictionary(grouping: all, by: \.controlSlot).mapValues(\.count).sorted { $0.key < $1.key }
                say("load: \(all.count) sessions, online=\(all.filter(\.phase.isOnline).count) waiting=\(all.filter { if case .waiting = $0.phase { true } else { false } }.count) dead=\(all.filter(\.phase.isDead).count) everLost=\(everLost.count) everDead=\(everDead.count) ready in \(Int(ready)) s slots=\(slots)")
                for s in all where s.phase.isDead || !s.phase.isOnline { say("  \(s.phase.label): \(s.lastError ?? "") \(s.progress?.failure ?? "")") }
                if env["TETHER_SELFTEST_CLOSETIMING"] != nil {
                    // Fill every terminal's history, then close the tabs one by one through the UI path.
                    for s in model.sessions.sessions {
                        s.send(Array("i=0; while [ $i -lt 12000 ]; do echo \"history line $i of a long session\"; i=$((i+1)); done\r".utf8)[...])
                    }
                    try? await Task.sleep(for: .seconds(20))
                    model.settings.confirmCloseOnlineSessions = false
                    if env["TETHER_SELFTEST_RESIZE"] != nil, let w = state.window {
                        // The hidden terminals now have a stale size: each one revealed by a close must adapt.
                        w.setFrame(NSRect(x: w.frame.minX, y: w.frame.minY, width: w.frame.width - 260, height: w.frame.height - 120), display: true)
                        try? await Task.sleep(for: .seconds(1))
                    }
                    var gap = 0.0
                    var tick = Date()
                    let ticker = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
                        let now = Date(); gap = max(gap, now.timeIntervalSince(tick)); tick = now
                    }
                    var durations: [Int] = []
                    for s in Array(model.sessions.sessions) {
                        let target = model.workspaces.workspace(containing: s.id).flatMap { model.workspaces.state(ofWorkspace: $0) } ?? state
                        let t0 = Date()
                        target.closeTab(s)
                        durations.append(Int(Date().timeIntervalSince(t0) * 1000))
                        try? await Task.sleep(for: .milliseconds(400))
                    }
                    ticker.invalidate()
                    say("close timing: per closeTab ms max=\(durations.max() ?? 0) avg=\(durations.isEmpty ? 0 : durations.reduce(0, +) / durations.count); longest main-thread pause \(Int(gap * 1000)) ms")
                }
                for s in model.sessions.sessions { model.sessions.close(s.id, killRemote: true) }
                try? await Task.sleep(for: .seconds(2))
                say("done")
            }
            return
        }
        // Window layout across quit and relaunch: "save" arranges two windows and quits properly,
        // "check" reports what came back.
        if let mode = env["TETHER_SELFTEST_LAYOUT"] {
            Task { @MainActor in
                @MainActor func describe() -> String {
                    NSApp.orderedWindows.compactMap { w -> String? in
                        guard let id = model.workspaces.workspace(of: w), w.isVisible else { return nil }
                        let ws = model.workspaces.workspace(id)
                        return "[\(Int(w.frame.origin.x)),\(Int(w.frame.origin.y)) \(Int(w.frame.width))x\(Int(w.frame.height)) tabs=\(ws.tabs.count) selected=\(ws.selected.map { ws.tabs.firstIndex(of: $0) ?? -1 } ?? -1)]"
                    }.joined(separator: " ")
                }
                if mode == "save" {
                    try? await Task.sleep(for: .seconds(1))
                    for _ in 0..<3 { state.connect(target, mode: .tab); try? await Task.sleep(for: .seconds(1)) }
                    for _ in 0..<40 where !model.sessions.sessions.allSatisfy({ $0.phase.isOnline }) {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    say("online \(model.sessions.sessions.count)")
                    state.window?.setFrame(NSRect(x: 120, y: 140, width: 1100, height: 700), display: true)
                    try? await Task.sleep(for: .seconds(1))
                    say("resized")
                    if let first = state.tabs.first { state.select(first) }
                    if let last = state.tabs.last { state.present(last.id, mode: .window) }
                    try? await Task.sleep(for: .seconds(2))
                    say("second window")
                    NSApp.orderedWindows.first { $0 !== state.window && model.workspaces.workspace(of: $0) != nil }?
                        .setFrame(NSRect(x: 400, y: 200, width: 800, height: 500), display: true)
                    try? await Task.sleep(for: .seconds(1))
                    say("saved \(describe())")
                    say("done")
                    if env["TETHER_SELFTEST_CRASH"] != nil {
                        try? await Task.sleep(for: .seconds(2.5))   // the layout is written about 1.5 s after changes
                        kill(getpid(), SIGKILL)                     // like a crash: no quit handling at all
                    }
                    NSApp.terminate(nil)
                } else {
                    try? await Task.sleep(for: .seconds(6))
                    say("restored \(describe())")
                    say("done")
                }
            }
            return
        }
        if env["TETHER_SELFTEST_RESTORE_ONLY"] != nil {
            Task { @MainActor in
                say("restore-only start sessions=\(model.sessions.sessions.count)")
                try? await Task.sleep(for: .seconds(12))
                say("restore-only phases \(model.sessions.sessions.map(\.phase.label)) tabs=\(state.items.count)")
                say("done")
            }
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            snapshot(state.window, "01-welcome")
            say("start")
            for i in 0..<3 {
                state.connect(target, mode: .tab)
                say("opened \(i)")
                try? await Task.sleep(for: .seconds(1.5))
            }
            for _ in 0..<40 where !model.sessions.sessions.allSatisfy({ $0.phase.isOnline }) {
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .seconds(8))
            // Live resizing through narrow widths must never loop in AppKit's layout.
            if let w = state.window {
                for width in [1400.0, 1000, 760, 640, 900, 1280] {
                    w.setFrame(NSRect(x: 120, y: 120, width: width, height: 720), display: true)
                    try? await Task.sleep(for: .milliseconds(400))
                }
                say("resized through widths ok, now \(Int(w.frame.width))")
            }
            let m = model.monitor(for: target)
            say("monitor host=\(m.snapshot?.hostname ?? "nil") cpu=\(m.snapshot?.cpuUsage ?? -1) streaming=\(m.isStreaming) frames=\(m.history.count) err=\(m.error ?? "-")")
            say("latency \(model.sessions.sessions.map { LatencyStats.format($0.latency.median) + " " + $0.latency.quality.rawValue })")
            say("titles \(model.sessions.sessions.map(\.displayTitle))")
            say("remote sessions \(m.remoteSessions.map(\.name))")
            snapshot(state.window, "02-terminals")
            model.settings.showSidebarArchive = true
            try? await Task.sleep(for: .seconds(0.5))
            snapshot(state.window, "03-archive-shown")
            // Search: write a marker into each terminal, find it, jump to it.
            for s in model.sessions.sessions {
                TerminalRegistry.shared.existingView(for: s.id)?.send(source: TerminalRegistry.shared.existingView(for: s.id)!,
                                                                     data: Array("echo needle-\(s.id.uuidString.prefix(4))\r".utf8)[...])
            }
            try? await Task.sleep(for: .seconds(1.5))
            let search = SearchModel()
            search.query.pattern = "needle-[0-9A-F]{4}"
            search.query.isRegex = true
            search.filters.archive = false
            search.run()
            for _ in 0..<40 where search.running { try? await Task.sleep(for: .milliseconds(100)) }
            say("search groups=\(search.groups.count) matches=\(search.totalMatches) err=\(search.error ?? "-")")
            if let g = search.groups.first, let m = g.matches.last, case .live(let id, let base) = g.source.kind {
                let view = TerminalRegistry.shared.existingView(for: id)
                view?.reveal(invariantRow: base + m.line, columns: m.ranges.first.map { $0.location..<($0.location + $0.length) })
                say("reveal selection=\(view?.getSelection() ?? "nil")")
            }
            model.searchPreset = SearchPreset(host: nil, session: nil, query: "needle")
            model.openSearch?()
            try? await Task.sleep(for: .seconds(3))
            snapshot(NSApp.windows.first { $0.title == "Search" }, "05-search")
            model.searchPreset = SearchPreset(host: nil, session: nil, query: "")
            try? await Task.sleep(for: .seconds(1))
            snapshot(NSApp.windows.first { $0.title == "Search" }, "06-search-empty")
            let help = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
            help.isReleasedWhenClosed = false
            help.contentView = NSHostingView(rootView: ShortcutsView())
            help.orderFront(nil)
            try? await Task.sleep(for: .seconds(1))
            snapshot(help, "07-shortcuts")
            help.close()
            // A sudo-style prompt in the terminal shows the password bar; entering clears it.
            if let s = state.session, let view = TerminalRegistry.shared.existingView(for: s.id) {
                view.send(source: view, data: Array("printf '[sudo] password for demo: '; stty -echo; read x; stty echo; echo \"got ${#x}\"\r".utf8)[...])
                try? await Task.sleep(for: .seconds(1.5))
                say("prompt kind=\(s.passwordPrompt?.kind.rawValue ?? "none") user=\(s.passwordPrompt?.user ?? "-") saved=\(model.hasSavedPassword(for: s))")
                snapshot(state.window, "09-password-bar")
                model.enterPassword("selftest-pw", in: s, save: false)
                try? await Task.sleep(for: .seconds(1))
                say("prompt after enter=\(s.passwordPrompt == nil ? "cleared" : "still there")")
            }
            // Pasted image → upload sheet (private pasteboard; the user's clipboard is not touched).
            let pb = NSPasteboard(name: NSPasteboard.Name("tether-selftest"))
            pb.clearContents()
            pb.writeObjects([NSImage(size: NSSize(width: 8, height: 8), flipped: false) { NSColor.blue.setFill(); $0.fill(); return true }])
            if let files = PasteboardFiles.filesToPaste(from: pb), let s = state.session {
                TerminalRegistry.shared.existingView(for: s.id)?.onFiles?(files)
                try? await Task.sleep(for: .seconds(1))
                say("paste image files=\(files.map(\.lastPathComponent)) sheet=\(state.uploadRequest != nil)")
                snapshot(state.window?.attachedSheet, "08-upload-sheet")
                state.uploadRequest = nil
                files.forEach { try? FileManager.default.removeItem(at: $0) }
            } else {
                say("paste image failed")
            }
            pb.releaseGlobally()
            // Transfers popover: sizes to its rows; removing a row keeps the layout intact.
            let tdir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-selftest-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tdir.appendingPathComponent("out"), withIntermediateDirectories: true)
            let tfiles = (1...3).map { tdir.appendingPathComponent("sample-\($0).txt") }
            for f in tfiles { try? Data("hello".utf8).write(to: f) }
            model.transfers.uploadGroup(tfiles, names: tfiles.map(\.lastPathComponent), to: tdir.appendingPathComponent("out").path,
                                        target: .local, fileCount: 3, totalBytes: 15, pack: false)
            try? await Task.sleep(for: .seconds(1.5))
            let host = NSHostingView(rootView: TransfersView().environment(model))
            let tw = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
            tw.isReleasedWhenClosed = false
            tw.contentView = host
            tw.orderFront(nil)
            try? await Task.sleep(for: .seconds(0.5))
            say("transfers size \(host.fittingSize) items=\(model.transfers.items.map { "\($0.state)" })")
            snapshot(tw, "09-transfers")
            if let first = model.transfers.items.first { model.transfers.remove(first) }
            try? await Task.sleep(for: .seconds(0.8))
            tw.setContentSize(host.fittingSize)
            say("transfers size after remove \(host.fittingSize)")
            snapshot(tw, "10-transfers-removed")
            tw.close()
            try? FileManager.default.removeItem(at: tdir)
            say("phases \(model.sessions.sessions.map { "\($0.phase)" })")
            say("windows \(NSApp.windows.filter(\.isVisible).count) tabs \(state.workspace.tabs.count)")
            // File manager tab: open, list, switch away and back, move to background.
            state.openFiles(target, path: "/")
            try? await Task.sleep(for: .seconds(2))
            if case .files(let ft)? = state.selectedItem {
                let b = model.fileTabs.browser(for: ft)
                say("files tab dir=\(b.directory) count=\(b.files.count) items=\(state.items.count)")
                b.selection = Set(b.visibleFiles.prefix(1).map(\.id))
                state.select(state.tabs[0])
                state.select(ft.id)
                say("files tab after switch dir=\(b.directory) selection=\(b.selection.count)")
                // Select a folder (details load with long text), open it, select again.
                for _ in 0..<3 {
                    guard let dir = b.visibleFiles.first(where: { $0.isDirectory }) else { break }
                    b.selection = [dir.id]
                    try? await Task.sleep(for: .seconds(1.5))
                    await b.load(dir.path)
                    try? await Task.sleep(for: .seconds(0.5))
                    if let f = b.visibleFiles.first { b.selection = [f.id] }
                    try? await Task.sleep(for: .seconds(1))
                }
                say("files tab navigated dir=\(b.directory)")
                snapshot(state.window, "04-files-tab")
                state.moveToBackground(.files(ft))
                say("files tab background=\(model.workspaces.workspace(containing: ft.id) == nil) stillExists=\(model.fileTabs.tab(ft.id) != nil)")
            } else {
                say("files tab missing")
            }
            // Many sessions on one host: the sidebar shows the first ones and "Show N more".
            // Responsiveness while many sessions connect: the main thread should keep ticking.
            var maxGap = 0.0
            var last = Date()
            let ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                let now = Date()
                maxGap = max(maxGap, now.timeIntervalSince(last))
                last = now
            }
            for _ in 0..<9 { state.connect(target, mode: .tab) }
            for _ in 0..<60 where !model.sessions.sessions.allSatisfy({ $0.phase.isOnline }) {
                try? await Task.sleep(for: .milliseconds(250))
            }
            try? await Task.sleep(for: .seconds(2))
            say("many sessions=\(model.sessions.sessions(for: target.key).count) online=\(model.sessions.sessions.filter(\.phase.isOnline).count)")
            ticker.invalidate()
            say("main thread longest pause while connecting: \(Int(maxGap * 1000)) ms")
            snapshot(state.window, "11-many-sessions")
            // Tab bar: the mouse wheel scrolls it sideways; a middle click closes the tab under it.
            if let w = state.window, let content = w.contentView {
                let center = TabBarCenter.shared
                let before = center.tabScrollOffset(in: w) ?? -1
                let lastID = state.items.last?.id
                if let lastID, let r = center.tabFrames[lastID] {
                    let barPoint = CGPoint(x: r.midX - 200, y: content.bounds.height - r.midY)
                    let scrolled = center.scrollTabs(by: -300, at: barPoint, in: w)
                    try? await Task.sleep(for: .milliseconds(300))
                    say("wheel scrolled=\(scrolled) offset \(Int(before)) -> \(Int(center.tabScrollOffset(in: w) ?? -1))")
                }
                model.settings.confirmCloseOnlineSessions = false
                let count = state.items.count
                if let first = state.items.first, let r = center.tabFrames[first.id] {
                    let closed = center.closeTab(at: CGPoint(x: r.midX, y: r.midY), in: w)
                    try? await Task.sleep(for: .milliseconds(500))
                    say("middle click closed=\(closed) tabs \(count) -> \(state.items.count)")
                }
                // The same middle click on a terminal's row in the sidebar closes it too.
                if let (id, r) = Self.sidebarRow(in: w, workspace: state.workspaceID) {
                    let before = state.items.count
                    let closed = center.closeTab(at: CGPoint(x: r.midX, y: r.midY), in: w)
                    try? await Task.sleep(for: .milliseconds(500))
                    let gone = !state.items.contains { $0.id == id }
                    say("\(closed && gone ? "PASS" : "FAIL") sidebar middle click closed=\(closed) tabs \(before) -> \(state.items.count)")
                } else {
                    say("FAIL sidebar middle click: no sidebar row with a terminal")
                }
            }
            if ProcessInfo.processInfo.environment["TETHER_SELFTEST_KEEP"] != nil { say("keeping"); return }
            // Switch through the tabs, then close them.
            let start = Date()
            for s in state.tabs { state.select(s) }
            say("switched \(state.tabs.count) tabs in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            // Detach a tab into its own window, then close everything while measuring how long the
            // main thread is busy (closing must never freeze the app).
            if let s = state.tabs.last {
                state.present(s.id, mode: .window)
                try? await Task.sleep(for: .seconds(2))
                say("detached tab windows=\(NSApp.windows.filter { $0.isVisible && model.workspaces.workspace(of: $0) != nil }.count)")
            }
            var closeGap = 0.0
            var lastTick = Date()
            let closeTicker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                let now = Date()
                closeGap = max(closeGap, now.timeIntervalSince(lastTick))
                lastTick = now
            }
            var slowestClose = 0.0
            for s in model.sessions.sessions {
                say("closing \(s.id) phase=\(s.phase.label) inTab=\(state.workspace.tabs.contains(s.id)) window=\(state.window != nil)")
                let t0 = Date()
                if let ws = model.workspaces.workspace(containing: s.id), let other = model.workspaces.state(ofWorkspace: ws) {
                    other.closeTab(s)
                } else {
                    state.closeTab(s)
                }
                slowestClose = max(slowestClose, Date().timeIntervalSince(t0))
                try? await Task.sleep(for: .seconds(1))
                if let w = state.window, let sheet = w.attachedSheet {
                    say("answering sheet")
                    w.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                    try? await Task.sleep(for: .seconds(1))
                }
                say("closed; sessions=\(model.sessions.sessions.count) background=\(model.sessions.background.count)")
            }
            closeTicker.invalidate()
            say("closing: slowest closeTab \(Int(slowestClose * 1000)) ms, longest main-thread pause \(Int(closeGap * 1000)) ms")
            say("done")
        }
    }
}
/// A drag as AppKit hands it to a drop target, for dropping without a mouse.
final class SelfTestDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
#endif
