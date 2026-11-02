import Foundation
import Testing
@testable import SSHTransport

/// Sign-in passwords of a run: kept only sealed, only for the connection they were given to, only
/// after the sign-in worked, dropped when refused.
@Suite struct SealedPasswordCacheTests {
    /// Stands in for the Secure Enclave: reversible, and the sealed form never contains the text.
    struct FakeSealer: PasswordSealer {
        func seal(_ plain: Data) -> Data? { Data(plain.reversed().map { $0 ^ 0x5a }) }
        func open(_ sealed: Data) -> Data? { Data(sealed.map { $0 ^ 0x5a }.reversed()) }
    }

    /// Off until the ssh program is known to mark servers' own questions; here it is.
    func cache() -> SealedPasswordCache {
        let c = SealedPasswordCache(sealer: FakeSealer())
        c.sshNamesItsQuestions = true
        return c
    }

    /// A sign-in: bound to its connection, given a password, succeeded.
    func signIn(_ c: SealedPasswordCache, _ password: String, connection: String, login: String, token: String = UUID().uuidString) {
        c.bind(token: token, connection: connection)
        c.offer(password, login: login, token: token, source: .typed)
        c.commit(token: token)
    }

    /// The next sign-in to `connection`: what it would be answered with.
    func lookup(_ c: SealedPasswordCache, connection: String, login: String) -> String? {
        let token = UUID().uuidString
        c.bind(token: token, connection: connection)
        return c.password(token: token, login: login)?.password
    }

    /// A key file's passphrase opens that key whatever it signs in to: typed once for one server,
    /// it answers the key's question for another too; refused (a wrong one), it is gone. A server's
    /// password never goes to another server.
    @Test func aKeysPassphraseBelongsToTheKey() {
        let c = cache()
        let key = SealedPasswordCache.passphrasePrefix + "/Users/user/.ssh/id_example"
        signIn(c, "example-passphrase", connection: "/s/first", login: key)
        #expect(lookup(c, connection: "/s/second", login: key) == "example-passphrase", "the same key, another server")
        signIn(c, "example-password", connection: "/s/first", login: "user@example.com")
        #expect(lookup(c, connection: "/s/second", login: "user@example.com") == nil, "a password stays with its connection")
        let token = UUID().uuidString
        c.bind(token: token, connection: "/s/third")
        _ = c.password(token: token, login: key)
        c.reject(token: token, login: key)
        #expect(lookup(c, connection: "/s/first", login: key) == nil, "refused: never sent again")
    }

    @Test func keptOnlyAfterTheSignInWorked() {
        let c = cache()
        c.bind(token: "t1", connection: "/s/abc")
        c.offer("example-password", login: "user@example.com", token: "t1", source: .typed)
        #expect(c.count == 0, "not remembered before the server accepted it (only handed to this connection's sign-ins for a minute)")
        c.commit(token: "t1")
        #expect(c.count == 1)
        #expect(lookup(c, connection: "/s/abc", login: "user@example.com") == "example-password")
    }

    /// Another port, another jump host or another user is another connection (another socket name):
    /// a password is never offered there, even when ssh's question names the same user@host.
    @Test func onlyForTheSameConnection() {
        let c = cache()
        signIn(c, "secret", connection: "/s/port22", login: "user@example.com")
        #expect(lookup(c, connection: "/s/port2223", login: "user@example.com") == nil)
        #expect(lookup(c, connection: "/s/port22", login: "admin@example.com") == nil)
        let unbound = "never-bound"
        #expect(c.password(token: unbound, login: "user@example.com") == nil, "a sign-in Tether did not start gets nothing")
    }

    @Test func aFailedSignInKeepsNothing() {
        let c = cache()
        c.bind(token: "t1", connection: "/s/abc")
        c.offer("typo", login: "u@h", token: "t1", source: .typed)
        c.discard(token: "t1")
        c.commit(token: "t1")
        #expect(c.count == 0)
    }

    @Test func aRefusedPasswordIsNeverSentAgain() {
        let c = cache()
        signIn(c, "old", connection: "/s/abc", login: "u@h")
        let token = UUID().uuidString
        c.bind(token: token, connection: "/s/abc")
        #expect(c.password(token: token, login: "u@h")?.password == "old")
        c.reject(token: token, login: "u@h")
        #expect(lookup(c, connection: "/s/abc", login: "u@h") == nil)
    }

