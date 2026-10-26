import AppKit
import Testing
import TetherCore
@testable import SessionKit
@testable import TerminalUI

/// A new font size reaches the program at once — in the tab on screen and in tabs that are not
/// (no window) — so full-screen programs never draw for the old size on the new grid.
@MainActor
@Suite struct FontResizeTests {
    func pump(_ seconds: Double, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func fontChangeReportsTheNewSizeAtOnce() async throws {
        _ = NSApplication.shared
        let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) { SessionConfiguration(settings: AppSettings()) }
        var settings = AppSettings()
        settings.fontFromProfile = false
        settings.terminalColors = .alwaysDark
        settings.fontSize = 12
        let view = TetherTerminalView(session: session, settings: settings)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        window.contentView = view
        window.alphaValue = 0
        window.orderFrontRegardless()
        try await pump(10) { view.lastSentSize != nil }
        let first = try #require(view.lastSentSize)

        // On screen: bigger font, fewer cells, reported in the same call.
        settings.fontSize = 20
        view.apply(settings: settings)
        let bigger = try #require(view.lastSentSize)
        #expect(bigger.cols < first.cols && bigger.rows < first.rows)
        #expect(bigger == view.cellSize)

        // Hidden tab (no window): still reported in the same call.
        view.removeFromSuperview()
        #expect(view.window == nil)
        settings.fontSize = 10
        view.apply(settings: settings)
        let smaller = try #require(view.lastSentSize)
        #expect(smaller.cols > bigger.cols && smaller.rows > bigger.rows)
        #expect(smaller == view.cellSize)
    }
}
