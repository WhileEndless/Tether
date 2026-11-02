import Foundation

/// What Tether did for each sign-in's questions, kept in one place for the rules that depend on
/// it: an answer is sent to the same question once (asked again, it was refused — or a second
/// step), a saved password the server refused is not sent by itself again until it is saved anew,
/// and a password the user chose to save goes to the keychain only once the sign-in worked.
///
/// Per sign-in (askpass token) entries go when the sign-in ends (`ended`); refusals of saved
/// passwords last for the run. Thread-safe.
public final class SignInLedger: @unchecked Sendable {
    public init() {}

    private let lock = NSLock()
    /// Answers already sent, by `attemptKey`.
    private var sent: Set<String> = []
    /// Of those, the ones read from the keychain.
    private var fromKeychain: Set<String> = []
    /// Keychain items a server refused this run.
    private var refused: Set<String> = []
    /// Sign-ins asked the same login question again after a stored answer, by token.
    private var askedAgain: [String: (login: String, fromKeychain: Bool)] = [:]
    /// Passwords to save once the sign-in worked, by token.
    private var saves: [String: Save] = [:]
    /// Answers to save that came after the server's login time, by login: saved once the fresh
    /// sign-in they are handed to works.
    private var lateSaves: [String: (save: Save, at: Date)] = [:]

    public struct Save: Sendable, Equatable {
        public var password: String
        /// The keychain item.
        public var item: String
        public init(password: String, item: String) { self.password = password; self.item = item }
    }

    /// What marks an answer as given to one asker: its token — and for a key's passphrase its ssh
    /// process too (the ssh that ProxyJump starts for a jump host has the same token and opens the
    /// same key on its own; its question is not a sign of a wrong passphrase).
    public static func attemptKey(token: String, login: String, askerPID: Int32? = nil) -> String {
        askerPID.map { token + "\u{0}\($0)\u{0}" + login } ?? token + login
    }

    // MARK: Answers sent

    public func wasSent(_ attempt: String) -> Bool { lock.withLock { sent.contains(attempt) } }

    public func noteSent(_ attempt: String, fromKeychain keychain: Bool = false) {
        lock.withLock {
            sent.insert(attempt)
            if keychain { fromKeychain.insert(attempt) }
        }
    }

    /// The same question came again after an answer was sent for it: judged when the user answers
    /// it (`judgeRepeat`). Returns whether that answer came from the keychain.
    @discardableResult
    public func noteAskedAgain(token: String, attempt: String, login: String) -> Bool {
        lock.withLock {
            let keychain = fromKeychain.remove(attempt) != nil
            askedAgain[token] = (login, keychain)
            return keychain
        }
    }

    public enum RepeatVerdict: Equatable, Sendable {
        /// Nothing was sent before for it.
        case none
        /// A one-time code the server asks with the same words: the answer before it was accepted.
        case secondStep(login: String)
        /// The answer before was refused (forget it; a keychain item is not sent by itself again).
        case refused(login: String, fromKeychain: Bool)
    }

    /// The user answered a question asked again (`answer` nil: cancelled). Only digits (a one-time
    /// code) make it a second step; anything else — also a cancel — counts the earlier answer as
    /// refused, so a wrong password is never sent again by itself.
    public func judgeRepeat(token: String, answer: String?) -> RepeatVerdict {
        lock.withLock {
            guard let again = askedAgain.removeValue(forKey: token) else { return .none }
            if let answer, SealedPasswordCache.looksLikeOneTimeCode(answer) { return .secondStep(login: again.login) }
            if again.fromKeychain { refused.insert(again.login) }
            return .refused(login: again.login, fromKeychain: again.fromKeychain)
        }
    }

    // MARK: Saved passwords

    public func isRefused(_ item: String) -> Bool { lock.withLock { refused.contains(item) } }

    /// The keychain item was saved, changed or removed: it may be sent again.
    public func clearRefusal(_ item: String) { _ = lock.withLock { refused.remove(item) } }

    /// Saved to the keychain once the sign-in with this token worked.
    public func saveAfterSuccess(token: String, _ save: Save?) { lock.withLock { saves[token] = save } }

    /// An answer that came after the server's login time: saved once a fresh sign-in it is handed
    /// to (with this `login`) works.
    public func saveLate(login: String, _ save: Save) { lock.withLock { lateSaves[login] = (save, Date()) } }

    /// A fresh sign-in was answered with `password` for `login`: a late save waiting for it goes
    /// with that sign-in now (within 5 minutes of the late answer).
    public func handLateSave(login: String, password: String, to token: String) {
        lock.withLock {
            lateSaves = lateSaves.filter { Date().timeIntervalSince($0.value.at) < 300 }
            guard let late = lateSaves[login], late.save.password == password else { return }
            lateSaves[login] = nil
            saves[token] = late.save
        }
    }

    /// The sign-in with this token ended: what is kept for it goes; the password to save, when it
    /// worked, is returned (its refusal mark goes too).
    public func ended(token: String, end: SignInEnd) -> Save? {
        lock.withLock {
            askedAgain[token] = nil
            sent = sent.filter { !$0.hasPrefix(token) }
            fromKeychain = fromKeychain.filter { !$0.hasPrefix(token) }
            guard let save = saves.removeValue(forKey: token), end == .succeeded else { return nil }
            refused.remove(save.item)
            return save
        }
    }
}
