import Foundation
import Testing
import SSHTransport
@testable import MonitorKit

@MainActor
@Suite struct CommandHubSchedulingTests {
    @Test func backgroundThrottleAlwaysSuspends() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for elapsed in [0.0, 2, 14, 14.99, 15, 60] {
            let delay = CommandHub.pauseInterval(backgrounded: true, lastLook: now.addingTimeInterval(-elapsed), now: now)
            #expect(delay >= 0.05 && delay <= 1)
        }
        #expect(CommandHub.pauseInterval(backgrounded: false, lastLook: now, now: now) == 1)
        #expect(CommandHub.pauseInterval(backgrounded: true, lastLook: nil, now: now) == 1)
    }

    @Test func dueSamplerInBackgroundLeavesTheMainActorUsable() async throws {
        let hub = CommandHub(executor: RemoteExecutor(target: .local, options: SSHOptions()))
        hub.watchEnabled = false
        hub.backgrounded = true
        let sampler = CommandSampler(anchor: { nil }) {
            .init(hostKey: "local", hostName: "This Mac", sessionID: UUID(), sessionTitle: "Test")
        }
        sampler.lookInterval = 0.01
        sampler.update(online: true, foreground: "test")
        hub.register(sampler)
        defer { sampler.close(); hub.stop() }
        // A missing anchor makes the sampler due again immediately. The old loop never
        // suspended once its 15-second background throttle suppressed the next look.
        try await Task.sleep(for: .milliseconds(100))
        #expect(sampler.status != .waiting)
        hub.stop()
        hub.resume()
        hub.backgrounded = false
        try await Task.sleep(for: .milliseconds(30))
    }
}
