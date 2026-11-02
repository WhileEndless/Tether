import Foundation

/// A question ssh asked through askpass, waiting for the user (shown in the sign-in panel).
public struct SignInQuestion: Identifiable, Sendable {
    public let id = UUID()
    public let request: AskPassRequest
    public let created = Date()
    /// The saved password was just sent and not accepted (it probably changed on the server).
    public var savedWasRejected = false

    /// What makes two host-key questions the same: the question itself, which ssh writes with the
    /// host and its key's fingerprint — the same question for a jump host asked by several
    /// connections behind it is answered once.
    public var confirmationKey: String? { request.isConfirmation ? request.prompt : nil }

    public init(request: AskPassRequest, savedWasRejected: Bool = false) {
        self.request = request
        self.savedWasRejected = savedWasRejected
    }
}

/// What the app knows and does around a sign-in (the broker decides; the app shows, reads the
/// keychain after Touch ID, and moves its tabs).
@MainActor
public protocol SignInHost: AnyObject {
    /// Tether is locked: nothing is answered and nobody asked.
    var isLocked: Bool { get }
    /// Waits (briefly) for the ssh program's check after launch.
    func sshCheckSettled() async
    /// The saved password that may answer this question (see `AppModel.savedPasswordKey`).
    func savedPasswordKey(for request: AskPassRequest) -> String?
    /// The keychain item a password typed for this question is saved under.
    func passwordKey(for request: AskPassRequest) -> String
    /// A password typed in Quick Connect for this very question, taken.
    func takeQuickConnectPassword(for request: AskPassRequest) -> String?
    func hasSavedPassword(_ item: String) -> Bool
    /// A saved password read now would need Touch ID while nobody is at the Mac.
    var savedPasswordNeedsSomeone: Bool { get }
    /// "Touch ID" (or what macOS asks instead), for the log.
    var checkName: String { get }
    /// The saved password after Touch ID (when required); nil when it was declined or failed.
    func readSavedPassword(_ item: String, reason: String) async -> String?
    /// The tabs this sign-in stands for wait until one of them is shown.
    func waitForUser(token: String, sessionID: UUID?, host: String)
    /// Its tabs stop trying until the user presses Reconnect (the user cancelled its question).
    func pauseAfterCancel(_ request: AskPassRequest)
    /// Its tabs try again now (an answer came after the server's login time).
    func signInAgain(_ request: AskPassRequest)
    /// Saves to the keychain (`replacesRemembered`: a different password than the one in use).
    func save(_ password: String, for item: String, replacesRemembered: Bool)
    /// Whether this sign-in's ssh is still there to take an answer.
    func isLive(_ token: String) -> Bool
    /// Ends this sign-in's ssh (no answer will come).
    func endSignIn(_ token: String)
    /// The open questions changed (shown in the panel).
    func questionsChanged(_ questions: [SignInQuestion])
}

/// Decides how each askpass question is answered — one place for the rules (see
/// docs/connections-and-passwords.md):
/// - an answer comes from, in order: a password typed in Quick Connect, one remembered or handed on
///   for this connection, the keychain (after Touch ID), and only then the user;
/// - a password is sent to the same question once: asked again, it was refused (or a one-time code
///   follows), and the user is asked;
/// - one question is shown however many ssh processes ask it at once; its answer goes to the others
///   waiting for the same connection, and is handed on to the sign-ins that follow (60 s);
/// - a password is remembered, or saved, only once the sign-in it was typed for worked.
@MainActor
public final class SignInBroker {
    public let cache: SealedPasswordCache
    public let ledger: SignInLedger
    public weak var host: SignInHost?

    private struct Open {
        var question: SignInQuestion
        var continuation: CheckedContinuation<String?, Never>
        /// The same host-key question from other ssh processes, answered together.
        var followers: [CheckedContinuation<String?, Never>] = []
        /// Their askpass tokens, in the same order.
        var followerTokens: [String] = []
    }
    private var open: [Open] = [] { didSet { host?.questionsChanged(open.map(\.question)) } }
    /// Host-key questions answered in the last minutes.
    private var recentConfirmations: [String: (answer: String?, date: Date)] = [:]

