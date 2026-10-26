import Foundation
import Testing
import TetherCore

/// Appearance settings: new ones get their defaults, the terminal colours saved by earlier versions
/// stay what they were.
@Suite struct AppearanceSettingsTests {
    func decode(_ json: String) throws -> AppSettings {
        var s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        s.migrate()
        return s
    }

    @Test func newInstallsFollowTheApp() {
        let s = AppSettings()
        #expect(s.appearance == .system)
        #expect(s.terminalColors == .followApp)
        #expect(s.terminalLightTheme == .tetherLight && s.terminalDarkTheme == .tetherDark)
        #expect(s.sidebarStyle == .detailed && s.uiTextSize == .standard)
    }

    @Test func earlierThemesAreKept() throws {
        // The old default (and no theme saved at all) was the Terminal.app profile.
        #expect(try decode(#"{"version":4}"#).terminalColors == .terminalApp)
        #expect(try decode(#"{"version":4,"theme":"system"}"#).terminalColors == .terminalApp)
        let light = try decode(#"{"version":4,"theme":"solarizedLight"}"#)
        #expect(light.terminalColors == .alwaysLight && light.terminalLightTheme == .solarizedLight)
        let dark = try decode(#"{"version":4,"theme":"dark"}"#)
        #expect(dark.terminalColors == .alwaysDark && dark.terminalDarkTheme == .basicDark)
    }

    @Test func savedChoicesRoundTripAndUnknownValuesFallBack() throws {
        var s = AppSettings()
        s.appearance = .light
        s.sidebarStyle = .folders
        s.terminalColors = .alwaysDark
        s.terminalDarkTheme = .nord
        s.uiTextSize = .large
        s.accentColor = .purple
        let back = try decode(String(decoding: JSONEncoder().encode(s), as: UTF8.self))
        #expect(back == s)
        let odd = try decode(#"{"version":5,"sidebarStyle":"tiles","terminalColors":"rainbow","appearance":"sepia"}"#)
        #expect(odd.sidebarStyle == .detailed && odd.appearance == .system)
        #expect(odd.terminalColors == .terminalApp)   // unreadable: treated like a pre-0.8 save
    }

    @Test func textSizeSteps() {
        #expect(UITextSize.standard.bigger == .large && UITextSize.standard.smaller == .small)
        #expect(UITextSize.extraLarge.bigger == nil && UITextSize.small.smaller == nil)
    }
}
