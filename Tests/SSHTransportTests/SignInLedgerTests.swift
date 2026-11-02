import Foundation
import Testing
@testable import SSHTransport

/// The rules that depend on what was done for a sign-in's questions.
@Suite struct SignInLedgerTests {
    /// A password to save goes to the keychain only once the sign-in worked — never one that failed,
    /// and never twice.
    @Test func savedOnlyAfterSuccess() {
        let ledger = SignInLedger()
        let save = SignInLedger.Save(password: "example-password", item: "web")
        ledger.saveAfterSuccess(token: "t1", save)
        #expect(ledger.ended(token: "t1", end: .failed) == nil)
        ledger.saveAfterSuccess(token: "t2", save)
        #expect(ledger.ended(token: "t2", end: .notJudged) == nil)
        ledger.saveAfterSuccess(token: "t3", save)
        #expect(ledger.ended(token: "t3", end: .succeeded) == save)
        #expect(ledger.ended(token: "t3", end: .succeeded) == nil)
    }

    /// Asked again after the keychain's password: refused, and not sent by itself again until it is
    /// saved anew; a later successful save clears that.
    @Test func aRefusedKeychainPasswordWaitsUntilSavedAgain() {
        let ledger = SignInLedger()
        let attempt = SignInLedger.attemptKey(token: "t", login: "web")
        ledger.noteSent(attempt, fromKeychain: true)
        #expect(ledger.wasSent(attempt))
        #expect(ledger.noteAskedAgain(token: "t", attempt: attempt, login: "web"))
        #expect(ledger.judgeRepeat(token: "t", answer: "new-password") == .refused(login: "web", fromKeychain: true))
        #expect(ledger.isRefused("web"))
        ledger.saveAfterSuccess(token: "t", .init(password: "new-password", item: "web"))
        #expect(ledger.ended(token: "t", end: .succeeded) != nil)
        #expect(!ledger.isRefused("web"), "saved anew once it worked")
        #expect(!ledger.wasSent(attempt), "a sign-in's entries go when it ends")
    }

    /// The same "Password:" asked again and answered with digits only: a one-time code — the
    /// password before it was accepted and stays.
    @Test func digitsAfterTheSameQuestionAreASecondStep() {
        let ledger = SignInLedger()
        let attempt = SignInLedger.attemptKey(token: "t", login: "web")
        ledger.noteSent(attempt, fromKeychain: true)
        ledger.noteAskedAgain(token: "t", attempt: attempt, login: "web")
        #expect(ledger.judgeRepeat(token: "t", answer: "123456") == .secondStep(login: "web"))
        #expect(!ledger.isRefused("web"))
        #expect(ledger.judgeRepeat(token: "t", answer: "123456") == .none, "judged once")
    }

    /// Cancelling the repeated question counts the earlier answer as refused (never resent by itself).
    @Test func aCancelAfterARepeatCountsAsRefused() {
        let ledger = SignInLedger()
        let attempt = SignInLedger.attemptKey(token: "t", login: "web")
        ledger.noteSent(attempt)
        ledger.noteAskedAgain(token: "t", attempt: attempt, login: "web")
        #expect(ledger.judgeRepeat(token: "t", answer: nil) == .refused(login: "web", fromKeychain: false))
    }

    /// A key's passphrase is told apart per ssh process: the jump host's own ssh opening the same
    /// key is not a sign of a wrong passphrase.
    @Test func passphrasesArePerProcess() {
        #expect(SignInLedger.attemptKey(token: "t", login: "k", askerPID: 10) != SignInLedger.attemptKey(token: "t", login: "k", askerPID: 11))
    }

    /// An answer saved after the server's login time goes with the fresh sign-in it is handed to.
    @Test func aLateSaveGoesWithTheFreshSignIn() {
        let ledger = SignInLedger()
        ledger.saveLate(login: "web", .init(password: "late", item: "web"))
        ledger.handLateSave(login: "web", password: "other", to: "t1")
        #expect(ledger.ended(token: "t1", end: .succeeded) == nil, "another password: not this save")
        ledger.handLateSave(login: "web", password: "late", to: "t2")
        #expect(ledger.ended(token: "t2", end: .succeeded)?.password == "late")
    }
}
