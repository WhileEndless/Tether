import Foundation
import Testing
import TetherCore
import TestSupport
@testable import SSHTransport

/// One sign-in per server, whatever wants the connection, with a fake ssh that behaves like
/// OpenSSH's shared connections (`FakeSharedSSH`). Everything lives in a private folder.
@Suite(.serialized) final class SharedConnectionsTests {
    let dir: URL
    let ssh: URL

    init() throws {
        // Short: Unix socket paths are limited to 104 bytes.
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tsc-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ssh = try FakeSharedSSH.install(in: dir)
    }

    deinit {
        FakeSharedSSH.stopMasters(in: dir)
        try? FileManager.default.removeItem(at: dir)
    }

    func options() -> SSHOptions {
        SSHOptions(sshBinary: ssh.path, useControlMaster: true)
    }

    func host() -> ConnectionTarget { .alias("host-\(UUID().uuidString.prefix(6))") }

    func signIn() -> SharedConnections.SignIn { .init(purpose: "connect") }

    /// Sockets are worked out in (and stale ones removed only from) this test's folder.
    func isolate() async {
        await SharedConnectionsTestLock.shared.acquire()
        await SharedConnections.shared.useSocketDirectory(dir)
    }

    func finish() async {
        await SharedConnections.shared.reset()
        await SharedConnectionsTestLock.shared.release()
    }

    /// A server that hangs up after a wrong password (no second question): the remembered password
    /// that sign-in was answered with is dropped, not retried on every reconnect.
    @Test func aPasswordRefusedWithoutAskingAgainIsForgotten() {
        let c = SealedPasswordCache(sealer: SealedPasswordCacheTests.FakeSealer())
        c.sshNamesItsQuestions = true
        c.bind(token: "first", connection: "/s/a")
        c.offer("old", login: "u@h", token: "first", source: .typed)
        c.commit(token: "first")
        c.bind(token: "second", connection: "/s/a")
        #expect(c.password(token: "second", login: "u@h")?.password == "old")
        c.discard(token: "second")
        c.bind(token: "third", connection: "/s/a")
        #expect(c.password(token: "third", login: "u@h") == nil)
        #expect(BackgroundSignIn.reasonFor(stderr: "user@example.com: Permission denied (password).") == .password)
    }

