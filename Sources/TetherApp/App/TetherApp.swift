import SwiftUI
import TetherCore
import SessionKit

@main
struct TetherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    init() {
        // Tether has its own tabs per window; native window tabbing stays off.
        UserDefaults.standard.removeObject(forKey: "AppleWindowTabbingMode")
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        // Every window is a native tab: drag tabs out into their own windows, drop them into another
        // window's tab bar, or use Window ▸ Merge All Windows.
        WindowGroup("Tether", id: "workspace", for: UUID.self) { $workspaceID in
            WorkspaceRoot(workspaceID: $workspaceID)
                .environment(model)
                .frame(minWidth: 640, minHeight: 360)
        }
        .defaultSize(width: 1280, height: 800)
        .commands { TetherCommands(model: model) }

        WindowGroup("Transcript", id: "transcript", for: TranscriptRequest.self) { $request in
            if let request {
                TranscriptWindow(request: request)
                    .environment(model)
                    .standaloneWindow()
            }
        }
        .defaultSize(width: 900, height: 600)

        WindowGroup("Files", id: "files", for: FilesRequest.self) { $request in
            if let request {
                FilesWindow(request: request)
                    .environment(model)
                    .standaloneWindow()
                    .frame(minWidth: 640, minHeight: 400)
            }
        }
        .defaultSize(width: 1000, height: 640)

        Window("Search", id: "search") {
            SearchView()
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

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        MainActor.assumeIsolated {
            AppModel.shared.launch()
            TabBarCenter.shared.start()
            installCloseTabShortcut()
        }
    }

    private var keyMonitor: Any?

    /// ⌘W closes the selected tab; only a window without tabs closes itself. A local monitor runs
    /// before menu key equivalents, so this wins over File ▸ Close. Also handles shortcut alternates
    /// that would otherwise clutter the menus (see `Shortcut`).
    @MainActor
    private func installCloseTabShortcut() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
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
            case (24, [.command]):                                   // ⌘= as Bigger
                model.adjustFont(+1)
            default:
                return event
            }
            return nil
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppModel.shared.isTerminating = true }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.fileTabs.saveDirectories()
            AppModel.shared.sessions.prepareForTermination()
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
            Color.clear.onAppear { workspaceID = UUID() }
        }
    }
}
