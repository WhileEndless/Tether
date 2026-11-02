import Foundation
import Testing
@testable import SSHTransport

/// When servers can be reached again, said once for everything that waits.
@MainActor
@Suite struct HostLinksTests {
    @Test func aWaitEndsWhenItsServerSignsIn() async throws {
        let links = HostLinks()
        let waiting = Task { await links.whenReachable("web.example.com", within: 30) }
        try await Task.sleep(for: .milliseconds(50))
        links.post(.signedIn("other.example.com"))          // another server: still waiting
        try await Task.sleep(for: .milliseconds(50))
        links.post(.signedIn("web.example.com"))
        #expect(await waiting.value)
    }

    @Test func theNetworkOrAnUnlockEndsEveryWait() async throws {
        let links = HostLinks()
        let a = Task { await links.whenReachable("a.example.com", within: 30) }
        let b = Task { await links.whenReachable("b.example.com", within: 30) }
        try await Task.sleep(for: .milliseconds(50))
        links.post(.networkBack)
        let (ra, rb) = (await a.value, await b.value)
        #expect(ra && rb)
        let c = Task { await links.whenReachable("c.example.com", within: 30) }
        try await Task.sleep(for: .milliseconds(50))
        links.post(.unlocked)
        #expect(await c.value)
    }

    @Test func aWaitEndsByItselfOrWhenCancelled() async throws {
        let links = HostLinks()
        #expect(await links.whenReachable("web.example.com", within: 0.05) == false)
        let waiting = Task { await links.whenReachable("web.example.com", within: 30) }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        #expect(await waiting.value == false)
    }

    @Test func observersHearEveryEvent() {
        let links = HostLinks()
        var heard: [HostLinks.Event] = []
        let id = links.observe { heard.append($0) }
        links.post(.networkBack)
        links.post(.signedIn("web.example.com"))
        links.stopObserving(id)
        links.post(.unlocked)
        #expect(heard == [.networkBack, .signedIn("web.example.com")])
    }

    /// After you cancel a server's sign-in, what follows by itself does not ask again for a moment;
    /// asking for it again (Retry) or a sign-in that worked lifts that.
    @Test func aCancelHoldsBackWhatFollowsByItself() {
        let links = HostLinks()
        #expect(links.mayAskByItself("web.example.com"))
        links.noteCancelled("web.example.com")
        #expect(!links.mayAskByItself("web.example.com"))
        #expect(links.mayAskByItself("other.example.com"))
        links.signInWanted("web.example.com")
        #expect(links.mayAskByItself("web.example.com"))
        links.noteCancelled("web.example.com")
        links.post(.signedIn("web.example.com"))
        #expect(links.mayAskByItself("web.example.com"))
    }

    @Test func aServerThatAsksASecondStepIsRemembered() {
        let links = HostLinks()
        #expect(!links.asksSecondStep("otp.example.com"))
        links.noteSecondStep("otp.example.com")
        #expect(links.asksSecondStep("otp.example.com"))
        #expect(!links.asksSecondStep("web.example.com"))
    }
}
