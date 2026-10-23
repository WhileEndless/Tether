import AppKit
import SwiftTerm
import TetherCore

/// A terminal colour scheme. ANSI colours are 16 entries (normal + bright).
public struct TerminalTheme {
    public var foreground: NSColor
    public var background: NSColor
    public var cursor: NSColor
    public var selection: NSColor
    public var ansi: [SwiftTerm.Color]
    /// Blur radius requested by a translucent Terminal.app profile (0 = none).
    public var backgroundBlur: Double = 0

    /// Only clearly see-through profiles get a blurred background; nearly opaque ones
    /// (e.g. Clear Dark at 95%) look better and cleaner as a solid colour.
    public var isTranslucent: Bool { background.alphaComponent < 0.85 }

    /// Resolves the theme for the current settings and appearance.
    public static func resolve(_ settings: AppSettings, appearance: NSAppearance) -> TerminalTheme {
        resolve(settings.theme, profileName: settings.terminalProfile, appearance: appearance)
    }

    public static func resolve(_ choice: TerminalThemeChoice, profileName: String = "",
                               appearance: NSAppearance) -> TerminalTheme {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        switch choice {
        case .system:
            if let p = TerminalAppProfile.load(profileName.isEmpty ? nil : profileName) {
                return fromProfile(p, fallback: dark ? basicDark : basicLight)
            }
            return dark ? basicDark : basicLight
        case .light: return basicLight
        case .dark: return basicDark
        case .solarizedDark: return solarized(dark: true)
        case .solarizedLight: return solarized(dark: false)
        }
    }

    /// Builds a theme from a Terminal.app profile, filling gaps from `fallback`.
    static func fromProfile(_ p: TerminalAppProfile, fallback: TerminalTheme) -> TerminalTheme {
        let ansi = p.ansi.enumerated().map { i, c -> SwiftTerm.Color in
            guard let c else { return fallback.ansi[i] }
            return SwiftTerm.Color(red: UInt16(c.redComponent * 65535), green: UInt16(c.greenComponent * 65535),
                                   blue: UInt16(c.blueComponent * 65535))
        }
        var background = p.background ?? fallback.background
        if background.alphaComponent >= 0.85 { background = background.withAlphaComponent(1) }
        return TerminalTheme(foreground: p.foreground ?? fallback.foreground,
                             background: background,
                             cursor: p.cursor ?? (p.foreground ?? fallback.foreground).withAlphaComponent(0.6),
                             selection: p.selection ?? fallback.selection,
                             ansi: ansi, backgroundBlur: p.backgroundBlur)
    }

    private static func c(_ r: Int, _ g: Int, _ b: Int) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(r * 257), green: UInt16(g * 257), blue: UInt16(b * 257))
    }

    private static func ns(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// The ANSI palette used by Terminal.app's default profiles.
    static let terminalAppPalette: [SwiftTerm.Color] = [
        c(0, 0, 0), c(153, 0, 0), c(0, 166, 0), c(153, 153, 0),
        c(0, 0, 178), c(178, 0, 178), c(0, 166, 178), c(191, 191, 191),
        c(102, 102, 102), c(229, 0, 0), c(0, 217, 0), c(229, 229, 0),
        c(0, 0, 255), c(229, 0, 229), c(0, 229, 229), c(229, 229, 229),
    ]

    static let basicLight = TerminalTheme(
        foreground: ns(0, 0, 0), background: ns(255, 255, 255),
        cursor: ns(127, 127, 127), selection: ns(178, 215, 255), ansi: terminalAppPalette)

    static let basicDark = TerminalTheme(
        foreground: ns(255, 255, 255), background: ns(30, 30, 30),
        cursor: ns(170, 170, 170), selection: ns(63, 99, 139), ansi: terminalAppPalette)

    static func solarized(dark: Bool) -> TerminalTheme {
        let palette: [SwiftTerm.Color] = [
            c(7, 54, 66), c(220, 50, 47), c(133, 153, 0), c(181, 137, 0),
            c(38, 139, 210), c(211, 54, 130), c(42, 161, 152), c(238, 232, 213),
            c(0, 43, 54), c(203, 75, 22), c(88, 110, 117), c(101, 123, 131),
            c(131, 148, 150), c(108, 113, 196), c(147, 161, 161), c(253, 246, 227),
        ]
        return dark
            ? TerminalTheme(foreground: ns(131, 148, 150), background: ns(0, 43, 54), cursor: ns(147, 161, 161),
                            selection: ns(7, 54, 66), ansi: palette)
            : TerminalTheme(foreground: ns(101, 123, 131), background: ns(253, 246, 227), cursor: ns(88, 110, 117),
                            selection: ns(238, 232, 213), ansi: palette)
    }
}

public extension AppSettings {
    /// The font to use: the Terminal.app profile's font when "use profile font" is on,
    /// otherwise the configured font (or the system monospaced font).
    var terminalFont: NSFont {
        if fontFromProfile, theme == .system,
           let f = TerminalAppProfile.load(terminalProfile.isEmpty ? nil : terminalProfile)?.font {
            return f
        }
        let size = CGFloat(max(fontSize, 6))
        if !fontName.isEmpty, let f = NSFont(name: fontName, size: size) { return f }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var swiftTermCursor: CursorStyle {
        switch (cursorShape, cursorBlink) {
        case (.block, true): .blinkBlock
        case (.block, false): .steadyBlock
        case (.underline, true): .blinkUnderline
        case (.underline, false): .steadyUnderline
        case (.bar, true): .blinkBar
        case (.bar, false): .steadyBar
        }
    }
}
