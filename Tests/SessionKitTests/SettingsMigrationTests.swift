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

    /// The longest wait between retries grows once from the old 30 s; a value the user chose stays.
    @Test func longestRetryWaitGrowsOnce() throws {
        #expect(try decode(#"{"version":7,"reconnectMaxDelay":30}"#).reconnectMaxDelay == 120)
        #expect(try decode(#"{"version":7,"reconnectMaxDelay":45}"#).reconnectMaxDelay == 45)
        #expect(try decode(#"{"version":8,"reconnectMaxDelay":30}"#).reconnectMaxDelay == 30)
        #expect(AppSettings().reconnectMaxDelay == 120 && AppSettings().connectTimeout == 20)
    }

    /// Forced keep-alives and the 6 s stall limit go once (they ended connections plain ssh keeps);
    /// values the user chose stay.
    @Test func keepAlivesOffAndStallLimitLongerOnce() throws {
        let old = try decode(#"{"version":4,"serverAliveInterval":10,"serverAliveCountMax":3,"stallTimeout":6}"#)
        #expect(old.serverAliveInterval == 0 && old.stallTimeout == 15)
        let chosen = try decode(#"{"version":4,"serverAliveInterval":60,"serverAliveCountMax":3,"stallTimeout":9}"#)
        #expect(chosen.serverAliveInterval == 60 && chosen.stallTimeout == 9)
        let later = try decode(#"{"version":5,"serverAliveInterval":10,"serverAliveCountMax":3,"stallTimeout":6}"#)
        #expect(later.serverAliveInterval == 10 && later.stallTimeout == 6)
        #expect(AppSettings().serverAliveInterval == 0 && AppSettings().rememberSignInPasswords)
    }

    /// Many small files go as one stream from 5 on (was 20) unless chosen otherwise; compression,
    /// a switch before, is a method now: off stays off.
    @Test func packingAndCompressionOnce() throws {
        #expect(AppSettings().transferArchiveThreshold == 5 && AppSettings().transferCompression == .auto)
        let old = try decode(#"{"version":6,"transferArchiveThreshold":20,"transferCompress":true}"#)
        #expect(old.transferArchiveThreshold == 5 && old.transferCompression == .auto)
        let chosen = try decode(#"{"version":6,"transferArchiveThreshold":50,"transferCompress":false}"#)
        #expect(chosen.transferArchiveThreshold == 50 && chosen.transferCompression == .off)
        let now = try decode(#"{"version":7,"transferArchiveThreshold":20,"transferCompression":"xz"}"#)
        #expect(now.transferArchiveThreshold == 20 && now.transferCompression == .xz)
    }
}
