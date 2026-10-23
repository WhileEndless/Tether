import Carbon.HIToolbox
import Foundation

/// macOS Secure Keyboard Entry while a visible terminal waits for a password: no other app can read
/// the keys typed then. On for as long as at least one such terminal asks (Settings ▸ Security).
@MainActor
enum SecureInput {
    private static var asking: Set<UUID> = []

    static func set(_ on: Bool, for session: UUID) {
        let wasOn = !asking.isEmpty
        if on { asking.insert(session) } else { asking.remove(session) }
        let isOn = !asking.isEmpty
        if isOn && !wasOn { EnableSecureEventInput() }
        if wasOn && !isOn { DisableSecureEventInput() }
    }
}
