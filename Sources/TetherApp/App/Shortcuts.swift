import SwiftUI

/// Every keyboard shortcut in Tether, in one place. Menus use `key`; the Keyboard Shortcuts
/// window lists the same entries, so the reference can never drift from what the app does.
///
/// Rules the set follows:
/// - Anything with ⌘ belongs to the app; keys without ⌘ (Ctrl, Option-as-Meta, Esc, function keys)
///   always reach the terminal, so vim, emacs, tmux key bindings and fzf keep working.
/// - Terminal.app / Safari conventions are kept wherever they exist (⌘T, ⌘K, ⌘1…9, ⇧⌘[ ], ⌘↑/⌘↓).
struct Shortcut: Identifiable {
    enum Category: String, CaseIterable, Identifiable {
        case connections = "Connections"
        case tabs = "Tabs and Windows"
        case session = "Session"
        case terminal = "Terminal"
        case search = "Find and Search"
        case files = "Files"
        case view = "View"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .connections: "network"
            case .tabs: "square.on.square"
            case .session: "terminal"
            case .terminal: "text.cursor"
            case .search: "magnifyingglass"
            case .files: "folder"
            case .view: "eye"
            }
        }
    }

    let title: String
    let category: Category
    /// The menu key equivalent, if this shortcut is a menu command.
    let key: KeyboardShortcut?
    /// How the keys are shown (also used for shortcuts that are not menu commands).
    let display: String
    var note: String?

    var id: String { category.rawValue + title }

    init(_ title: String, _ category: Category, _ key: KeyboardShortcut, note: String? = nil) {
        self.title = title
        self.category = category
        self.key = key
        self.display = Self.describe(key)
        self.note = note
    }

    /// A shortcut handled outside the menus (terminal navigation, alternates).
    init(_ title: String, _ category: Category, display: String, note: String? = nil) {
        self.title = title
        self.category = category
        self.key = nil
        self.display = display
        self.note = note
    }

    static func describe(_ k: KeyboardShortcut) -> String {
        var s = ""
        if k.modifiers.contains(.control) { s += "⌃" }
        if k.modifiers.contains(.option) { s += "⌥" }
        if k.modifiers.contains(.shift) { s += "⇧" }
        if k.modifiers.contains(.command) { s += "⌘" }
        switch k.key {
        case .upArrow: s += "↑"
        case .downArrow: s += "↓"
        case .leftArrow: s += "←"
        case .rightArrow: s += "→"
        case .tab: s += "Tab"
        case .delete: s += "⌫"
        case .return: s += "↩"
        case .escape: s += "Esc"
        default: s += String(k.key.character).uppercased()
        }
        return s
    }

    private static func k(_ c: Character, _ m: EventModifiers = .command) -> KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(c), modifiers: m)
    }

    // MARK: Connections
    static let newConnection = Shortcut("New Connection…", .connections, k("n"))
    static let newTab = Shortcut("New Tab to Same Host", .connections, k("t"),
                                 note: "Opens a new session to the host of the current tab")
    static let newLocalTerminal = Shortcut("New Local Terminal", .connections, k("t", [.command, .option]))
    static let newWindow = Shortcut("New Window", .connections, k("n", [.command, .shift]))
    static let addHost = Shortcut("Add Host…", .connections, k("h", [.command, .shift]))
    static let editConfig = Shortcut("Edit SSH Config File…", .connections, k("h", [.command, .option, .shift]))

    // MARK: Tabs and windows
    static let closeTab = Shortcut("Close Tab", .tabs, display: "⌘W",
                                   note: "A running session asks whether to keep it in the background")
    static let closeWindow = Shortcut("Close Window", .tabs, k("w", [.command, .shift]))
    static let previousTab = Shortcut("Show Previous Tab", .tabs, k("[", [.command, .shift]))
    static let nextTab = Shortcut("Show Next Tab", .tabs, k("]", [.command, .shift]))
    static let cycleAlternates = Shortcut("Next / Previous Tab", .tabs, display: "⌃Tab  ⌃⇧Tab  ⌥⌘→  ⌥⌘←")
    static let tabNumbers = Shortcut("Show Tab 1…8 / Last Tab", .tabs, display: "⌘1 … ⌘8  ⌘9",
                                     note: "Hold ⌘ to see the numbers on the tabs")
    static let goToSession = Shortcut("Go to Session…", .tabs, k("p"))
    static let moveTabToWindow = Shortcut("Move Tab to New Window", .tabs, k("m", [.command, .shift]))
    static let mergeWindows = Shortcut("Merge All Windows", .tabs, k("m", [.command, .option, .shift]))
    static let renameTab = Shortcut("Rename Tab…", .tabs, k("r", [.command, .shift]), note: "Or double-click the tab")

    // MARK: Session
    static let reconnect = Shortcut("Reconnect Now", .session, k("r"), note: "While a session is waiting")
    static let moveToBackground = Shortcut("Move Tab to Background", .session, k("b", [.command, .shift]),
                                           note: "Keeps the session running and connected")
    static let disconnect = Shortcut("Disconnect & Move to Background", .session, k("b", [.command, .option, .shift]),
                                     note: "Drops the connection; tmux/screen keeps running on the server")
    static let terminate = Shortcut("Terminate Session…", .session, k("w", [.command, .option, .shift]),
                                    note: "Stops the shell on the server (asks first)")

    // MARK: Terminal
    static let clearScrollback = Shortcut("Clear Scrollback", .terminal, k("k"))
    static let clearScreen = Shortcut("Clear Screen", .terminal, display: "⌃L", note: "Handled by the shell")
    static let copy = Shortcut("Copy / Paste / Select All", .terminal, display: "⌘C  ⌘V  ⌘A",
                               note: "Pasting files uploads them and pastes their remote paths")
    static let jumpMarks = Shortcut("Jump to Previous / Next Command", .terminal, display: "⌘↑  ⌘↓")
    static let selectMarks = Shortcut("Select Previous / Next Command Output", .terminal, display: "⇧⌘↑  ⇧⌘↓")
    static let scrollPage = Shortcut("Scroll Page Up / Down", .terminal, display: "PgUp  PgDn",
                                 note: "Add ⌘ inside full-screen apps such as vim or less")
    static let scrollEnds = Shortcut("Scroll to Top / Bottom", .terminal, display: "Home  End",
                                 note: "Add ⌘ inside full-screen apps such as vim or less")
    static let biggerFont = Shortcut("Bigger Font", .terminal, k("+"), note: "⌘= works too")
    static let smallerFont = Shortcut("Smaller Font", .terminal, k("-"))
    static let defaultFont = Shortcut("Default Font Size", .terminal, k("0"))

    // MARK: Find and search
    static let find = Shortcut("Find in Terminal…", .search, k("f"))
    static let findNext = Shortcut("Find Next", .search, k("g"))
    static let findPrevious = Shortcut("Find Previous", .search, k("g", [.command, .shift]))
    static let useSelection = Shortcut("Use Selection for Find", .search, k("e"))
    static let searchAll = Shortcut("Search All Sessions…", .search, k("f", [.command, .shift]),
                                    note: "Open terminals, archive and recordings")
    static let searchSession = Shortcut("Search in This Session…", .search, k("f", [.command, .option]))

    // MARK: Files
    static let browseHere = Shortcut("Browse Files Here", .files, k("o", [.command, .shift]),
                                     note: "File manager tab in the terminal's current directory")
    static let filesWindow = Shortcut("Open File Manager Window", .files, k("o", [.command, .option]))
    static let transfers = Shortcut("Show Transfers", .files, k("l", [.command, .option]))
    static let fileCopyPaste = Shortcut("Copy to Mac / Paste from Mac", .files, display: "⌘C  ⌘V",
                                        note: "In the file manager; works with Finder")
    static let fileOpen = Shortcut("Open / Go Up", .files, display: "↩  ⌘↓  ⌘↑")
    static let fileDelete = Shortcut("Delete", .files, display: "⌘⌫", note: "Asks first")

    // MARK: View
    static let toggleSidebar = Shortcut("Show / Hide Sidebar", .view, display: "⌃⌘S")
    static let hostPanel = Shortcut("Show / Hide Host Panel", .view, k("i", [.command, .option]))
    static let showArchive = Shortcut("Show Archive in Sidebar", .view, k("a", [.command, .option]))
    static let statusBar = Shortcut("Show Host Status Bar", .view, k("s", [.command, .option]))
    static let settings = Shortcut("Settings…", .view, display: "⌘,")
    static let shortcuts = Shortcut("Keyboard Shortcuts", .view, k("/"))

    static let all: [Shortcut] = [
        newConnection, newTab, newLocalTerminal, newWindow, addHost, editConfig,
        closeTab, closeWindow, previousTab, nextTab, cycleAlternates, tabNumbers, goToSession, moveTabToWindow,
        mergeWindows, renameTab,
        reconnect, moveToBackground, disconnect, terminate,
        clearScrollback, clearScreen, copy, jumpMarks, selectMarks, scrollPage, scrollEnds,
        biggerFont, smallerFont, defaultFont,
        find, findNext, findPrevious, useSelection, searchAll, searchSession,
        browseHere, filesWindow, transfers, fileCopyPaste, fileOpen, fileDelete,
        toggleSidebar, hostPanel, showArchive, statusBar, settings, shortcuts,
    ]
}

extension View {
    /// Applies a catalogued shortcut.
    @ViewBuilder
    func shortcut(_ s: Shortcut) -> some View {
        if let key = s.key { keyboardShortcut(key) } else { self }
    }
}