    /// A sign-in answered with the remembered password failed without ssh saying "Permission
    /// denied" (the server hung up: fail2ban, pam_faillock, a network device; or it was stopped):
    /// that password is never sent again — every reconnect retrying it would lock the account.
    /// A sign-in that failed before ssh asked for it (no route, host not found) forgets nothing.
    @Test func anyFailureAfterTheRememberedPasswordWasSentForgetsIt() {
        let c = cache()
        signIn(c, "old", connection: "/s/abc", login: "u@h")
        c.bind(token: "unreachable", connection: "/s/abc")
        c.discard(token: "unreachable")
        #expect(lookup(c, connection: "/s/abc", login: "u@h") == "old", "never asked for: kept")
        c.bind(token: "hung-up", connection: "/s/abc")
        #expect(c.password(token: "hung-up", login: "u@h")?.password == "old")
        c.discard(token: "hung-up")
        #expect(lookup(c, connection: "/s/abc", login: "u@h") == nil)
    }

    /// *Forget them after …* counts from when the password was typed: using it (an answer taken
    /// from the cache is not given back to it) does not make it last longer.
    @Test func usingAPasswordDoesNotExtendItsTime() throws {
        let c = cache()
        signIn(c, "pw", connection: "/s/abc", login: "u@h")
        let typedAt = try #require(c.items().first).since
        let token = UUID().uuidString
        c.bind(token: token, connection: "/s/abc")
        #expect(c.password(token: token, login: "u@h")?.password == "pw")
        c.commit(token: token)
        #expect(c.items().first?.since == typedAt)
        c.maxAge = 0
        #expect(lookup(c, connection: "/s/abc", login: "u@h") == nil, "past its time: gone, however often it was used")
    }

    /// Waking from sleep, the network is often not back when the first sign-in starts: one that
    /// failed on the way (no answer, no route) was never refused, and what it was answered with
    /// stays — the next try signs in without asking. A connection closed or reset is not the
    /// network's doing for sure (a server can hang up instead of saying no): forgotten.
    @Test func aNetworkFailureKeepsTheRememberedPassword() {
        let c = cache()
        signIn(c, "pw", connection: "/s/abc", login: "u@h")
        c.bind(token: "timed-out", connection: "/s/abc")
        #expect(c.password(token: "timed-out", login: "u@h")?.password == "pw")
        c.discard(token: "timed-out", end: .notJudged)
        #expect(lookup(c, connection: "/s/abc", login: "u@h") == "pw")
        #expect(SealedPasswordCache.isNetworkFailure("ssh: connect to host 192.0.2.5 port 22: Operation timed out"))
        #expect(SealedPasswordCache.isNetworkFailure("connect to address 192.0.2.5 port 22: Host is down"))
        #expect(!SealedPasswordCache.isNetworkFailure("Connection closed by 192.0.2.5 port 22"))
        #expect(!SealedPasswordCache.isNetworkFailure("ssh_dispatch_run_fatal: Connection to 192.0.2.5 port 22: Broken pipe"))
        #expect(!SealedPasswordCache.isNetworkFailure("user@example.com: Permission denied (publickey,password)."))
    }

    /// When ssh asks although passwords are remembered, the Connection Log says why (never the
    /// password, nor where it goes).
    @Test func saysWhyNothingAnswered() {
        let c = cache()
        let first = UUID().uuidString
        c.bind(token: first, connection: "/s/abc")
        #expect(c.whyNotRemembered(token: first, login: "u@h") == "nothing was remembered for this connection since Tether started")
        signIn(c, "pw", connection: "/s/abc", login: "u@h")
        let elsewhere = UUID().uuidString
        c.bind(token: elsewhere, connection: "/s/other-port")
        #expect(c.whyNotRemembered(token: elsewhere, login: "u@h").contains("another connection"))
        let refused = UUID().uuidString
        c.bind(token: refused, connection: "/s/abc")
        c.reject(token: refused, login: "u@h")
        #expect(c.whyNotRemembered(token: refused, login: "u@h") == "it was forgotten: the server did not accept it")
        signIn(c, "pw", connection: "/s/abc", login: "u@h")
        c.removeAll(reason: "Tether was locked (App Lock)")
        let later = UUID().uuidString
        c.bind(token: later, connection: "/s/abc")
        #expect(c.whyNotRemembered(token: later, login: "u@h") == "it was forgotten: Tether was locked (App Lock)")
        #expect(c.whyNotRemembered(token: "never-bound", login: "u@h").contains("not one Tether started"))
        let off = SealedPasswordCache(sealer: FakeSealer())
        #expect(off.whyNotRemembered(token: first, login: "u@h") == "the ssh program was still being checked")
    }

    /// What a sign-in gave is reported once it worked (for the log: logins, never passwords).
    @Test func commitTellsWhatWasRemembered() {
        let c = cache()
        c.bind(token: "t", connection: "/s/abc")
        c.offer("pw", login: "u@h", token: "t", source: .keychain)
        #expect(c.commit(token: "t") == ["u@h"])
        #expect(c.commit(token: "t").isEmpty)
    }