    /// An answer after this long went to a login the server closed (sshd's LoginGraceTime is 2 min).
    public static let lateAnswer: TimeInterval = 110

    public init(cache: SealedPasswordCache, ledger: SignInLedger = SignInLedger()) {
        self.cache = cache
        self.ledger = ledger
    }

    public var questions: [SignInQuestion] { open.map(\.question) }

    nonisolated static func attempt(_ request: AskPassRequest, _ key: String) -> String {
        SignInLedger.attemptKey(token: request.token, login: key, askerPID: request.isPassphrasePrompt ? request.askerPID : nil)
    }

    /// Whether a password typed for it may be remembered and handed on: only ssh's own password
    /// question or a local key's passphrase, never a one-time code — and only from an ssh that marks
    /// a server's questions.
    nonisolated static func isRememberable(_ request: AskPassRequest) -> Bool {
        (request.isPlainPasswordPrompt && request.askerNamesItsQuestions) || request.isPassphrasePrompt
    }

    // MARK: Answering

    /// The answer for ssh (nil: none — the sign-in ends).
    public nonisolated func answer(_ request: AskPassRequest) async -> String? {
        let quiet = SSHOptions.isQuietPurpose(request.purpose)
        let hostKey = request.targetKey.isEmpty ? nil : request.targetKey
        // Background work never gets a password and never asks (its ssh refuses every question at
        // the bridge already; this holds whatever reaches here).
        if quiet { return nil }
        // While Tether is locked nothing is answered from memory or the keychain, and no one is
        // asked: the sign-in is ended (unjudged — nothing is forgotten) and starts again once
        // Tether is unlocked (`SignInEvents.gatekeeper`).
        if !request.isConfirmation, !request.isNotice, !quiet, await MainActor.run(body: { host?.isLocked == true }) {
            ConnectionLog.shared.info("A sign-in asked while Tether was locked; it starts again once Tether is unlocked", .signIn, host: hostKey)
            await MainActor.run { host?.endSignIn(request.token) }
            return nil
        }
        // Just launched: the ssh program's check decides whether anything may be filled in.
        await host?.sshCheckSettled()
        // Nothing is filled in by itself for a question an older ssh asks: a jump host behind it
        // could have worded it as the target's (the user still sees it, and Fill).
        if (request.isPasswordPrompt && request.askerNamesItsQuestions) || request.isPassphrasePrompt {
            if let found = await stored(request) { return found }
        } else if request.isPasswordPrompt, request.askpassKind == nil, !quiet {
            ConnectionLog.shared.info("No remembered password for this sign-in", .signIn, host: hostKey,
                                      detail: "the ssh asking is not known to mark a server's own questions (OpenSSH 8.4 or later), so nothing is filled in by itself")
        }
        if !request.isConfirmation, !request.isNotice, !quiet {
            ConnectionLog.shared.info("Asking you: " + Self.questionKind(request), .signIn, host: hostKey)
        }
        return await ask(request)
    }

