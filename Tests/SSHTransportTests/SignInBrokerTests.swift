import Foundation
import Testing
@testable import SSHTransport

/// How askpass questions are answered, end to end with a stand-in for the app: one question however
/// many ssh processes ask, an answer handed on, the keychain written only after success, a one-time
/// code told from a refusal, nothing while locked.
@MainActor
@Suite(.serialized) struct SignInBrokerTests {
    struct FakeSealer: PasswordSealer {
        func seal(_ plain: Data) -> Data? { Data(plain.reversed().map { $0 ^ 0x5a }) }
        func open(_ sealed: Data) -> Data? { Data(sealed.map { $0 ^ 0x5a }.reversed()) }
    }

    final class FakeHost: SignInHost {
        var isLocked = false
        var saved: [String: String] = [:]
        var savedPasswordNeedsSomeone = false
        var checkName: String { "Touch ID" }
        var keychainReads = 0
        var paused: [String] = []
        var ended: [String] = []
        var savedNow: [(String, String)] = []
        var shown: [SignInQuestion] = []
        func sshCheckSettled() async {}
        func savedPasswordKey(for request: AskPassRequest) -> String? { request.isPassphrasePrompt ? nil : "web" }
        func passwordKey(for request: AskPassRequest) -> String { "web" }
        func takeQuickConnectPassword(for request: AskPassRequest) -> String? { nil }
        func hasSavedPassword(_ item: String) -> Bool { saved[item] != nil }
        func readSavedPassword(_ item: String, reason: String) async -> String? { keychainReads += 1; return saved[item] }
        func waitForUser(token: String, sessionID: UUID?, host: String) {}
        func pauseAfterCancel(_ request: AskPassRequest) { paused.append(request.token) }
        func signInAgain(_ request: AskPassRequest) {}
        func save(_ password: String, for item: String, replacesRemembered: Bool) { savedNow.append((item, password)) }
        func isLive(_ token: String) -> Bool { !ended.contains(token) }
        func endSignIn(_ token: String) { ended.append(token) }
        func questionsChanged(_ questions: [SignInQuestion]) { shown = questions }
    }

    let host = FakeHost()
    let broker: SignInBroker

    init() {
        let cache = SealedPasswordCache(sealer: FakeSealer())
        cache.sshNamesItsQuestions = true
        broker = SignInBroker(cache: cache)
        broker.host = host
    }

    func request(_ token: String = UUID().uuidString, prompt: String = "user@web.example.com's password:",
                 purpose: String = "connect") -> AskPassRequest {
        var r = AskPassRequest(token: token, targetKey: "web", purpose: purpose, prompt: prompt, sequence: 1)
        r.askerNamesItsQuestions = true
        return r
    }

    /// Waits until `count` questions are open.
    func shown(_ count: Int) async throws {
        for _ in 0..<500 where host.shown.count < count { try await Task.sleep(for: .milliseconds(10)) }
        #expect(host.shown.count == count)
    }

