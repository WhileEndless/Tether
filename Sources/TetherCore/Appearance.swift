import Foundation

/// Light or dark for the app's windows (the terminal's colours are chosen separately).
public enum AppAppearance: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// The size of text and icons in the app's windows (sidebar, tabs, host panel).
public enum UITextSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case small, standard, large, extraLarge
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .small: "Small"
        case .standard: "Default"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }
    public var scale: Double {
        switch self {
        case .small: 0.9
        case .standard: 1
        case .large: 1.15
        case .extraLarge: 1.3
        }
    }
    public var bigger: UITextSize? { Self.allCases.firstIndex(of: self).flatMap { $0 + 1 < Self.allCases.count ? Self.allCases[$0 + 1] : nil } }
    public var smaller: UITextSize? { Self.allCases.firstIndex(of: self).flatMap { $0 > 0 ? Self.allCases[$0 - 1] : nil } }
}

/// How the sidebar lays out hosts and sessions.
public enum SidebarStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Sections, two-line host rows, status capsules and hover buttons.
    case detailed
    /// The same sections, one line per row.
    case compact
    /// A Finder-like tree: groups are folders, hosts open to their sessions.
    case folders
    /// Names only; status shows only when something needs you.
    case minimal
    /// Every host in one list, without groups.
    case flat

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .detailed: "Detailed"
        case .compact: "Compact"
        case .folders: "Folders"
        case .minimal: "Minimal"
        case .flat: "Flat"
        }
    }
    public var summary: String {
        switch self {
        case .detailed: "Addresses, status and buttons on every row."
        case .compact: "One line per host and session."
        case .folders: "Groups as folders, hosts open to their sessions."
        case .minimal: "Names only. Status shows when something needs you."
        case .flat: "All hosts in one list, without groups."
        }
    }
    public var symbol: String {
        switch self {
        case .detailed: "list.bullet.rectangle"
        case .compact: "list.dash"
        case .folders: "folder"
        case .minimal: "text.alignleft"
        case .flat: "list.bullet"
        }
    }
    /// Rows have room for the user@host line.
    public var canShowDetails: Bool { self == .detailed || self == .flat }
    /// Rows have room for hover buttons.
    public var canShowRowButtons: Bool { self != .minimal }
    /// Section and folder rows can show counts.
    public var canShowCounts: Bool { self != .minimal }
}

/// Where the terminal's colours come from. Independent of the app's appearance: a light app can
/// keep a dark terminal.
public enum TerminalColorMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The light theme while the app is light, the dark theme while it is dark.
    case followApp
    case alwaysLight
    case alwaysDark
    /// Colours (and optionally the font) of a Terminal.app profile.
    case terminalApp

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .followApp: "Match the App"
        case .alwaysLight: "Always Light"
        case .alwaysDark: "Always Dark"
        case .terminalApp: "Terminal.app Profile"
        }
    }
}

/// Built-in terminal colour themes.
public enum TerminalPalette: String, Codable, CaseIterable, Identifiable, Sendable {
    case tetherLight, paper, rosePineDawn, solarizedLight, gruvboxLight, basicLight
    case tetherDark, graphite, solarizedDark, oneDark, dracula, nord, gruvboxDark, tokyoNight, basicDark

    public var id: String { rawValue }
    public var isDark: Bool {
        switch self {
        case .tetherLight, .paper, .rosePineDawn, .solarizedLight, .gruvboxLight, .basicLight: false
        default: true
        }
    }
    public var title: String {
        switch self {
        case .tetherLight: "Tether Light"
        case .paper: "Paper"
        case .solarizedLight: "Solarized Light"
        case .rosePineDawn: "Rosé Pine Dawn"
        case .gruvboxLight: "Gruvbox Light"
        case .basicLight: "Basic Light"
        case .tetherDark: "Tether Dark"
        case .graphite: "Graphite"
        case .solarizedDark: "Solarized Dark"
        case .oneDark: "One Dark"
        case .dracula: "Dracula"
        case .nord: "Nord"
        case .gruvboxDark: "Gruvbox Dark"
        case .tokyoNight: "Tokyo Night"
        case .basicDark: "Basic Dark"
        }
    }
    /// Designed for Tether: soft backgrounds (never pure white or black) and every normal colour
    /// readable on its background (WCAG AA). The others keep the colours their authors chose.
    public var isTetherDesigned: Bool { [.tetherLight, .paper, .tetherDark, .graphite].contains(self) }
    public static var light: [TerminalPalette] { allCases.filter { !$0.isDark } }
    public static var dark: [TerminalPalette] { allCases.filter(\.isDark) }
}
