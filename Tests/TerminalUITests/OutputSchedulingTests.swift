import AppKit
import Foundation
import Testing
import TetherCore
@testable import SessionKit
@testable import TerminalUI

@MainActor
@Suite(.serialized) struct OutputSchedulingTests {
    // Run alone with TETHER_OUTPUT_PERFORMANCE=1: unrelated history/reflow suites deliberately
    // perform large synchronous setup and would invalidate an input-latency measurement.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TETHER_OUTPUT_PERFORMANCE"] == "1"))
    func twentyStreamingTerminalsLeaveTimeForInput() async throws {
        _ = NSApplication.shared
        var views: [TetherTerminalView] = []
        var sessions: [TerminalSession] = []
        let data = Array(String(repeating: "\u{1b}[32mstreaming output\u{1b}[0m\r\n", count: 2000).utf8)
        for _ in 0..<20 {
            var settings = AppSettings()
            settings.scrollbackLines = 1000
            let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) {
                SessionConfiguration(settings: settings)
            }
            let view = TetherTerminalView(session: session, settings: settings)
            view.batchesWhileHidden = true
            view.feed(data[...])
            sessions.append(session)
            views.append(view)
        }
        defer { for view in views { view.releaseCallbacks() } }
        var worst: TimeInterval = 0
        for _ in 0..<30 {
            let started = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .milliseconds(10))
            worst = max(worst, ProcessInfo.processInfo.systemUptime - started - 0.01)
        }
        print("OUTPUT: 20 terminals, longest main-actor scheduling delay \(Int(worst * 1000)) ms")
        #expect(worst < 0.1)
        #expect(sessions.count == 20)
    }

    @Test func deferredResizeDoesNotWaitForTheProducerToGoIdle() async throws {
        _ = NSApplication.shared
        let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) {
            SessionConfiguration(settings: AppSettings())
        }
        let view = TetherTerminalView(session: session, settings: AppSettings())
        defer { view.releaseCallbacks() }
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 500)
        view.batchesWhileHidden = true
        view.feed(Array(String(repeating: "line\r\n", count: 11_000).utf8)[...])
        view.setFrameSize(NSSize(width: 1000, height: 500))
        view.setFrameSize(NSSize(width: 1100, height: 500))
        let deadline = Date().addingTimeInterval(5)
        while view.frame.width != 1100, Date() < deadline {
            view.feed(Array("more output\r\n".utf8)[...])
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(view.frame.width == 1100)
    }

    @Test func historyRemeasureKeepsBrowsingAndSelection() async throws {
        let fixture = try HistoryBrowsingTests.Fixture(lines: (0..<3000).map { "history line \($0)" })
        fixture.view.setFrameSize(NSSize(width: 900, height: 500))
        #expect(await fixture.slide(up: true))
        let history = try #require(fixture.view.history)
        history.setFrameSize(NSSize(width: 900, height: 500))
        try await Task.sleep(for: .milliseconds(100))
        let t = history.getTerminal()
        let row = t.buffer.yDisp
        history.selection.setSelection(start: .init(col: 0, row: row), end: .init(col: 7, row: row))
        let before = t.getScrollInvariantLine(row: row + t.buffer.totalLinesTrimmed)?.translateToString(trimRight: true)
        history.remeasure(font: NSFont.monospacedSystemFont(ofSize: 16, weight: .regular))
        #expect(fixture.view.isBrowsingHistory)
        #expect(history.selection.active)
        let after = t.getScrollInvariantLine(row: history.selection.start.row + t.buffer.totalLinesTrimmed)?.translateToString(trimRight: true)
        #expect(before == after)
    }

    @Test func historyResizeUsesTheLatestWindowBoundsWithoutMovingTheReadingPlace() async throws {
        let fixture = try HistoryBrowsingTests.Fixture(lines: (0..<3000).map { "history line \($0)" })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = fixture.view
        window.orderFrontRegardless()
        defer { fixture.view.releaseCallbacks(); window.orderOut(nil); window.close() }
        #expect(await fixture.slide(up: true))
        let history = try #require(fixture.view.history)
        let before = history.getTerminal().getLine(row: 0)?.translateToString(trimRight: true)
        for width in [1100.0, 700, 1000] {
            window.setContentSize(NSSize(width: width, height: 500))
            window.layoutIfNeeded()
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(fixture.view.isBrowsingHistory)
        #expect(abs(history.frame.width - fixture.view.bounds.width) < 2)
        #expect(history.getTerminal().getLine(row: 0)?.translateToString(trimRight: true) == before)
    }
}
