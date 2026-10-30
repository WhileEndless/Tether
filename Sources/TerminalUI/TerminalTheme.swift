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

    /// ANSI colour `index` (0–15) as an `NSColor`, for previews.
    public func ansiNSColor(_ index: Int) -> NSColor {
        let c = ansi[min(max(index, 0), ansi.count - 1)]
        return NSColor(srgbRed: CGFloat(c.red) / 65535, green: CGFloat(c.green) / 65535, blue: CGFloat(c.blue) / 65535, alpha: 1)
    }

    /// Resolves the theme for the current settings and the appearance of the view it is shown in
    /// (the app's appearance, which may differ from the system's).
    public static func resolve(_ settings: AppSettings, appearance: NSAppearance) -> TerminalTheme {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        switch settings.terminalColors {
        case .terminalApp:
            let name = settings.terminalProfile
            if let p = TerminalAppProfile.load(name.isEmpty ? nil : name) {
                return fromProfile(p, fallback: dark ? basicDark : basicLight)
            }
            return dark ? basicDark : basicLight
        case .followApp: return palette(dark ? settings.terminalDarkTheme : settings.terminalLightTheme)
        case .alwaysLight: return palette(settings.terminalLightTheme)
        case .alwaysDark: return palette(settings.terminalDarkTheme)
        }
    }

    /// The theme `settings` would show for a given appearance (previews in Settings and setup).
    public static func resolve(_ settings: AppSettings, dark: Bool) -> TerminalTheme {
        resolve(settings, appearance: NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance)
    }

    /// Builds a theme from a Terminal.app profile, filling gaps from `fallback`.
    static func fromProfile(_ p: TerminalAppProfile, fallback: TerminalTheme) -> TerminalTheme {
        let ansi = p.ansi.enumerated().map { i, c -> SwiftTerm.Color in
            guard let c else { return fallback.ansi[i] }
            func channel(_ v: CGFloat) -> UInt16 { UInt16((min(max(v, 0), 1) * 65535).rounded()) }
            return SwiftTerm.Color(red: channel(c.redComponent), green: channel(c.greenComponent), blue: channel(c.blueComponent))
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

extension TerminalTheme {
    private static func hex(_ v: UInt32) -> SwiftTerm.Color { c(Int(v >> 16 & 0xff), Int(v >> 8 & 0xff), Int(v & 0xff)) }
    private static func nsHex(_ v: UInt32) -> NSColor { ns(Int(v >> 16 & 0xff), Int(v >> 8 & 0xff), Int(v & 0xff)) }

    private static func make(fg: UInt32, bg: UInt32, cursor: UInt32, selection: UInt32, _ ansi: [UInt32]) -> TerminalTheme {
        TerminalTheme(foreground: nsHex(fg), background: nsHex(bg), cursor: nsHex(cursor),
                      selection: nsHex(selection), ansi: ansi.map(hex))
    }

    /// A built-in theme. Tether's own (Tether Light/Dark, Paper, Graphite) use soft backgrounds and
    /// keep every normal colour readable on them; the others use the colours published by their
    /// authors (Rosé Pine, Solarized, Gruvbox, One Dark, Dracula, Nord, Tokyo Night — all MIT or
    /// similarly free palettes). Light themes keep ANSI black dark, so programs that print in black
    /// stay readable.
    public static func palette(_ p: TerminalPalette) -> TerminalTheme {
        switch p {
        case .tetherLight:
            make(fg: 0x2B2B2E, bg: 0xF7F6F2, cursor: 0x4A4A55, selection: 0xD3DEEC, [
                0x2B2B2E, 0xB3261E, 0x2E7D32, 0x8A6100, 0x1F5FAD, 0x8E3FA8, 0x0F7480, 0xA8A7A2,
                0x6E6E73, 0xC9372C, 0x3B8C3F, 0x9E7100, 0x2F72C4, 0xA052BC, 0x168896, 0xD9D8D2])
        case .paper:
            make(fg: 0x3B3631, bg: 0xF4EFE6, cursor: 0x5A534B, selection: 0xE1D7C4, [
                0x3B3631, 0xA8322D, 0x4A7426, 0x86650F, 0x2F6390, 0x8A4A8F, 0x2A7670, 0xB5ACA0,
                0x7A7167, 0xC2453F, 0x5F8F33, 0xA67F1A, 0x3B78AD, 0xA05AA6, 0x33918A, 0xDCD3C5])
        case .rosePineDawn:
            make(fg: 0x575279, bg: 0xFAF4ED, cursor: 0x9893A5, selection: 0xDFDAD9, [
                0x575279, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0x9893A5,
                0x797593, 0xB4637A, 0x286983, 0xEA9D34, 0x56949F, 0x907AA9, 0xD7827E, 0xCECACD])
        case .solarizedLight: solarized(dark: false)
        case .gruvboxLight:
            make(fg: 0x3C3836, bg: 0xFBF1C7, cursor: 0x3C3836, selection: 0xD5C4A1, [
                0x3C3836, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
                0x928374, 0x9D0006, 0x79740E, 0xB57614, 0x076678, 0x8F3F71, 0x427B58, 0xD5C4A1])
        case .basicLight: basicLight
        case .tetherDark:
            make(fg: 0xD8DAE0, bg: 0x1E2024, cursor: 0xAEB4C0, selection: 0x3A4556, [
                0x2A2D33, 0xE87A7A, 0x8CC07A, 0xE2C077, 0x6FA8E8, 0xC792D8, 0x66C2CD, 0xC5C8CF,
                0x6B717D, 0xF08F8F, 0xA3D48F, 0xF0D08C, 0x8BBCF2, 0xD6A8E4, 0x84D3DC, 0xECEEF2])
        case .graphite:
            make(fg: 0xD4D4D8, bg: 0x26272B, cursor: 0xB8B9BF, selection: 0x44464E, [
                0x34363C, 0xEC8486, 0x9BC88A, 0xE6C27A, 0x82AEE8, 0xC99BE0, 0x79C7C2, 0xBFC0C6,
                0x70737C, 0xF29597, 0xB0D9A0, 0xF2D392, 0x9DC1F0, 0xD9B2EC, 0x92D7D2, 0xE8E9EC])
        case .solarizedDark: solarized(dark: true)
        case .oneDark:
            make(fg: 0xABB2BF, bg: 0x282C34, cursor: 0x528BFF, selection: 0x3E4451, [
                0x3F4451, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
                0x5C6370, 0xEF7F88, 0xA5D48A, 0xF0CC8A, 0x78BDF5, 0xD38AE8, 0x6CC6D1, 0xD7DAE0])
        case .dracula:
            make(fg: 0xF8F8F2, bg: 0x282A36, cursor: 0xF8F8F2, selection: 0x44475A, [
                0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF])
        case .nord:
            make(fg: 0xD8DEE9, bg: 0x2E3440, cursor: 0xD8DEE9, selection: 0x434C5E, [
                0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4])
        case .gruvboxDark:
            make(fg: 0xEBDBB2, bg: 0x282828, cursor: 0xEBDBB2, selection: 0x504945, [
                0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
                0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2])
        case .tokyoNight:
            make(fg: 0xC0CAF5, bg: 0x1A1B26, cursor: 0xC0CAF5, selection: 0x33467C, [
                0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5])
        case .basicDark: basicDark
        }
    }
}

public extension AppSettings {
    /// The font to use: the Terminal.app profile's font when "use profile font" is on,
    /// otherwise the configured font (or the system monospaced font).
    var terminalFont: NSFont {
        if fontFromProfile, terminalColors == .terminalApp,
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
