import Foundation
import SSHTransport
import TetherCore

/// Keeps what a sign-in was answered with by how it ended (`SignInEnd`): remembered once it worked,
/// forgotten only when the server judged it; a password to save goes to the keychain only after
/// success (`AppModel.signInEnded`).
final class SignInRecorder: SignInObserver, @unchecked Sendable {
    private let cache: SealedPasswordCache

    init(cache: SealedPasswordCache) { self.cache = cache }

    func signIn(_ event: SignInEvent) {
        switch event {
        case .started(let token, let connection):
            cache.bind(token: token, connection: connection)
        case .ended(let token, let end):
            Task { @MainActor in AppModel.shared.signInEnded(token: token, end: end) }
            // Failed: see `SealedPasswordCache.discard` (forgotten only when the server judged it).
            guard end == .succeeded else {
                cache.discard(token: token, end: end)
                switch end {
                case .notJudged: ConnectionLog.shared.info("The sign-in ended before the server judged its answer; nothing remembered was forgotten", .signIn)
                case .unanswered: ConnectionLog.shared.notice("The server never answered the sign-in; a remembered password it was sent is tried once more at most", .signIn)
                default: break
                }
                return
            }
            for login in cache.commit(token: token) {
                // A key is named by its file name only (the log can be copied; no home folder in it).
                if login.hasPrefix(SealedPasswordCache.passphrasePrefix) {
                    let file = (String(login.dropFirst(SealedPasswordCache.passphrasePrefix.count)) as NSString).lastPathComponent
                    ConnectionLog.shared.info("Remembered the key's passphrase for this run", .signIn, host: "key " + file)
                } else {
                    ConnectionLog.shared.info("Remembered the password for this connection's next sign-ins", .signIn, host: login)
                }
            }
        }
    }
}

/// While Tether is locked no sign-in that may ask starts: nothing is asked for, and no remembered
/// password used, until it is unlocked.
final class LockGatekeeper: SignInGatekeeper, @unchecked Sendable {
    func mayStart() async { await AppLock.shared.waitUntilUnlocked() }
}
