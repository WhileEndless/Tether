#if DEBUG
import AppKit
import SwiftUI
import TetherCore
import SessionKit
import SSHTransport
import TerminalUI

/// Debug-only scripted UI run used to reproduce window/tab problems without a person at the keyboard.
/// Enabled with TETHER_SELFTEST=<log file> and TETHER_SSH_BINARY=<fake ssh>; always combine with
/// TETHER_SUPPORT_DIR and TETHER_DEFAULTS_SUITE so real user data is never touched.
@MainActor
enum SelfTest {
    private static var started = false

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

    static func runIfRequested(state: WindowState) {
        let env = ProcessInfo.processInfo.environment
        guard !started, let logPath = env["TETHER_SELFTEST"], let ssh = env["TETHER_SSH_BINARY"],
              env["TETHER_SUPPORT_DIR"] != nil, env["TETHER_DEFAULTS_SUITE"] != nil else { return }
        started = true
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
        if env["TETHER_SELFTEST_NOBLINK"] != nil { model.settings.cursorBlink = false }
        model.settings.showStatusStrip = env["TETHER_SELFTEST_NOSTRIP"] == nil
        model.settings.cursorBlink = env["TETHER_SELFTEST_NOBLINK"] == nil ? model.settings.cursorBlink : false
        model.settings.showSidebarArchive = false
        model.settings.requireAuthForSavedPasswords = false
        if env["TETHER_SELFTEST_NOINSPECTOR"] != nil { state.sidebarSelection = nil; state.showInspectorRequest = false }
        let target = ConnectionTarget.adhoc(user: nil, host: "selftest.local", port: nil, jump: nil)

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
#endif