    /// A remembered, handed-on or saved answer for it (`.some(nil)`: the sign-in was ended), or nil
    /// when the user is to be asked.
    private nonisolated func stored(_ request: AskPassRequest) async -> String?? {
        let quiet = SSHOptions.isQuietPurpose(request.purpose)
        // Only the account's own password (or a key's passphrase) is filled in, counted as refused
        // when asked again, and saved: never a one-time code or a new password.
        let loginQuestion = request.isSecretOfTheAccount
        let named = request.sshNamedLogin.map { "\($0.user)@\($0.host)" }
        let (key, remembered, tried, fromCache) = await MainActor.run { () -> (String?, (password: String, source: SealedPasswordCache.Source)?, Bool, Bool) in
            let key = host?.savedPasswordKey(for: request)
            let tried = key.map { ledger.wasSent(Self.attempt(request, $0)) } ?? true
            // The same ssh asking the same question again: the answer it got was refused — or the
            // server asks a second step with the same words. Judged once the user answers.
            if tried, loginQuestion, let key {
                ledger.noteAskedAgain(token: request.token, attempt: Self.attempt(request, key), login: key)
                ConnectionLog.shared.notice("The server asked again after the password it was sent; asking you", .signIn, host: key)
            }
            var remembered: (password: String, source: SealedPasswordCache.Source)?
            var fromCache = false
            // Background work never gets a password (it refuses every prompt anyway). A key's
            // passphrase too: typed once, it opens that key for every server it signs in to.
            if !quiet, !tried, request.takesRememberedAnswer, let key {
                if let typed = host?.takeQuickConnectPassword(for: request) { remembered = (typed, .typed) }
                else { remembered = cache.password(token: request.token, login: key, named: named); fromCache = remembered != nil }
            }
            return (key, remembered, tried, fromCache)
        }
        let label = request.isPassphrasePrompt ? Self.keyLabel(request) : key
        // Remembered, typed or read from the keychain: sent without asking.
        if let key, let remembered {
            ConnectionLog.shared.info(request.isPassphrasePrompt ? "Opened the key with the remembered passphrase" : "Answered ssh's sign-in question with the remembered password",
                                      .signIn, host: label)
            await MainActor.run {
                // An answer saved after the server's login time goes to the keychain once the sign-in
                // it is handed to works.
                ledger.handLateSave(login: key, password: remembered.password, to: request.token)
                ledger.noteSent(Self.attempt(request, key))
                // One taken from the cache is not given to it again: its entry keeps the time it was
                // typed (Forget them after …), and one forgotten meanwhile stays forgotten.
                if !fromCache { cache.offer(remembered.password, login: key, token: request.token, source: remembered.source, named: named) }
            }
            return .some(remembered.password)
        }
        // Why nothing remembered answers it (the Connection Log; never a password or address).
        if let key, !tried, request.takesRememberedAnswer, !quiet {
            let why = await MainActor.run { cache.whyNotRemembered(token: request.token, login: key) }
            ConnectionLog.shared.info(request.isPassphrasePrompt ? "No remembered passphrase for this key" : "No remembered password for this sign-in",
                                      .signIn, host: label, detail: why)
        } else if key == nil, request.isLoginPasswordPrompt, !quiet {
            ConnectionLog.shared.info("No remembered or saved password looked up for this sign-in", .signIn,
                                      host: request.targetKey.isEmpty ? nil : request.targetKey,
                                      detail: "the question names a host that is not on this connection's way, or names none while jump hosts are on it")
        }
        // A saved password once per question; asked again, it was wrong. Touch ID (if enabled)
        // comes before the password is even read from the keychain.
        guard let key, !tried, loginQuestion else { return nil }
        let (refused, hasSaved, away) = await MainActor.run {
            (ledger.isRefused(key), host?.hasSavedPassword(key) ?? false, host?.savedPasswordNeedsSomeone ?? false)
        }
        if refused {
            if hasSaved { ConnectionLog.shared.info("The saved password was refused earlier in this run; asking instead", .signIn, host: key) }
            return nil
        }
        guard hasSaved else { return nil }
        // Nobody at the Mac to answer Touch ID (asleep, display off, screen locked): the sign-in is
        // ended unjudged and its tabs wait to be shown — the server would close a login kept waiting
        // meanwhile, and the request would fail unseen.
        if away {
            ConnectionLog.shared.info("A saved password needs Touch ID while nobody is at the Mac; the sign-in waits until you are back", .signIn, host: key)
            await MainActor.run {
                host?.waitForUser(token: request.token, sessionID: request.sessionID, host: request.targetKey)
                host?.endSignIn(request.token)
            }
            return .some(nil)
        }
        if let saved = await host?.readSavedPassword(key, reason: Self.reason(for: request, key: key)) {
            ConnectionLog.shared.info(request.isPassphrasePrompt ? "Opened the key with the passphrase saved in the keychain" : "Answered ssh's sign-in question with the password saved in the keychain",
                                      .signIn, host: label)
            await MainActor.run {
                ledger.noteSent(Self.attempt(request, key), fromKeychain: true)
                // Remembered for this connection's further sign-ins this run, without Touch ID again.
                if request.takesRememberedAnswer { cache.offer(saved, login: key, token: request.token, source: .keychain, named: named) }
            }
            return .some(saved)
        }
        let method = await MainActor.run { host?.checkName ?? "Touch ID" }
        ConnectionLog.shared.info("The saved password was not used (\(method) was cancelled or failed); asking", .signIn, host: key)
        return nil
    }

