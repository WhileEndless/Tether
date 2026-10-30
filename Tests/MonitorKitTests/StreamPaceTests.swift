import Foundation
import Testing
import SSHTransport
@testable import MonitorKit

/// The host's live numbers come as often as what shows them needs: the status bar alone every few
/// seconds, the host panel at the interval set.
@MainActor
@Suite struct StreamPaceTests {
    @Test func theBarAloneLooksLessOften() {
        let monitor = RemoteMonitor(executor: RemoteExecutor(target: .local, options: SSHOptions()))
        monitor.paused = true          // nothing is started on this Mac
        monitor.retain(interval: 2, detail: false)
        #expect(monitor.wantedInterval == RemoteMonitor.stripInterval)
        monitor.retain(interval: 2, detail: true)
        #expect(monitor.wantedInterval == 2, "the panel open: as set")
        monitor.release(detail: true)
        #expect(monitor.wantedInterval == RemoteMonitor.stripInterval, "back to the bar's pace")
        monitor.release(detail: false)
        monitor.retain(interval: 10, detail: false)
        #expect(monitor.wantedInterval == 10, "never faster than set")
        monitor.release(detail: false)
    }
}
