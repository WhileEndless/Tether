import SwiftUI
import SessionKit
import TerminalUI
import TetherCore

struct ActiveSessionKey: FocusedValueKey {
    typealias Value = UUID
}

extension FocusedValues {
    var activeSessionID: UUID? {
        get { self[ActiveSessionKey.self] }
        set { self[ActiveSessionKey.self] = newValue }
    }
}

struct TetherCommands: Commands {
    let model: AppModel
    @FocusedValue(\.windowState) private var focusedWindow
    /// No window while Tether is locked, so menu commands do nothing behind the lock screen.
    private var window: WindowState? { AppLock.shared.isLocked ? nil : focusedWindow }
    @Environment(\.openWindow) private var openWindow

    private var active: TerminalSession? { window?.session }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Tether") { openWindow(id: "about") }
        }
        CommandGroup(after: .appSettings) {
            Button("Lock Tether") { AppLock.shared.lock() }
                .shortcut(.lockApp)
                .disabled(model.settings.appLockMode == .off || AppLock.shared.isLocked)
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }
                .shortcut(.shortcuts)
            Divider()
            Link("Tether on GitHub", destination: AppInfo.repository)
            Link("Release Notes", destination: AppInfo.releases)
            Link("Report an Issue…", destination: AppInfo.issues)
        }
        SidebarCommands()

        CommandGroup(replacing: .newItem) {
            Button("New Connection…") {
                if let window { window.showQuickConnect = true } else { openWindow(id: "workspace") }
            }
            .shortcut(.newConnection)
            Button(window?.selectedItem.map { if case .files = $0 { true } else { false } } == true
                   ? "New File Manager Tab" : "New Tab to Same Host") {
                guard let window else { return }
                // In a file manager, ⌘T opens another file manager there (like a Finder window), not a terminal.
                if case .files(let f)? = window.selectedItem {
                    let dir = model.fileTabs.browser(for: f).directory
                    window.openFiles(f.target, path: dir.isEmpty ? f.path : dir)
                } else if let active {
                    window.newSession(like: active)
                } else if let t = window.inspectedTarget {
                    window.connect(t, mode: .tab)
                } else {
                    window.showQuickConnect = true
                }
            }
            .shortcut(.newTab)
            Button("New Local Terminal") {
                if let window { window.connect(.local) } else { openWindow(id: "workspace") }
            }
            .shortcut(.newLocalTerminal)
            Button("New Private Tab") {
                if let window, let active { window.newSession(like: active, isPrivate: true) }
                else if let window { window.connect(window.inspectedTarget ?? .local, isPrivate: true) }
                else { openWindow(id: "workspace") }
            }
            .shortcut(.newPrivateTab)
            Button("New Window") { openWindow(id: "workspace", value: UUID()) }
                .shortcut(.newWindow)
            Divider()
            Button("Browse Files Here") {
                if let t = active?.descriptor.target ?? window?.inspectedTarget { window?.browse(t, path: active?.currentDirectory) }
            }
            .shortcut(.browseHere)
            .disabled(window?.inspectedTarget == nil)
            Button("Open File Manager Window") {
                if let t = active?.descriptor.target ?? window?.inspectedTarget {
                    openWindow(id: "files", value: FilesRequest(target: t, path: active?.currentDirectory))
                }
            }
            .shortcut(.filesWindow)
            .disabled(window?.inspectedTarget == nil)
            Divider()
            Button("Add Host…") { window?.hostEditor = HostEditorRequest() }
                .shortcut(.addHost)
            Button("Edit SSH Config File…") { window?.showConfigEditor = true }
                .shortcut(.editConfig)
        }
        CommandGroup(after: .saveItem) {
            Button("Save Session…") { if let active { SessionSave.run(active) } }
                .shortcut(.saveSession)
                .disabled(active == nil)
            Button("Close Window") {
                if let window, window.window === NSApp.keyWindow { window.requestCloseWindow() }
                else { NSApp.keyWindow?.performClose(nil) }
            }
                .shortcut(.closeWindow)
        }

        CommandMenu("Session") {
            Button("Reconnect Now") { active?.reconnectNow() }
                .shortcut(.reconnect)
                .disabled(active.map { if case .waiting = $0.phase { false } else { true } } ?? true)
            Button("New Session to Same Host in New Window") {
                if let active { window?.newSession(like: active, mode: .window) }
            }
            .disabled(active == nil)
            Divider()
            Button("Rename Tab…") { window?.renamingSession = active }
                .shortcut(.renameTab)
                .disabled(active == nil)
            Menu("Tab Color") {
                ForEach(TagColor.allCases) { c in
                    Button(c.title) { if let id = active?.id { model.sessions.setColor(id, c) } }
                }
            }
            .disabled(active == nil)
            Divider()
            Button("Move Tab to Background") { if let item = window?.selectedItem { window?.moveToBackground(item) } }
                .shortcut(.moveToBackground)
                .disabled(window?.selectedItem == nil)
            Button("Disconnect & Move to Background") { if let active { window?.disconnectToBackground(active) } }
                .shortcut(.disconnect)
                .disabled(active.map { $0.phase.isDead || $0.descriptor.target.isLocal } ?? true)
            Button("Fill or Enter Password") { if let active { model.fillOrEnterPassword(in: active, state: window) } }
                .shortcut(.fillPassword)
                .disabled(active?.passwordPrompt == nil)
            Button("Enter Password…") { window?.passwordEntry = active }
                .disabled(active?.passwordPrompt == nil)
            Button("Terminate Session…") { if let active { window?.terminate(active) } }
                .shortcut(.terminate)
                .disabled(active.map { $0.phase.isDead } ?? true)
            Divider()
            Button("Clear Scrollback") {
                if let id = active?.id { TerminalRegistry.shared.existingView(for: id)?.clearBuffer() }
            }
            .shortcut(.clearScrollback)
            .disabled(active == nil)
        }

        CommandGroup(before: .windowList) {
            Button("Show Previous Tab") { cycle(-1) }
                .shortcut(.previousTab)
            Button("Show Next Tab") { cycle(1) }
                .shortcut(.nextTab)
            Menu("Show Tab") {
                ForEach(1..<10) { n in
                    Button(n == 9 ? "Last Tab" : "Tab \(n)") {
                        if let window { model.workspaces.select(index: n == 9 ? -1 : n - 1, in: window.workspaceID) }
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(n))))
                }
            }
            Button("Go to Session…") { window?.showSwitcher = true }
                .shortcut(.goToSession)
            Divider()
            Button("Move Tab to New Window") { if let active { window?.present(active.id, mode: .window) } }
                .shortcut(.moveTabToWindow)
                .disabled(active == nil)
            Button("Merge All Windows") { if let window { model.workspaces.mergeAll(into: window.workspaceID) } }
                .shortcut(.mergeWindows)
            Divider()
            Button("Transfers") { window?.showTransfers.toggle() }
                .shortcut(.transfers)
            Button("Search") { openWindow(id: "search") }
            Divider()
        }

        CommandGroup(after: .toolbar) {
            Button("Show or Hide Host Panel") { window?.toggleInspector.toggle() }
                .shortcut(.hostPanel)
            Button("Show Running Command") { window?.showRunningCommand() }
                .shortcut(.runningCommand)
                .disabled(window?.session == nil)
            Toggle("Show Archive in Sidebar", isOn: Binding(get: { model.settings.showSidebarArchive },
                                                            set: { model.settings.showSidebarArchive = $0 }))
                .shortcut(.showArchive)
            Toggle("Show Host Status Bar", isOn: Binding(get: { model.settings.showStatusStrip },
                                                         set: { model.settings.showStatusStrip = $0 }))
                .shortcut(.statusBar)
            Divider()
            Button("Bigger") { model.adjustFont(+1) }
                .shortcut(.biggerFont)
            Button("Smaller") { model.adjustFont(-1) }
                .shortcut(.smallerFont)
            Button("Default Size") {
                model.settings.fontFromProfile = true
                model.settings.fontSize = 12
                model.settingsChanged()
            }
            .shortcut(.defaultFont)
        }

        CommandGroup(after: .textEditing) {
            Button("Search All Sessions…") { openWindow(id: "search") }
                .shortcut(.searchAll)
            Button("Search in This Session…") {
                model.searchPreset = SearchPreset(host: nil, session: active?.id)
                openWindow(id: "search")
            }
            .shortcut(.searchSession)
            .disabled(active == nil)
            Divider()
            Button("Find…") { sendFind(.showFindInterface) }.shortcut(.find)
            Button("Find Next") { sendFind(.nextMatch) }.shortcut(.findNext)
            Button("Find Previous") { sendFind(.previousMatch) }.shortcut(.findPrevious)
            Button("Use Selection for Find") { sendFind(.setSearchString) }.shortcut(.useSelection)
        }
    }

    private func cycle(_ offset: Int) {
        if let window { model.workspaces.selectNeighbour(in: window.workspaceID, offset: offset) }
    }

    private func sendFind(_ action: NSTextFinder.Action) {
        // Terminals use Tether's find bar (match count, highlighted matches); other views
        // (transcripts) keep their own.
        if let id = active?.id, let view = TerminalRegistry.shared.existingView(for: id) {
            let selected = view.getSelection().flatMap { $0.isEmpty || $0.contains("\n") ? nil : $0 }
            var find = model.terminalFind[id] ?? TerminalFind(term: "")
            switch action {
            case .nextMatch, .previousMatch:
                if model.terminalFind[id] != nil {
                    model.terminalFindStep[id] = AppModel.FindStep(forward: action == .nextMatch)
                    return
                }
                guard let term = FindPasteboard.get(), !term.isEmpty else { NSSound.beep(); return }
                find.term = term
            case .setSearchString:
                guard let selected else { NSSound.beep(); return }
                FindPasteboard.set(selected)
                find.term = selected
            default:
                if let selected { find.term = selected } else if find.term.isEmpty { find.term = FindPasteboard.get() ?? "" }
            }
            find.anchorRow = nil
            find.focusToken = UUID()
            model.terminalFind[id] = find
            return
        }
        let item = NSMenuItem()
        item.tag = action.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: item)
    }
}

extension AppModel {
    /// Changes the font size. If the Terminal.app profile font is in use, it becomes the starting point.
    func adjustFont(_ delta: CGFloat) {
        let current = settings.terminalFont
        settings.fontName = current.fontName
        settings.fontSize = Double(min(max(current.pointSize + delta, 8), 40))
        settings.fontFromProfile = false
        settingsChanged()
    }
}
