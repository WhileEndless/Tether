import Foundation
import Testing
import TetherCore

/// The keychain copy of the security settings is read without a keychain prompt (keychain is
/// in memory under tests).
@Suite(.serialized) struct SecuritySettingsPinTests {
    let service = "Tether Security Settings"
    let account = "settings"

    func custom() -> SecuritySettings {
        var s = AppSettings()
        s.encryptRecordings.toggle()
        s.lockOnSleep.toggle()
        return SecuritySettings(s)
    }

    @Test func storedInAnAttributeNotInTheData() throws {
        defer { Keychain.delete(service: service, account: account) }
        Keychain.delete(service: service, account: account)
        #expect(SecuritySettings.pinned() == .missing)
        SecuritySettings.pin(custom())
        #expect(SecuritySettings.pinned() == .pinned(custom()))
        #expect(Keychain.read(service: service, account: account) == nil)
    }

    /// Copies written by 0.3.0–0.3.1 kept the settings in the item's data: read once, then moved.
    @Test func oldStyleCopyIsMovedToTheAttribute() throws {
        defer { Keychain.delete(service: service, account: account) }
        Keychain.write(try JSONEncoder().encode(custom()), service: service, account: account, label: "test")
        #expect(SecuritySettings.pinned() == .pinned(custom()))
        guard case .found(let value?) = Keychain.lookUpAttribute(service: service, account: account) else {
            Issue.record("not moved to the attribute"); return
        }
        #expect(try JSONDecoder().decode(SecuritySettings.self, from: value) == custom())
    }

    @Test func unreadableCopyIsReportedAsSuch() {
        defer { Keychain.delete(service: service, account: account) }
        Keychain.write(Data("not json".utf8), service: service, account: account, label: "test")
        #expect(SecuritySettings.pinned() == .unreadable)
    }
}