    /// Shows the question (once, however many ssh processes ask it) and waits for the user.
    private nonisolated func ask(_ request: AskPassRequest) async -> String? {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                // Asked the same question again after the saved password was sent: it was not accepted.
                var rejected = false
                if request.isSecretOfTheAccount, let key = host?.savedPasswordKey(for: request) {
                    rejected = (ledger.wasSent(Self.attempt(request, key)) || ledger.isRefused(key)) && host?.hasSavedPassword(key) == true
                }
                // Its ssh ended while this was on the way (Touch ID, the lock screen): nothing to ask.
                guard host?.isLive(request.token) ?? false else { continuation.resume(returning: nil); return }
                let question = SignInQuestion(request: request, savedWasRejected: rejected)
                // Several ssh processes logging in to a new host at once (a tab, monitoring, files)
                // each ask about the same key: shown once, and one asked again right after it was
                // answered gets the same answer.
                if let key = question.confirmationKey {
                    if let recent = recentConfirmations[key], Date().timeIntervalSince(recent.date) < 120 {
                        continuation.resume(returning: recent.answer)
                        return
                    }
                    if let i = open.firstIndex(where: { $0.question.confirmationKey == key }) {
                        open[i].followers.append(continuation)
                        open[i].followerTokens.append(request.token)
                        return
                    }
                }
                open.append(Open(question: question, continuation: continuation))
            }
        }
    }

    // MARK: The user's answer

    public enum UserAnswer: Sendable, Equatable {
        /// Typed (`save`: also to the keychain once the sign-in worked).
        case text(String, save: Bool)
        /// Cancel Sign-In: its ssh is ended (and its tabs stop asking).
        case cancel
        /// A key skipped (ssh goes on with the next way to sign in).
        case skipKey
        /// A host key trusted (or not), a yes/no question answered.
        case yes, no
    }

    /// The user answered (or cancelled) an open question. Answered once only: Return and the
    /// default button can both arrive, and a question withdrawn a moment ago is gone already.
    public func resolve(_ id: UUID, with reply: UserAnswer) {
        guard let i = open.firstIndex(where: { $0.question.id == id }) else { return }
        let current = open.remove(at: i)
        let request = current.question.request
        let answer: String?
        var save = false
        switch reply {
        case .text(let text, let s): answer = text; save = s
        case .cancel: answer = nil
        case .skipKey: answer = ""
        case .yes: answer = "yes"
        case .no: answer = "no"
        }
        let quiet = SSHOptions.isQuietPurpose(request.purpose)
        // Cancelled: its ssh is ended first (told "no answer", ssh would send an empty password — a
        // failed login on the server — and ask again), its waiters stop too, and every tab it stood
        // for stops asking until the user presses Reconnect.
        if answer == nil, !request.isConfirmation {
            SignInEvents.shared.userCancelled(token: request.token)
            host?.endSignIn(request.token)
            ConnectionLog.shared.info("Sign-in question cancelled", .signIn, host: request.targetKey)
            host?.pauseAfterCancel(request)
        }
        // The same question again after a stored answer: a one-time code typed now means the server
        // took the password and asks a second step (nothing is remembered or saved from it);
        // anything else means the password was refused.
        var secondStep = false
        switch ledger.judgeRepeat(token: request.token, answer: answer) {
        case .none:
            break
        case .secondStep(let login):
            secondStep = true
            HostLinks.shared.noteSecondStep(request.targetKey)
            ConnectionLog.shared.info("The answer looks like a one-time code: taken as a second step, the password before it is kept", .signIn, host: login)
        case .refused(let login, let fromKeychain):
            cache.reject(token: request.token, login: login)
            ConnectionLog.shared.notice(fromKeychain ? "The server did not accept the password saved in the keychain; it is not sent again until it is saved anew"
                                                     : "The server did not accept the password it was sent", .signIn, host: login)
        }
        // Another question answered after the password (a one-time code, a token): the server asks a
        // second step; its tabs then keep to one connection.
        if let answer, !answer.isEmpty, !request.isSecretOfTheAccount, !request.isConfirmation, !request.isNotice,
           request.askpassKind == nil, request.askerNamesItsQuestions, request.sshNamedLogin != nil, !request.targetKey.isEmpty, !quiet {
            HostLinks.shared.noteSecondStep(request.targetKey)
        }
        let key = host?.savedPasswordKey(for: request)
        let typed = answer.flatMap { $0.isEmpty || secondStep ? nil : $0 }
        // Remembered (sealed) for this server's further sign-ins only once this one has worked, and
        // handed to its sign-ins that follow (`SealedPasswordCache.handOffTime`).
        if let typed, Self.isRememberable(request), !quiet, let key {
            cache.offer(typed, login: key, token: request.token, source: .typed, named: request.sshNamedLogin.map { "\($0.user)@\($0.host)" })
        }
        // Answered after the server's login time ran out (sshd closes an unfinished login after about
        // two minutes; ssh does not notice while it waits): sending it would fail. The answer is
        // handed to the fresh sign-in that follows (above), so it is not asked for again.
        if let typed, Self.isRememberable(request), Date().timeIntervalSince(current.question.created) > Self.lateAnswer {
            ledger.saveAfterSuccess(token: request.token, nil)
            if save, request.isSecretOfTheAccount, let key, let item = host?.passwordKey(for: request) {
                // Saved once the fresh sign-in it is handed to works (never a mistyped one).
                ledger.saveLate(login: key, .init(password: typed, item: item))
            }
            ConnectionLog.shared.info("The answer came after the server's login time; signing in again with it", .signIn, host: request.targetKey)
            host?.endSignIn(request.token)
            current.continuation.resume(returning: nil)
            current.followers.forEach { $0.resume(returning: nil) }
            host?.signInAgain(request)
            return
        }
        // Saved in the keychain once the sign-in worked (one bound to a connection reports how it
        // ended; others are saved now). Never a one-time code or a new password.
        if save, let typed, request.isSecretOfTheAccount, let item = host?.passwordKey(for: request) {
            if cache.connection(token: request.token) != nil {
                ledger.saveAfterSuccess(token: request.token, .init(password: typed, item: item))
            } else {
                host?.save(typed, for: item, replacesRemembered: false)
            }
        }
        // The same ssh asking again means it was wrong: then the user is asked, not the keychain.
        if request.isSecretOfTheAccount, answer?.isEmpty == false, let key { ledger.noteSent(Self.attempt(request, key)) }
        // Skipped key: an earlier answer to this question (a typo ssh asked again for) is not kept.
        if answer == "", request.isPassphrasePrompt, let key { cache.withdraw(token: request.token, login: key) }
        if let confirmation = current.question.confirmationKey { recentConfirmations[confirmation] = (answer, Date()) }
        current.continuation.resume(returning: answer)
        current.followers.forEach { $0.resume(returning: answer) }
        if let typed, Self.isRememberable(request), let key { handOnToWaiting(typed, key: key, from: request) }
    }

    /// Other sign-ins waiting for the same login at this moment (another connection to the same
    /// server, hosts behind the same jump host) take the answer too, once each, instead of asking.
    /// Only a sign-in for the same connection (host, port, user and jump host): the same user@host on
    /// another port, or behind another jump host, is another server.
    private func handOnToWaiting(_ answer: String, key: String, from request: AskPassRequest) {
        let connection = cache.connection(token: request.token)
        func sameConnection(_ other: AskPassRequest) -> Bool {
            // A key's passphrase belongs to the key file on this Mac: every sign-in waiting to open
            // that key takes it, whatever server it is for.
            if request.isPassphrasePrompt { return other.isPassphrasePrompt }
            if let connection { return cache.connection(token: other.token) == connection }
            return cache.connection(token: other.token) == nil && other.targetKey == request.targetKey
        }
        for other in open where Self.isRememberable(other.question.request) && host?.savedPasswordKey(for: other.question.request) == key
            && sameConnection(other.question.request) && !ledger.wasSent(Self.attempt(other.question.request, key)) {
            let o = other.question.request
            ledger.noteSent(Self.attempt(o, key))
            open.removeAll { $0.question.id == other.question.id }
            if o.takesRememberedAnswer {
                cache.offer(answer, login: key, token: o.token, source: .typed, named: o.sshNamedLogin.map { "\($0.user)@\($0.host)" })
            }
            other.continuation.resume(returning: answer)
            other.followers.forEach { $0.resume(returning: answer) }
        }
    }

    /// The ssh behind a question is gone (gave up, timed out, was stopped): the question goes away
    /// (one others wait on stays: they still need the answer). Returns it when it went.
    @discardableResult
    public func withdraw(token: String) -> SignInQuestion? {
        // One of those sharing a host-key question is gone: it stops waiting; the question stays.
        if let i = open.firstIndex(where: { $0.followerTokens.contains(token) }), let k = open[i].followerTokens.firstIndex(of: token) {
            open[i].followerTokens.remove(at: k)
            open[i].followers.remove(at: k).resume(returning: nil)
            return nil
        }
        guard let i = open.firstIndex(where: { $0.question.request.token == token }), open[i].followers.isEmpty else { return nil }
        let gone = open.remove(at: i)
        ConnectionLog.shared.info("A sign-in question went away (its ssh ended)", .signIn, host: gone.question.request.targetKey)
        gone.continuation.resume(returning: nil)
        return gone.question
    }

    /// Every askpass token a shown question answers (the one asking, and others asking the same
    /// host-key question): all of them are in front of the user.
    public func tokens(of questionID: UUID) -> [String] {
        guard let o = open.first(where: { $0.question.id == questionID }) else { return [] }
        return [o.question.request.token] + o.followerTokens
    }

    // MARK: Wording

    /// What kind of question is shown, for the Connection Log (never its text: a server words it).
    public nonisolated static func questionKind(_ request: AskPassRequest) -> String {
        if request.isConfirmation { return "trust a host key" }
        if request.isPassphrasePrompt || request.isUnverifiedPassphrasePrompt { return "a key's passphrase" }
        if request.isUnverifiedPasswordPrompt { return "a password (from an ssh that does not mark a server's questions)" }
        if request.isLoginPasswordPrompt { return "the account's password" }
        if request.isPasswordPrompt { return "a one-time code or another password the server asks for" }
        return request.isServerText ? "a question from the server" : "a question from ssh"
    }

    /// "key id_example" for a passphrase question (never the folder it is in).
    public nonisolated static func keyLabel(_ request: AskPassRequest) -> String {
        "key " + (request.keyPath.map { ($0 as NSString).lastPathComponent } ?? "")
    }

    /// Why Touch ID is asked (shown by macOS).
    public nonisolated static func reason(for request: AskPassRequest, key: String) -> String {
        if request.isPassphrasePrompt { return "unlock your SSH key \((request.keyPath.map { ($0 as NSString).lastPathComponent }) ?? "")" }
        return "sign in to \(key)"
    }
}
