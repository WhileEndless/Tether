import AppKit
import SwiftUI
import Testing
import TetherCore
@testable import SessionKit
@testable import TerminalUI

/// Switching tabs moves a terminal into another host view. That must be quick with a long
/// scrollback and must not give the terminal a passing size on the way (a narrow one wraps every
/// line again, twice: slow, and lines can be pushed out).
@MainActor
@Suite(.serialized) struct TabSwitchCostTests {
    func terminal(lines: Int, scrollback: Int) -> (TerminalSession, TetherTerminalView) {
        var settings = AppSettings()
        settings.scrollbackLines = scrollback
        let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) { SessionConfiguration(settings: settings) }
        let view = TerminalRegistry.shared.view(for: session)
        view.apply(settings: settings)
        var chunk = ""
        for i in 0..<lines {
            chunk += "\u{1b}[3\(i % 7 + 1)mline \(i) " + String(repeating: "word ", count: 18) + "\u{1b}[0m\r\n"
            if chunk.utf8.count > 1 << 20 { view.feed(Array(chunk.utf8)[...]); chunk = "" }
        }
        view.feed(Array(chunk.utf8)[...])
        return (session, view)
    }

    @Test func switchingTabsIsQuickAndKeepsTheWidth() async throws {
        _ = NSApplication.shared
        let (a, viewA) = terminal(lines: 40_000, scrollback: 50_000)
        // On the main screen (invisible): the same screen the terminals were measured on, as
        // Tether's windows usually are.
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        let window = NSWindow(contentRect: NSRect(x: origin.x, y: origin.y, width: 1000, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // As the workspace does: the selected tab's host, swapped for another tab's.
        let host = NSHostingView(rootView: AnyView(TerminalHost(session: a)))
        window.contentView = host
        window.layoutIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        // A tab opened in the background meanwhile: it takes its output at the size tabs have.
        // (Set here, with nothing awaited before the tab is made: other suites' windows lay out too.)
        TerminalRegistry.lastHostSize = viewA.frame.size
        let (b, viewB) = terminal(lines: 40_000, scrollback: 50_000)
        defer { TerminalRegistry.shared.remove(a.id); TerminalRegistry.shared.remove(b.id) }
        let cols = viewA.getTerminal().cols
        #expect(viewB.getTerminal().cols == cols, "made at the size tabs have (\(viewB.getTerminal().cols) vs \(cols))")
        #expect(cols > 80)
        var worst: TimeInterval = 0
        for round in 0..<6 {
            let next = round % 2 == 0 ? b : a
            let view = round % 2 == 0 ? viewB : viewA
            view.frameWidthsSeen = []
            let began = ProcessInfo.processInfo.systemUptime
            host.rootView = AnyView(TerminalHost(session: next))
            let t1 = ProcessInfo.processInfo.systemUptime
            window.layoutIfNeeded()
            let t2 = ProcessInfo.processInfo.systemUptime
            window.displayIfNeeded()
            let took = ProcessInfo.processInfo.systemUptime - began
            print("TABSWITCH round \(round): root \(Int((t1 - began) * 1000)) layout \(Int((t2 - t1) * 1000)) display \(Int((ProcessInfo.processInfo.systemUptime - t2) * 1000)) ms widths \(view.frameWidthsSeen)")
            worst = max(worst, took)
            try await Task.sleep(for: .milliseconds(150))
            #expect(view.superview != nil, "the tab's terminal is shown")
            #expect(view.getTerminal().cols == cols, "same width as before (\(view.getTerminal().cols))")
            let passing = view.frameWidthsSeen.filter { abs($0 - host.bounds.width) > 40 }
            #expect(passing.isEmpty, "no passing width on the way: \(view.frameWidthsSeen)")
        }
        print("TABSWITCH worst \(Int(worst * 1000)) ms")
        #expect(worst < 0.1, "a tab switch held the main thread \(Int(worst * 1000)) ms")
    }

    /// A window that opens small and then fills the screen (full screen, zoom): the terminal and the
    /// size the program is told follow at once, without a tab switch.
    @Test func aWindowMadeBigTakesTheTerminalWithIt() async throws {
        _ = NSApplication.shared
        let (a, view) = terminal(lines: 2_000, scrollback: 10_000)
        defer { TerminalRegistry.shared.remove(a.id) }
        let origin = NSScreen.main?.visibleFrame.origin ?? .zero
        let window = NSWindow(contentRect: NSRect(x: origin.x, y: origin.y, width: 520, height: 360),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // As in the workspace: the host fills a part of the window that follows the window's size.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
        window.contentView = content
        let host = NSHostingView(rootView: AnyView(TerminalHost(session: a)))
        host.frame = content.bounds
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let small = view.getTerminal().cols
        window.setContentSize(NSSize(width: 1500, height: 900))
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let big = view.getTerminal().cols
        #expect(big > small * 2, "the terminal follows the window (\(small) → \(big) columns)")
        #expect(abs(view.frame.width - host.bounds.width) < 2, "as wide as its host (\(view.frame.width) vs \(host.bounds.width))")
    }
}
