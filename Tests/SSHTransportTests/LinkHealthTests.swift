import Foundation
import Testing
import TetherCore
import TestSupport
@testable import SSHTransport

/// Whether a shared connection still reaches its server, decided in one place
/// (`SharedConnections.verifyLink`), with a fake ssh whose master can lose its link while it keeps
/// running (`FakeSharedSSH.cutLink`) — the state after a network change, when every tab used to wait
/// on a connection that only looked alive. Everything lives in a private folder.
@Suite(.serialized) final class LinkHealthTests {
    let dir: URL
    let ssh: URL

    init() throws {
        // Short: Unix socket paths are limited to 104 bytes.
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tlh-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ssh = try FakeSharedSSH.install(in: dir)
    }

    deinit {
        FakeSharedSSH.stopMasters(in: dir)
        try? FileManager.default.removeItem(at: dir)
    }

    func options() -> SSHOptions { SSHOptions(sshBinary: ssh.path, useControlMaster: true) }
    func host() -> ConnectionTarget { .alias("host-\(UUID().uuidString.prefix(6))") }
    func signIn() -> SharedConnections.SignIn { .init(purpose: "connect") }

    func isolate() async {
        await SharedConnectionsTestLock.shared.acquire()
        await SharedConnections.shared.useSocketDirectory(dir)
        await SharedConnections.shared.useStaleLinkDeadAfter(1.5)
    }

    func finish() async {
        await SharedConnections.shared.reset()
        await SharedConnectionsTestLock.shared.release()
    }

    /// Runs a test with the shared connections to itself, giving them back also when it fails
    /// (a test still holding them would hold up every suite after it).
    func isolated(_ body: () async throws -> Void) async throws {
        await isolate()
        do { try await body() } catch { await finish(); throw error }
        await finish()
    }

    func connect(_ target: ConnectionTarget) async -> (socket: String?, reused: Bool) {
        if case .ready(let o, let reused) = await SharedConnections.shared.prepare(target, options: options(), signIn: signIn()) {
            return (o.controlPath, reused)
        }
        return (nil, false)
    }

