import Foundation
import Testing
import TetherCore

/// ⌘T starts in the current tab's folder (unless the user chose the home folder), next to the current tab.
@Suite struct NewTabDirectoryTests {
    @Test func settingsFromBeforeTheOptionStartInTheCurrentFolder() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"version":1,"openNewSessionsInWindow":true}"#.utf8))
        #expect(old.newTabDirectory == .current)
        #expect(old.newTabPosition == .afterCurrent)
        #expect(old.openNewSessionsInWindow)
        var s = AppSettings()
        s.newTabDirectory = .home
        s.newTabPosition = .end
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.newTabDirectory == .home)
        #expect(back.newTabPosition == .end)
    }
}
