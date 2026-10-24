import AppKit
import Testing
import SwiftTerm
import TetherCore
@testable import SessionKit
@testable import TerminalUI

/// A terminal view made before it has a window (a tab restored at launch) measures its cells on the
/// main screen. Shown on a screen with another scale (a Retina and a non-Retina display), it must
/// measure again: SwiftTerm draws box-drawing characters at whole pixels per cell of the current
/// screen, so with a stale cell width Claude Code's tables, rules and input box drift to the right
/// of the text. Measuring again must not reset the running program's terminal modes (a change of
/// font does in SwiftTerm).
@MainActor
@Suite(.serialized) struct DisplayScaleTests {
    /// The cell width SwiftTerm uses, from the frame it asks for (cells plus the legacy scroller).
    func cellWidth(_ view: TetherTerminalView) -> CGFloat {
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        return (view.getOptimalFrameSize().width - scroller) / CGFloat(view.getTerminal().cols)
    }

    func check(on screen: NSScreen) {
        _ = NSApplication.shared
        let session = TerminalSession(descriptor: SessionDescriptor(target: .alias("local"), persistence: .off)) {
            SessionConfiguration(settings: AppSettings())
        }
        let rect = NSRect(x: screen.frame.minX + 10, y: screen.frame.minY + 10, width: 900, height: 500)
        let view = TetherTerminalView(session: session, settings: AppSettings())
        view.frame = NSRect(origin: .zero, size: rect.size)
        // A program's mode (application cursor keys), set before the view is shown.
        view.feed(Array("hello\r\n\u{1b}[?1h".utf8)[...])

        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        defer { window.orderOut(nil); window.close() }
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let container = NSView(frame: NSRect(origin: .zero, size: rect.size))
        window.contentView = container
        container.addSubview(view)
        window.orderFrontRegardless()
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

        let scale = window.backingScaleFactor
        let width = cellWidth(view)
        // SwiftTerm's cell: the advance of "W", snapped to the pixels of the screen it measured on.
        let font = AppSettings().terminalFont
        let advance = font.advancement(forGlyph: font.glyph(withName: "W")).width
        #expect(width == (advance * scale).rounded() / scale, "cell width \(width) at scale \(scale)")
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        #expect(view.getTerminal().cols == Int((view.bounds.width - scroller) / width))
        #expect(view.getTerminal().applicationCursor)
    }

    @Test func measuresAgainForTheWindowsScreen() {
        for screen in NSScreen.screens { check(on: screen) }
    }
}