    @Test func manyAtOnceSignInOnce() async throws {
        await isolate()
        let target = host(), o = options()
        let outcomes = await withTaskGroup(of: SharedConnections.Outcome.self) { group in
            for _ in 0..<50 { group.addTask { await SharedConnections.shared.prepare(target, options: o, signIn: self.signIn()) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let sockets = Set(outcomes.compactMap { outcome -> String? in
            if case .ready(let ready, _) = outcome { return ready.controlPath }
            return nil
        })
        #expect(outcomes.count == 50)
        #expect(sockets.count == 1, "all fifty use the one connection")
        #expect(FakeSharedSSH.logins(in: dir).filter { $0 == "start" }.count == 1, "one sign-in for fifty")
        // Already there: no sign-in at all.
        if case .ready(_, let reused) = await SharedConnections.shared.prepare(target, options: o, signIn: signIn()) {
            #expect(reused)
        } else { Issue.record("not ready") }
        #expect(FakeSharedSSH.logins(in: dir).filter { $0 == "start" }.count == 1)
        await finish()
    }

    /// One server's further connections (more tabs than one carries) sign in one after another,
    /// whichever asks first — also the first connection after a further one: a remembered password
    /// is never sent by several of them at the same moment (a changed one would fail several times).
    @Test func connectionsOfOneServerSignInOneAtATime() async throws {
        await isolate()
        let target = host()
        func slot(_ n: Int) -> SSHOptions { var o = options(); o.controlSlot = n; return o }
        let outcomes = await withTaskGroup(of: SharedConnections.Outcome.self) { group in
            group.addTask { await SharedConnections.shared.prepare(target, options: slot(1), signIn: self.signIn()) }
            try? await Task.sleep(for: .milliseconds(80))
            for n in [0, 2] { group.addTask { await SharedConnections.shared.prepare(target, options: slot(n), signIn: self.signIn()) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(outcomes.allSatisfy { if case .ready = $0 { true } else { false } })
        #expect(FakeSharedSSH.logins(in: dir) == ["start", "end", "start", "end", "start", "end"], "never two sign-ins at once")
        await finish()
    }

    @Test func aCancelledWaiterDoesNotStopTheSignInForTheOthers() async throws {
        await isolate()
        let target = host(), o = options()
        let first = Task { await SharedConnections.shared.prepare(target, options: o, signIn: self.signIn()) }
        try await Task.sleep(for: .milliseconds(50))
        let second = Task { await SharedConnections.shared.prepare(target, options: o, signIn: self.signIn()) }
        try await Task.sleep(for: .milliseconds(50))
        first.cancel()
        if case .failed = await first.value {} else { Issue.record("the cancelled waiter stops waiting") }
        guard case .ready = await second.value else { Issue.record("the other waiter gets the connection"); await finish(); return }
        #expect(FakeSharedSSH.logins(in: dir) == ["start", "end"])
        await finish()
    }

    /// A server that never answers (its sign-in hangs, a further connection of it waits for that
    /// one, background work waits too) holds up only itself: another server signs in at once.
    @Test func aServerThatDoesNotAnswerNeverDelaysAnother() async throws {
        await isolate()
        let stuck = host(), other = host()
        func slot(_ n: Int) -> SSHOptions { var o = options(); o.controlSlot = n; return o }
        let name = String(stuck.key.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        FileManager.default.createFile(atPath: dir.appendingPathComponent("hang-" + name).path, contents: Data())
        let waiting = [Task { await SharedConnections.shared.prepare(stuck, options: slot(0), signIn: self.signIn()) },
                       Task { await SharedConnections.shared.prepare(stuck, options: slot(1), signIn: self.signIn()) },
                       Task { await SharedConnections.shared.prepare(stuck, options: slot(0), signIn: nil) }]
        try await Task.sleep(for: .milliseconds(300))
        let start = Date()
        let outcome = await SharedConnections.shared.prepare(other, options: options(), signIn: signIn())
        if case .ready = outcome {} else { Issue.record("the other server signs in") }
        #expect(Date().timeIntervalSince(start) < 3, "not held up by the server that does not answer")
        #expect(FakeSharedSSH.logins(in: dir).filter { $0 == "end" }.count == 1, "the other server signed in while the first still hangs")
        // Closing the tabs that wait ends the hung sign-in (its ssh is stopped).
        waiting.forEach { $0.cancel() }
        for task in waiting { if case .ready = await task.value { Issue.record("the hung sign-in did not finish") } }
        await finish()
    }

    @Test func aRefusedSignInAnswersEveryWaiterOnce() async throws {
        await isolate()
        FileManager.default.createFile(atPath: dir.appendingPathComponent("refuse").path, contents: Data())
        let target = host(), o = options()
        let outcomes = await withTaskGroup(of: SharedConnections.Outcome.self) { group in
            for _ in 0..<5 { group.addTask { await SharedConnections.shared.prepare(target, options: o, signIn: self.signIn()) } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(outcomes.allSatisfy { if case .failed = $0 { true } else { false } })
        #expect(FakeSharedSSH.logins(in: dir).filter { $0 == "start" }.count == 1, "one refused attempt, not five")
        await finish()
    }

    @Test func backgroundWorkNeverSignsIn() async throws {
        await isolate()
        let target = host(), o = options()
        BackgroundSignIn.shared.markWaiting(target.key)
        defer { BackgroundSignIn.shared.clear(target.key) }
        guard case .needsUser = await SharedConnections.shared.prepare(target, options: o, signIn: nil) else {
            Issue.record("background work waits for the user"); await finish(); return
        }
        #expect(FakeSharedSSH.logins(in: dir).isEmpty)
        await finish()
    }

    @Test func aDeadConnectionIsSignedInAgainOnce() async throws {
        await isolate()
        let target = host(), o = options()
        guard case .ready(let ready, _) = await SharedConnections.shared.prepare(target, options: o, signIn: signIn()),
              let socket = ready.controlPath else { Issue.record("not ready"); await finish(); return }
        await SharedConnections.shared.reset()       // its silent channel ends too
        FakeSharedSSH.killMaster(socket: socket)
        #expect(await !SharedConnections.shared.isUp(target, options: o))
        let again = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    if case .ready = await SharedConnections.shared.prepare(target, options: o, signIn: self.signIn()) { return true }
                    return false
                }
            }
            return await group.reduce(true) { $0 && $1 }
        }
        #expect(again)
        #expect(FakeSharedSSH.logins(in: dir).filter { $0 == "start" }.count == 2, "the first and one more, not ten")
        await finish()
    }

    /// Hosts behind one jump host sign in to it once, through its own connection.
    @Test func hostsBehindOneJumpHostShareItsSignIn() async throws {
        await isolate()
        let jump = "jump-\(UUID().uuidString.prefix(4))", a = "a-\(UUID().uuidString.prefix(4))", b = "b-\(UUID().uuidString.prefix(4))"
        try "\(a) \(jump)\n\(b) \(jump)\n".write(to: dir.appendingPathComponent("jumps"), atomically: true, encoding: .utf8)
        let o = options()
        async let first = SharedConnections.shared.prepare(.alias(a), options: o, signIn: signIn())
        async let second = SharedConnections.shared.prepare(.alias(b), options: o, signIn: signIn())
        let results = await [first, second]
        #expect(results.allSatisfy { if case .ready = $0 { true } else { false } })
        #expect(FakeSharedSSH.logins(in: dir).filter { $0 == "start" }.count == 3, "the jump host once, then each host")
        let calls = (try? String(contentsOf: dir.appendingPathComponent("ssh-calls.log"), encoding: .utf8)) ?? ""
        let masters = calls.split(separator: "\n").filter { $0.contains("ControlMaster=yes") && ($0.hasSuffix(a) || $0.hasSuffix(b)) }
        #expect(masters.count == 2 && masters.allSatisfy { $0.contains("ProxyCommand=") && $0.contains("cm-\(jump.replacingOccurrences(of: "-", with: "_"))") && $0.contains("-W") })
        await finish()
    }

    /// A broken config where two hosts jump through each other, opened at the same moment, must not
    /// leave both waiting for each other for ever.
    @Test func jumpHostsThatLeadToEachOtherDoNotHang() async throws {
        await isolate()
        let a = "loop-a-\(UUID().uuidString.prefix(4))", b = "loop-b-\(UUID().uuidString.prefix(4))"
        try "\(a) \(b)\n\(b) \(a)\n".write(to: dir.appendingPathComponent("jumps"), atomically: true, encoding: .utf8)
        let o = options()
        let done = Task {
            async let first = SharedConnections.shared.prepare(.alias(a), options: o, signIn: self.signIn())
            async let second = SharedConnections.shared.prepare(.alias(b), options: o, signIn: self.signIn())
            _ = await [first, second]
            return true
        }
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await done.value }
            group.addTask { try? await Task.sleep(for: .seconds(15)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(finished, "both sign-ins end")
        await finish()
    }

    @Test func clientsOfTheConnectionCannotSignInOnTheirOwn() async throws {
        await isolate()
        let target = ConnectionTarget.adhoc(user: "user", host: "example.com", port: 2222, jump: "jump.example.com")
        var o = options()
        o.serverAliveInterval = 30
        o.controlPath = "/tmp/example-socket"
        let args = o.batchArguments(target: target, remoteCommand: "true")
        #expect(args.contains("ControlMaster=no"))
        #expect(args.contains("ProxyCommand=/usr/bin/false"))
        #expect(args.contains("ControlPath=/tmp/example-socket"))
        #expect(!args.contains("-J"), "the connection carries the jump host")
        #expect(!args.contains { $0.hasPrefix("ServerAlive") }, "clients send no keep-alives")
        let master = o.masterArguments(target: target, controlPath: "/tmp/example-socket", logFile: nil, proxyCommand: nil)
        #expect(master.contains("ControlMaster=yes") && master.contains("-N") && master.contains("-J"))
        #expect(master.contains("ServerAliveInterval=30"))
        var plain = SSHOptions(useControlMaster: true)
        plain.controlPath = "/tmp/example-socket"
        #expect(!plain.masterArguments(target: target, controlPath: "/tmp/s", logFile: nil, proxyCommand: nil).contains { $0.hasPrefix("ServerAlive") },
                "no keep-alives unless asked for, like plain ssh")
    }

    @Test func throughTheJumpHostsOwnConnection() {
        var jump = SSHOptions(sshBinary: "/usr/bin/ssh", useControlMaster: true)
        jump.controlPath = "/tmp/jump-socket"
        let command = SharedConnections.proxyCommand(through: jump, jump: SharedConnections.target(forJump: "admin@jump.example.com:2200"))
        #expect(command == "/usr/bin/ssh -o ControlMaster=no -o ControlPath=/tmp/jump-socket -o ProxyCommand=/usr/bin/false "
                + "-o BatchMode=yes -p 2200 -l admin -W '[%h]:%p' -- jump.example.com")
        jump.controlPath = "/tmp/a folder/50% socket"
        let quoted = SharedConnections.proxyCommand(through: jump, jump: .alias("jump"))
        #expect(quoted.contains("'ControlPath=/tmp/a folder/50%% socket'"), "spaces quoted, % doubled for ssh's expansion")
        #expect(SharedConnections.target(forJump: "bastion") == .alias("bastion"))
        let parsed = SharedConnections.parseResolution("hostname example.com\ncontrolpath /tmp/x/abc\nproxyjump a.example.com,b.example.com\n")
        #expect(parsed?.socket == "/tmp/x/abc" && parsed?.jump == nil, "a chain of jump hosts keeps ssh's own hop")
        #expect(SharedConnections.parseResolution("controlpath none\n") == nil)
    }
}

/// A process that ignores SIGTERM still lets its caller go at the timeout.
@Suite struct ProcessRunnerTimeoutTests {
    @Test func aProcessIgnoringTermIsStillEnded() async {
        let start = Date()
        let r = await ProcessRunner.run("/bin/sh", arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"], timeout: 1)
        #expect(r.timedOut)
        #expect(Date().timeIntervalSince(start) < 8)
    }
}
