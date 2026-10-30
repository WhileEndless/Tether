import AppKit
import Testing
import SwiftTerm
import TetherCore
@testable import SessionKit
@testable import TerminalUI

/// Programs that hide and show the cursor on every frame (coding agents) must not make the window
/// lay out again each time: the cursor view stays in the terminal, only its layer is hidden.
@MainActor
struct SteadyCaretTests {
    @Test func hidingTheCursorKeepsItsViewInPlace() throws {
        _ = NSApplication.shared
        let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) { SessionConfiguration(settings: AppSettings()) }
        let view = TetherTerminalView(session: session, settings: AppSettings())
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        window.contentView = view
        view.feed(Array("hello\r\n$ ".utf8)[...])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let caret = try #require(SteadyCaret.caretView(of: view))
        #expect(!caret.translatesAutoresizingMaskIntoConstraints, "moving it changes no layout")
        view.feed(Array("\u{1b}[?25l".utf8)[...])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(caret.superview === view, "not taken out of the view")
        #expect(caret.layer?.isHidden == true)
        view.feed(Array("\u{1b}[?25h".utf8)[...])
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(caret.superview === view)
        #expect(caret.layer?.isHidden == false, "shown again")
    }
}
