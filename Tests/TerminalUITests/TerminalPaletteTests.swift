import AppKit
import Testing
import SwiftTerm
import TetherCore
@testable import TerminalUI

/// Built-in terminal themes stay readable: Tether's own meet WCAG AA (4.5:1) for the text and the
/// eight normal colours; published themes keep their authors' colours but must not drop below a
/// readable floor. ANSI black on dark themes and white on light ones are background shades by design.
@MainActor
@Suite struct TerminalPaletteTests {
    func luminance(_ c: NSColor) -> Double {
        let c = c.usingColorSpace(.sRGB)!
        func lin(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }
    func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    func ns(_ c: SwiftTerm.Color) -> NSColor {
        NSColor(srgbRed: CGFloat(c.red) / 65535, green: CGFloat(c.green) / 65535, blue: CGFloat(c.blue) / 65535, alpha: 1)
    }

    /// Basic Light/Dark copy Terminal.app's Basic profile exactly (its dark blue is hard to read
    /// on dark, as in Terminal.app); they are there for people who want exactly that.
    @Test(arguments: TerminalPalette.allCases.filter { $0 != .basicLight && $0 != .basicDark })
    func readable(_ p: TerminalPalette) {
        let t = TerminalTheme.palette(p)
        #expect(t.ansi.count == 16)
        #expect((luminance(t.background) < 0.2) == p.isDark, "\(p) background does not match its light/dark kind")
        let textFloor = p.isTetherDesigned ? 4.5 : 4.0
        let colorFloor = p.isTetherDesigned ? 4.5 : 1.9
        #expect(contrast(t.foreground, t.background) >= textFloor, "\(p) text")
        for i in 0..<8 where !(p.isDark ? i == 0 : i == 7) {
            let r = contrast(ns(t.ansi[i]), t.background)
            #expect(r >= colorFloor, "\(p) colour \(i): \(String(format: "%.2f", r))")
        }
    }

    @Test func tetherThemesAvoidPureWhiteAndBlack() {
        for p in TerminalPalette.allCases where p.isTetherDesigned {
            let l = luminance(TerminalTheme.palette(p).background)
            #expect(l > 0.005 && l < 0.95, "\(p)")
        }
    }

    @Test func followTheAppPicksByAppearance() {
        var s = AppSettings()
        s.terminalColors = .followApp
        s.terminalLightTheme = .paper
        s.terminalDarkTheme = .nord
        #expect(TerminalTheme.resolve(s, dark: false).background == TerminalTheme.palette(.paper).background)
        #expect(TerminalTheme.resolve(s, dark: true).background == TerminalTheme.palette(.nord).background)
        s.terminalColors = .alwaysDark
        #expect(TerminalTheme.resolve(s, dark: false).background == TerminalTheme.palette(.nord).background)
    }
}
