import Foundation
import Testing
import TetherCore

/// Changed defaults reach settings saved by older versions once; later choices are kept.
@Suite struct SettingsMigrationTests {
    func decode(_ json: String) throws -> AppSettings {
        var s = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        s.migrate()
        return s
    }

    /// Option types the layout's characters (⌥Q → @ on Turkish keyboards) unless turned on again.
    @Test func optionAsMetaIsOffOnceThenTheUsersChoice() throws {
        #expect(AppSettings().optionAsMeta == false)
        #expect(try decode(#"{"version":3,"optionAsMeta":true}"#).optionAsMeta == false)
        #expect(try decode(#"{"version":4,"optionAsMeta":true}"#).optionAsMeta == true)
        #expect(try decode(#"{"version":3,"optionAsMeta":true}"#).version == AppSettings.currentVersion)
    }
}
