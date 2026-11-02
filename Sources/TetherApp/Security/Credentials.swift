import Foundation
import TetherCore

/// The one way Tether writes saved passwords and passphrases: a password saved, changed or
/// removed may be sent again (a refusal of the old one no longer counts), and a copy remembered
/// from the old one is not used any more (`AppModel.savedPasswordChanged`).
@MainActor
enum Credentials {
    /// - Parameter replacesRemembered: false when the password saved is the one the sign-in just
    ///   used (its remembered copy is that very password).
    @discardableResult
    static func save(_ password: String, for item: String, replacesRemembered: Bool = true) -> Bool {
        let saved = PasswordVault.setPassword(password, for: item)
        if replacesRemembered { AppModel.shared.savedPasswordChanged(item) } else { AppModel.shared.signIns.clearRefusal(item) }
        return saved
    }

    static func remove(_ item: String) {
        PasswordVault.deletePassword(for: item)
        AppModel.shared.savedPasswordChanged(item)
    }
}