    /// Sent and then nothing from the server until Tether gave up: perhaps a slow server, perhaps
    /// one that goes silent instead of refusing. Sent once more at most, then forgotten.
    @Test func anUnansweredPasswordIsSentOnceMoreAtMost() {
        let c = cache()
        signIn(c, "pw", connection: "/s/abc", login: "u@h")
        c.bind(token: "silent-1", connection: "/s/abc")
        #expect(c.password(token: "silent-1", login: "u@h")?.password == "pw")
        c.discard(token: "silent-1", end: .unanswered)
        c.bind(token: "silent-2", connection: "/s/abc")
        #expect(c.password(token: "silent-2", login: "u@h")?.password == "pw", "once more")
        c.discard(token: "silent-2", end: .unanswered)
        #expect(lookup(c, connection: "/s/abc", login: "u@h") == nil, "then never again")
        // Answered after all: no longer in doubt.
        signIn(c, "pw", connection: "/s/abc", login: "u@h")
        c.bind(token: "silent-3", connection: "/s/abc")
        _ = c.password(token: "silent-3", login: "u@h")
        c.discard(token: "silent-3", end: .unanswered)
        c.bind(token: "works", connection: "/s/abc")
        _ = c.password(token: "works", login: "u@h")
        c.commit(token: "works")
        c.bind(token: "silent-4", connection: "/s/abc")
        _ = c.password(token: "silent-4", login: "u@h")
        c.discard(token: "silent-4", end: .unanswered)
        #expect(lookup(c, connection: "/s/abc", login: "u@h") == "pw")
    }

    /// One question per server: a typed answer goes to the same connection's next sign-ins for a
    /// minute — also with remembering turned off, and also when the sign-in it was typed for was
    /// stopped before the server judged it (a question answered late, a tab closed).
    @Test func aTypedAnswerIsHandedToTheSameConnection() {
        let c = cache()
        c.isEnabled = false
        c.bind(token: "first", connection: "/s/abc")
        c.offer("typed", login: "u@h", token: "first", source: .typed)
        c.discard(token: "first", end: .notJudged)
        #expect(lookup(c, connection: "/s/abc", login: "u@h") == "typed")
        #expect(lookup(c, connection: "/s/other", login: "u@h") == nil, "never another connection")
        #expect(c.count == 0, "nothing remembered with remembering off")
        // Refused: not handed on.
        c.bind(token: "refused", connection: "/s/abc")
        #expect(c.password(token: "refused", login: "u@h")?.password == "typed")
        c.discard(token: "refused", end: .failed)
        #expect(lookup(c, connection: "/s/abc", login: "u@h") == nil)
        // The screen locked with "forget when locking" (removeAll): gone too.
        c.bind(token: "again", connection: "/s/abc")
        c.offer("typed", login: "u@h", token: "again", source: .typed)
        c.removeAll()
        #expect(lookup(c, connection: "/s/abc", login: "u@h") == nil)
        // A keychain answer is not handed on (it is read again, with Touch ID when that is on).
        c.bind(token: "keychain", connection: "/s/abc")
        c.offer("saved", login: "u@h", token: "keychain", source: .keychain)
        #expect(lookup(c, connection: "/s/abc", login: "u@h") == nil)
    }

    /// The same "Password:" asked again: digits only are a one-time code, anything else a password.
    @Test func oneTimeCodesAreToldFromPasswords() {
        #expect(SealedPasswordCache.looksLikeOneTimeCode("123456"))
        #expect(SealedPasswordCache.looksLikeOneTimeCode("12345678"))
        #expect(!SealedPasswordCache.looksLikeOneTimeCode("123"))
        #expect(!SealedPasswordCache.looksLikeOneTimeCode("example-password"))
        #expect(!SealedPasswordCache.looksLikeOneTimeCode("12345678901"))
        #expect(!SealedPasswordCache.looksLikeOneTimeCode("\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}"), "only ASCII digits")
    }

    /// A typed answer the server refused by hanging up (no second question), with remembering off:
    /// its own sign-in failing takes the hand-off back.
    @Test func aFailedTypedAnswerIsNotHandedOn() {
        let c = cache()
        c.isEnabled = false
        c.bind(token: "typed", connection: "/s/abc")
        c.offer("wrong", login: "u@h", token: "typed", source: .typed)
        c.discard(token: "typed", end: .failed)
        #expect(lookup(c, connection: "/s/abc", login: "u@h") == nil)
    }