    /// Twelve ssh processes of one server ask its password at the same moment: the user answers once,
    /// and every one of them gets the answer.
    @Test func manyAskTheUserAnswersOnce() async throws {
        let asking = (0..<12).map { _ in request() }
        let answers = asking.map { r in Task { await broker.answer(r) } }
        try await shown(12)
        broker.resolve(host.shown[0].id, with: .text("example-password", save: false))
        for a in answers { #expect(await a.value == "example-password") }
        #expect(host.shown.isEmpty, "every question went with the one answer")
    }

    /// A password typed for one sign-in answers the next sign-in of the same connection without
    /// asking (handed on, then remembered once the server accepted it).
    @Test func theNextSignInOfTheConnectionIsNotAsked() async throws {
        let first = request()
        broker.cache.bind(token: first.token, connection: "/s/web")
        let a = Task { await broker.answer(first) }
        try await shown(1)
        broker.resolve(host.shown[0].id, with: .text("example-password", save: false))
        #expect(await a.value == "example-password")
        SignInEvents.shared.post(.ended(token: first.token, end: .succeeded))
        _ = broker.cache.commit(token: first.token)
        let next = request()
        broker.cache.bind(token: next.token, connection: "/s/web")
        #expect(await broker.answer(next) == "example-password")
        #expect(host.shown.isEmpty)
    }

    /// "Save" goes to the keychain only once the sign-in worked (a connection's sign-in); without a
    /// connection to report how it ended, at once.
    @Test func savedOnlyOnceTheSignInWorked() async throws {
        let shared = request()
        broker.cache.bind(token: shared.token, connection: "/s/web")
        let a = Task { await broker.answer(shared) }
        try await shown(1)
        broker.resolve(host.shown[0].id, with: .text("new-password", save: true))
        _ = await a.value
        #expect(host.savedNow.isEmpty, "not before the server accepted it")
        #expect(broker.ledger.ended(token: shared.token, end: .succeeded)?.password == "new-password")

        let own = request()
        let b = Task { await broker.answer(own) }
        try await shown(1)
        broker.resolve(host.shown[0].id, with: .text("other-password", save: true))
        _ = await b.value
        #expect(host.savedNow.map(\.1) == ["other-password"])
    }

    /// The keychain's password is sent once; the same question again with only digits typed is a
    /// one-time code — the saved password stays usable.
    @Test func aCodeAfterTheSavedPasswordKeepsIt() async throws {
        host.saved["web"] = "saved-password"
        let token = UUID().uuidString
        #expect(await broker.answer(request(token)) == "saved-password")
        let again = Task { await broker.answer(request(token, prompt: "(user@web.example.com) Password:")) }
        try await shown(1)
        #expect(host.shown[0].savedWasRejected, "asked again after the saved password")
        broker.resolve(host.shown[0].id, with: .text("123456", save: true))
        #expect(await again.value == "123456")
        #expect(!broker.ledger.isRefused("web"))
        #expect(host.savedNow.isEmpty, "a code is never saved")
    }

    /// Asked again and answered with a password: the saved one was refused and is not sent by itself
    /// again in this run.
    @Test func aRefusedSavedPasswordIsNotSentAgain() async throws {
        host.saved["web"] = "old-password"
        let token = UUID().uuidString
        #expect(await broker.answer(request(token)) == "old-password")
        let again = Task { await broker.answer(request(token)) }
        try await shown(1)
        broker.resolve(host.shown[0].id, with: .text("new-password", save: false))
        _ = await again.value
        #expect(broker.ledger.isRefused("web"))
        let reads = host.keychainReads
        let later = Task { await broker.answer(request()) }
        try await shown(1)
        #expect(host.keychainReads == reads, "the refused item is not read again")
        broker.resolve(host.shown[0].id, with: .cancel)
        _ = await later.value
    }

    @Test func nothingWhileLocked() async {
        host.isLocked = true
        let r = request()
        #expect(await broker.answer(r) == nil)
        #expect(host.ended == [r.token])
        #expect(host.shown.isEmpty)
    }

    /// Background work never gets a remembered or saved password, and never asks.
    @Test func quietWorkIsNeverAnswered() async {
        host.saved["web"] = "saved-password"
        #expect(await broker.answer(request(purpose: "monitor")) == nil)
        #expect(host.keychainReads == 0 && host.shown.isEmpty)
    }

    /// The same new host key asked by several connections: one question, one answer for all, and the
    /// same answer for one more asked right after.
    @Test func aHostKeyQuestionIsShownOnce() async throws {
        let text = "The authenticity of host 'web.example.com (192.0.2.5)' can't be established.\nED25519 key fingerprint is SHA256:example.\nAre you sure you want to continue connecting (yes/no/[fingerprint])?"
        let asking = (0..<3).map { _ in request(prompt: text) }
        #expect(asking[0].isConfirmation)
        let answers = asking.map { r in Task { await broker.answer(r) } }
        try await shown(1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.shown.count == 1)
        broker.resolve(host.shown[0].id, with: .yes)
        for a in answers { #expect(await a.value == "yes") }
        #expect(await broker.answer(request(prompt: text)) == "yes")
    }

    /// Cancel ends the ssh and stops the tabs it stood for (until Reconnect).
    @Test func cancelStopsItsTabs() async throws {
        let r = request()
        let a = Task { await broker.answer(r) }
        try await shown(1)
        broker.resolve(host.shown[0].id, with: .cancel)
        #expect(await a.value == nil)
        #expect(host.paused == [r.token] && host.ended == [r.token])
    }
}
