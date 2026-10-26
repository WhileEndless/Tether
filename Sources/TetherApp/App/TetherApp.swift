import SwiftUI
import TetherCore
import SessionKit

@main
struct TetherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    init() {
        CrashLog.installIfRequested()
        // A pipe or socket whose other end is gone (an ssh, scp or the askpass helper that already
        // ended) must give a write error, not end the app: by default SIGPIPE terminates silently,
        // without even a crash report.
        signal(SIGPIPE, SIG_IGN)
        Self.raiseOpenFileLimit()
        // Tether has its own tabs per window; native window tabbing stays off.
        UserDefaults.standard.removeObject(forKey: "AppleWindowTabbingMode")
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// Apps started from Finder may only open 256 files. Every terminal uses several (pseudo-terminal,
    /// pipes, its recording), so dozens of tabs would run out — new tabs fail and old ones cannot
    /// reconnect. Raise the limit to what the system allows (up to 16384).
    static func raiseOpenFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let wanted = rlim_t(16_384)
        let target = min(wanted, limit.rlim_max)
        if limit.rlim_cur < target {
            limit.rlim_cur = target
            setrlimit(RLIMIT_NOFILE, &limit)
        }
    }

    var body: some Scene {
        // Every window is a native tab: drag tabs out into their own windows, drop them into another
        // window's tab bar, or use Window ▸ Merge All Windows.
        WindowGroup("Tether", id: "workspace", for: UUID.self) { $workspaceID in
            WorkspaceRoot(workspaceID: $workspaceID)
                .tetherAppearance()
                .appLockCover()
                .environment(model)
                .frame(minWidth: 640, minHeight: 360)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { TetherCommands(model: model) }

        WindowGroup("Transcript", id: "transcript", for: TranscriptRequest.self) { $request in
            if let request {
                TranscriptWindow(request: request)
                    .tetherAppearance()
                    .appLockCover()
                    .environment(model)
                    .standaloneWindow()
            }
        }
        .defaultSize(width: 900, height: 600)

        WindowGroup("Files", id: "files", for: FilesRequest.self) { $request in
            if let request {
                FilesWindow(request: request)
                    .tetherAppearance()
                    .appLockCover()
                    .environment(model)
                    .standaloneWindow()
                    .frame(minWidth: 640, minHeight: 400)
            }
        }
        .defaultSize(width: 1000, height: 640)

        Window("Search", id: "search") {
            SearchView()
                .tetherAppearance()
                .appLockCover()
                .environment(model)
                .frame(minWidth: 760, minHeight: 480)
                .standaloneWindow()
        }
        .defaultSize(width: 1100, height: 720)

        Window("Keyboard Shortcuts", id: "shortcuts") {
            ShortcutsView()
                .frame(minWidth: 460, minHeight: 360)
                .standaloneWindow()
        }
        .defaultSize(width: 560, height: 680)

        Window("About Tether", id: "about") {
            AboutView()
                .standaloneWindow()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Window("Set Up Tether", id: "setup") {
            AppearanceSetupView()
                .tetherAppearance(scalesInterface: false)
                .appLockCover()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .tetherAppearance(scalesInterface: false)
                .appLockCover()
                .environment(model)
        }

        // Closing the last window leaves Tether running here (Settings ▸ General).
        MenuBarExtra("Tether", systemImage: "point.3.connected.trianglepath.dotted",
                     isInserted: Binding(get: { model.settings.keepRunningInMenuBar },
                                         set: { model.settings.keepRunningInMenuBar = $0 })) {
            MenuBarContent()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        MainActor.assumeIsolated {
            AppModel.shared.launch()
            Notifier.shared.install()
            Self.reportTamperedSettings()
            TabBarCenter.shared.start()
            installCloseTabShortcut()
            // After the first window is up, so the notice never blocks starting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Updater.shared.checkAtLaunch() }
        }
    }

    /// Security settings changed outside Tether were put back at launch: say so once.
    @MainActor
    private static func reportTamperedSettings() {
        let names = AppModel.shared.settingsStore.tamperedSecuritySettings
        let review = AppModel.shared.settingsStore.unpinnedNonDefaults
        if names.isEmpty, !review.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let alert = NSAlert()
                alert.messageText = "Please check your security settings"
                alert.informativeText = "Tether now keeps a copy of its security settings in your keychain. These differ from the defaults, so make sure you set them yourself: \(review.joined(separator: ", ")). Settings ▸ Security, Passwords and SSH."
                alert.runModal()
            }
            return
        }
        guard !names.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Security settings were changed outside Tether"
            alert.informativeText = "These settings no longer matched the copy kept in your keychain, so Tether put them back: \(names.joined(separator: ", ")). Another program may have edited Tether's preferences. Change them in Settings ▸ Security if you want something else."
            alert.runModal()
        }
    }

    private var keyMonitor: Any?

    /// ⌘W closes the selected tab; only a window without tabs closes itself. A local monitor runs
    /// before menu key equivalents, so this wins over File ▸ Close. Also handles shortcut alternates
    /// that would otherwise clutter the menus (see `Shortcut`).
    @MainActor
    private func installCloseTabShortcut() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if AppLock.shared.isLocked {
                // Keys go to lock screens only (windows and sheets show one), never to a hidden panel.
                if let window = event.window, window is NSPanel, !window.isSheet { return nil }
                return event
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard let window = event.window, let state = AppModel.shared.workspaces.state(of: window) else { return event }
            let model = AppModel.shared
            switch (event.keyCode, flags) {
            case (13, [.command]):                                   // ⌘W
                guard let item = state.selectedItem else { return event }
                state.close(item)
            // Alternates for Show Next/Previous Tab (Safari and Terminal.app habits).
            case (48, [.control]), (124, [.command, .option]):        // ⌃Tab, ⌥⌘→
                model.workspaces.selectNeighbour(in: state.workspaceID, offset: 1)
            case (48, [.control, .shift]), (123, [.command, .option]): // ⌃⇧Tab, ⌥⌘←
                model.workspaces.selectNeighbour(in: state.workspaceID, offset: -1)
            case (36, [.command]), (76, [.command]):                 // ⌘↩: Quick Connect, typing in the search
                guard !state.showQuickConnect else { return event }
                state.quickConnectSearch = true
                state.showQuickConnect = true
            case (24, [.command]):                                   // ⌘= as Bigger
                model.adjustFont(+1)
            default:
                return event
            }
            return nil
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            WindowLayout.saveOpenWindows()
            AppModel.shared.isTerminating = true
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.fileTabs.saveDirectories()
            AppModel.shared.sessions.prepareForTermination()
            AppModel.shared.stopCommandHubs()
            AppModel.shared.commandHistory.flush()
            DeferredWrites.shared.flush()
        }
    }
}

/// Gives a fresh window its own workspace id (stored by SwiftUI, so windows restore with their tabs).
struct WorkspaceRoot: View {
    @Binding var workspaceID: UUID?

    var body: some View {
        if let workspaceID {
            WorkspaceWindow(workspaceID: workspaceID).id(workspaceID)
        } else {
            // At launch this is the frontmost window of the last run, with its tabs.
            Color.clear.onAppear { workspaceID = WindowLayout.firstWorkspaceAtLaunch() }
        }
    }
}