    /// The sign-in a password was typed for was stopped before the server judged it; the next one
    /// takes it from the hand-off and works: it is remembered then, as if typed for that one.
    @Test func aHandedOffAnswerIsRememberedWhenItWorks() {
        let c = cache()
        c.bind(token: "stopped", connection: "/s/abc")
        c.offer("typed", login: "u@h", token: "stopped", source: .typed)
        c.discard(token: "stopped", end: .notJudged)
        #expect(c.count == 0)
        c.bind(token: "next", connection: "/s/abc")
        #expect(c.password(token: "next", login: "u@h")?.password == "typed")
        c.commit(token: "next")
        #expect(c.count == 1)
        #expect(lookup(c, connection: "/s/abc", login: "u@h") == "typed")
    }

    /// The same server and user under another name (another alias, Quick Connect) on the same
    /// connection: the password typed under one answers the other.
    @Test func theSameAccountUnderAnotherName() {
        let c = cache()
        c.bind(token: "t1", connection: "/s/abc")
        c.offer("pw", login: "web", token: "t1", source: .typed, named: "user@web.example.com")
        c.commit(token: "t1")
        let t2 = UUID().uuidString
        c.bind(token: t2, connection: "/s/abc")
        #expect(c.password(token: t2, login: "web-admin-alias", named: "user@web.example.com")?.password == "pw")
        let t3 = UUID().uuidString
        c.bind(token: t3, connection: "/s/abc")
        #expect(c.password(token: t3, login: "other", named: "admin@web.example.com") == nil, "another user")
    }

    /// A key's passphrase typed for a sign-in the server then refused (the key, or a password) is
    /// kept: the key opened with it.
    @Test func aPassphraseSurvivesAnotherFailure() {
        let c = cache()
        let key = SealedPasswordCache.passphrasePrefix + "/Users/user/.ssh/id_example"
        c.bind(token: "t", connection: "/s/abc")
        c.offer("phrase", login: key, token: "t", source: .typed)
        c.offer("wrong", login: "u@h", token: "t", source: .typed)
        c.discard(token: "t", end: .failed)
        #expect(lookup(c, connection: "/s/other", login: key) == "phrase")
        #expect(lookup(c, connection: "/s/abc", login: "u@h") == nil)
    }

    /// A saved password changed or removed: the copy remembered from it is not used any more.
    @Test func forgettingALoginSaysWhy() {
        let c = cache()
        signIn(c, "pw", connection: "/s/abc", login: "web")
        c.forget(login: "web", reason: "its saved password was changed or removed")
        let t = UUID().uuidString
        c.bind(token: t, connection: "/s/abc")
        #expect(c.password(token: t, login: "web") == nil)
        #expect(c.whyNotRemembered(token: t, login: "web") == "it was forgotten: its saved password was changed or removed")
    }

    @Test func offWhenDisabledWithoutASecureEnclaveOrWithAnOldSSH() {
        let none = SealedPasswordCache(sealer: nil)
        none.sshNamesItsQuestions = true
        signIn(none, "x", connection: "/s", login: "u@h")
        #expect(!none.isAvailable && none.count == 0, "nothing is kept unsealed")
        let off = cache()
        off.isEnabled = false
        signIn(off, "x", connection: "/s", login: "u@h")
        #expect(off.count == 0)
        let old = cache()
        old.sshNamesItsQuestions = false
        signIn(old, "x", connection: "/s", login: "u@h")
        #expect(old.count == 0)
    }

    @Test func removeAllForgetsEverything() {
        let c = cache()
        signIn(c, "a", connection: "/s/a", login: "u@a")
        c.bind(token: "t2", connection: "/s/b")
        c.offer("b", login: "u@b", token: "t2", source: .typed)
        c.removeAll()
        c.commit(token: "t2")
        #expect(c.count == 0)
    }

    @Test func offUntilTheSSHProgramIsKnown() {
        let c = SealedPasswordCache(sealer: FakeSealer())
        signIn(c, "x", connection: "/s", login: "u@h")
        #expect(c.count == 0)
    }

    @Test func onlySSHThatNamesItsQuestions() {
        #expect(SSHVersion.namesItsQuestions("OpenSSH_10.3p1, LibreSSL 3.3.6"))
        #expect(SSHVersion.namesItsQuestions("OpenSSH_8.4p1"))
        #expect(!SSHVersion.namesItsQuestions("OpenSSH_8.2p1 Ubuntu"))
        #expect(!SSHVersion.namesItsQuestions("something else"))
    }

    /// The real sealer: what is held cannot be read without this run's Secure Enclave key.
    @Test(.enabled(if: SecureEnclaveSealer() != nil)) func secureEnclaveSealing() throws {
        let sealer = try #require(SecureEnclaveSealer())
        let plain = Data("example-password".utf8)
        let sealed = try #require(sealer.seal(plain))
        #expect(sealed.range(of: plain) == nil)
        #expect(sealer.open(sealed) == plain)
        let other = try #require(SecureEnclaveSealer())
        #expect(other.open(sealed) == nil, "another run's key cannot open it")
    }
}