    func starts() -> Int { FakeSharedSSH.logins(in: dir).filter { $0 == "start" }.count }
    func probes() -> Int {
        ((try? String(contentsOf: dir.appendingPathComponent("ssh-calls.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").filter { $0.contains("-W 127.0.0.1:9") }.count
    }

    /// The network changed and the connection's link went with it: the next tab does not wait on
    /// it — it is checked, closed, and a fresh sign-in follows, quickly.
    @Test func aLinkThatDiedWithTheNetworkIsNotTrusted() async throws {
        try await isolated {
        let target = host()
        let first = await connect(target)
        let socket = try #require(first.socket)
        FakeSharedSSH.cutLink(socket: socket)
        await SharedConnections.shared.noteNetworkChanged()
        let began = Date()
        let again = await connect(target)
        #expect(again.socket == socket)
        #expect(!again.reused, "signed in afresh")
        #expect(starts() == 2)
        #expect(Date().timeIntervalSince(began) < 10, "took \(Date().timeIntervalSince(began)) s")
        }
    }

    /// A connection that survived the network change is checked once and used, without a sign-in.
    @Test func aLiveLinkIsKeptAfterANetworkChange() async throws {
        try await isolated {
        let target = host()
        _ = await connect(target)
        await SharedConnections.shared.noteNetworkChanged()
        let again = await connect(target)
        #expect(again.reused)
        #expect(starts() == 1)
        #expect(probes() == 1, "checked once")
        // Checked after the change: trusted now, not checked for every tab.
        _ = await connect(target)
        #expect(probes() == 1)
        }
    }

    /// No network change: a connection is used as it is (no check on every tab).
    @Test func withoutANetworkChangeNothingIsChecked() async throws {
        try await isolated {
        let target = host()
        _ = await connect(target)
        _ = await connect(target)
        #expect(probes() == 0)
        #expect(starts() == 1)
        }
    }

    /// Many ask at once (every tab of a host after waking): one check, one verdict for all.
    @Test func concurrentChecksShareOneVerdict() async throws {
        try await isolated {
        let socket = try #require(await connect(host()).socket)
        FakeSharedSSH.cutLink(socket: socket)
        let verdicts = await withTaskGroup(of: Bool?.self) { group in
            for _ in 0..<6 {
                group.addTask { await SharedConnections.shared.verifyLink(socket, ssh: self.ssh.path, deadAfter: 1.5) }
            }
            return await group.reduce(into: [Bool?]()) { $0.append($1) }
        }
        #expect(verdicts.allSatisfy { $0 == false })
        #expect(probes() == 1, "one check, not six")
        #expect(!SharedConnections.isSocket(socket), "closed")
        }
    }

    /// The one who asked stops waiting (the next network event cancels its check): the check
    /// still decides — the reason checks used to end without a verdict, and tabs hung.
    @Test func aCheckDecidesEvenWhenItsCallerStopsWaiting() async throws {
        try await isolated {
        let socket = try #require(await connect(host()).socket)
        FakeSharedSSH.cutLink(socket: socket)
        let caller = Task { await SharedConnections.shared.verifyLink(socket, ssh: self.ssh.path, deadAfter: 1.5) }
        try await Task.sleep(for: .milliseconds(200))
        caller.cancel()
        for _ in 0..<50 where SharedConnections.isSocket(socket) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!SharedConnections.isSocket(socket), "closed although nobody waited for the verdict")
        }
    }

    /// Busy rather than dead: something received data on it meanwhile (a large transfer holds the
    /// check up). It is kept.
    @Test func aBusyConnectionIsNotClosed() async throws {
        try await isolated {
        let socket = try #require(await connect(host()).socket)
        FakeSharedSSH.cutLink(socket: socket)
        await SharedConnections.shared.configureLinkHealth(signsOfLife: { _, _ in true }, canJudge: { true })
        let verdict = await SharedConnections.shared.verifyLink(socket, ssh: ssh.path, deadAfter: 1.5)
        #expect(verdict == true)
        #expect(SharedConnections.isSocket(socket))
        }
    }

    /// Offline or asleep, nothing is decided: the connection stays for when the network is back.
    @Test func nothingIsDecidedWithoutTheNetwork() async throws {
        try await isolated {
        let socket = try #require(await connect(host()).socket)
        FakeSharedSSH.cutLink(socket: socket)
        await SharedConnections.shared.configureLinkHealth(signsOfLife: { _, _ in false }, canJudge: { false })
        let verdict = await SharedConnections.shared.verifyLink(socket, ssh: ssh.path, deadAfter: 1.5)
        #expect(verdict == nil)
        #expect(SharedConnections.isSocket(socket))
        }
    }

    /// A host behind a jump host stops answering: the jump host's own connection is checked too —
    /// a dead one is closed, or the next sign-in would hang on it.
    @Test func aDeadTargetGetsItsJumpHostChecked() async throws {
        try await isolated {
        let jump = "jump-\(UUID().uuidString.prefix(6))", target = "target-\(UUID().uuidString.prefix(6))"
        try "\(target) \(jump)\n".write(to: dir.appendingPathComponent("jumps"), atomically: true, encoding: .utf8)
        let socket = try #require(await connect(.alias(target)).socket)
        let jumpSocket = try #require(await SharedConnections.shared.socket(for: .alias(jump), options: options()))
        #expect(SharedConnections.isSocket(jumpSocket), "signed in through the jump host's own connection")
        FakeSharedSSH.cutLink(socket: socket)
        FakeSharedSSH.cutLink(socket: jumpSocket)
        #expect(await SharedConnections.shared.verifyLink(socket, ssh: ssh.path, deadAfter: 1.5) == false)
        for _ in 0..<60 where SharedConnections.isSocket(jumpSocket) { try await Task.sleep(for: .milliseconds(100)) }
        #expect(!SharedConnections.isSocket(jumpSocket), "the jump host's dead connection was closed too")
        }
    }

    /// The target is gone but the jump host is fine: its connection stays (other hosts use it).
    @Test func aLiveJumpHostStays() async throws {
        try await isolated {
        let jump = "jump-\(UUID().uuidString.prefix(6))", target = "target-\(UUID().uuidString.prefix(6))"
        try "\(target) \(jump)\n".write(to: dir.appendingPathComponent("jumps"), atomically: true, encoding: .utf8)
        let socket = try #require(await connect(.alias(target)).socket)
        let jumpSocket = try #require(await SharedConnections.shared.socket(for: .alias(jump), options: options()))
        FakeSharedSSH.cutLink(socket: socket)
        #expect(await SharedConnections.shared.verifyLink(socket, ssh: ssh.path, deadAfter: 1.5) == false)
        try await Task.sleep(for: .seconds(1))
        #expect(SharedConnections.isSocket(jumpSocket))
        }
    }

    /// The jump host is fine but cannot reach the server: the sign-in fails at once with the jump
    /// host's words (not a hang, not a "refused session"), and the jump host's connection stays.
    @Test func aJumpHostThatCannotReachTheServerSaysSo() async throws {
        try await isolated {
        let jump = "jump-\(UUID().uuidString.prefix(6))", target = "target-\(UUID().uuidString.prefix(6))"
        try "\(target) \(jump)\n".write(to: dir.appendingPathComponent("jumps"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("noroute-" + target.replacingOccurrences(of: "-", with: "_")).path, contents: nil)
        let began = Date()
        let outcome = await SharedConnections.shared.prepare(.alias(target), options: options(), signIn: signIn())
        #expect(Date().timeIntervalSince(began) < 10)
        guard case .failed(let message, let log) = outcome else { Issue.record("not failed: \(outcome)"); return }
        let said = ([message] + log).joined(separator: "\n")
        #expect(SSHFailure.isJumpCannotReachTarget(said), "said: \(said)")
        #expect(SSHFailure.isUnreachable(said))
        let jumpSocket = try #require(await SharedConnections.shared.socket(for: .alias(jump), options: options()))
        #expect(SharedConnections.isSocket(jumpSocket), "the jump host's connection stays for the hosts it can reach")
        }
    }
}
