import Foundation
import SSHTransport
import SessionKit
import TetherCore

/// What the sign-in broker needs from the app: the lock, Touch ID and the keychain, which saved
/// password fits a question, the panel, and the tabs a sign-in stands for.
extension AppModel: SignInHost {
    var isLocked: Bool { AppLock.shared.isLocked }

    func hasSavedPassword(_ item: String) -> Bool { PasswordVault.hasPassword(for: item) }

    var savedPasswordNeedsSomeone: Bool { SecretGate.shared.needsCheck && AppLock.shared.screenAway }

    var checkName: String { SecretGate.shared.methodName }

    func readSavedPassword(_ item: String, reason: String) async -> String? {
        guard await SecretGate.shared.authorize(reason) else { return nil }
        return await PasswordVault.passwordOffThread(for: item)
    }

    /// Every tab this sign-in stood for — of the host itself, its other names, or hosts behind it
    /// when it is a jump host's — stops asking until the user presses Reconnect.
    func pauseAfterCancel(_ request: AskPassRequest) {
        var stopped: [UUID: TerminalSession] = [:]
        let host = request.sessionID.flatMap { sessions.session($0)?.descriptor.target.key } ?? (request.targetKey.isEmpty ? nil : request.targetKey)
        for s in host.map({ sessions.sessions(for: $0) }) ?? [] { stopped[s.id] = s }
        if let host { for s in sessions.sessions where HostLinks.sameServer(s.descriptor.target.key, host) { stopped[s.id] = s } }
        for id in SignInInterest.waiting(for: request.token)?.sessions ?? [] {
            if let s = sessions.session(id) { stopped[id] = s }
        }
        for other in stopped.values where !other.phase.isOnline {
            other.pauseRetries("Sign-in cancelled. Press Reconnect when you want to sign in.")
        }
    }

    /// Its tabs try again now and take the answer (handed on) instead of asking.
    func signInAgain(_ request: AskPassRequest) {
        for id in (SignInInterest.waiting(for: request.token)?.sessions ?? []).union(request.sessionID.map { [$0] } ?? []) {
            if let s = sessions.session(id), !s.phase.isOnline { s.reconnectNow("the answer came after the server's login time; signing in again with it") }
        }
    }

    func save(_ password: String, for item: String, replacesRemembered: Bool) {
        Credentials.save(password, for: item, replacesRemembered: replacesRemembered)
    }

    func isLive(_ token: String) -> Bool { AskPassBridge.shared.isLive(token) }

    func endSignIn(_ token: String) { AskPassBridge.shared.terminateProcesses(of: token) }

    func questionsChanged(_ questions: [SignInQuestion]) { setPrompts(questions) }
}
