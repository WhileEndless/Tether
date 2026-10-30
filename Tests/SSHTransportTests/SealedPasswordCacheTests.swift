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
        #expect(lookup(c, connection: "/s/abc", login: "user@example.com") == nil, "not before the server accepted it")
        c.commit(token: "t1")
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

    @Test func keychainEntriesGoWhenTouchIDLocksAgain() {
        let c = cache()
        signIn(c, "typed", connection: "/s/a", login: "u@a")
        c.bind(token: "k", connection: "/s/b")
        c.offer("saved", login: "u@b", token: "k", source: .keychain)
        c.commit(token: "k")
        c.removeKeychainEntries()
        #expect(lookup(c, connection: "/s/a", login: "u@a") == "typed")
        #expect(lookup(c, connection: "/s/b", login: "u@b") == nil)
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
