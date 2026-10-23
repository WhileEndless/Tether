#if DEBUG
import AppKit
import SwiftUI
import TetherCore
import SessionKit
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
        if env["TETHER_SELFTEST_NOINSPECTOR"] != nil { state.sidebarSelection = nil; state.showInspectorRequest = false }
        let target = ConnectionTarget.adhoc(user: nil, host: "selftest.local", port: nil, jump: nil)

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
            help.contentView = NSHostingView(rootView: ShortcutsView())
            help.orderFront(nil)
            try? await Task.sleep(for: .seconds(1))
            snapshot(help, "07-shortcuts")
            help.close()
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
            if ProcessInfo.processInfo.environment["TETHER_SELFTEST_KEEP"] != nil { say("keeping"); return }
            // Switch through the tabs, then close them.
            let start = Date()
            for s in state.tabs { state.select(s) }
            say("switched \(state.tabs.count) tabs in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            for s in model.sessions.sessions {
                say("closing \(s.id) phase=\(s.phase.label) inTab=\(state.workspace.tabs.contains(s.id)) window=\(state.window != nil)")
                state.closeTab(s)
                try? await Task.sleep(for: .seconds(1))
                if let w = state.window, let sheet = w.attachedSheet {
                    say("answering sheet")
                    w.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                    try? await Task.sleep(for: .seconds(1))
                }
                say("closed; sessions=\(model.sessions.sessions.count) background=\(model.sessions.background.count)")
            }
            say("done")
        }
    }
}
#endif
