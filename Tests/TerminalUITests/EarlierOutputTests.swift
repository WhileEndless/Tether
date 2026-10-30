import AppKit
import Testing
import TetherCore
@testable import SessionKit
@testable import TerminalUI

/// A restored tab shows the end of its earlier recording: drawn only, never acted on.
@MainActor
@Suite struct EarlierOutputTests {
    @Test func earlierOutputIsDrawnButNotActedOn() {
        _ = NSApplication.shared
        let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) { SessionConfiguration(settings: AppSettings()) }
        let view = TetherTerminalView(session: session, settings: AppSettings())
        view.getTerminal().resize(cols: 60, rows: 10)
        // A title, a folder, a terminal query (device attributes, cursor position) and a clipboard copy.
        let earlier = "\u{1b}]0;old title\u{07}\u{1b}]7;file://host/old/folder\u{07}$ ls\r\nfile-a\r\n\u{1b}[c\u{1b}[6n"
            + "\u{1b}]52;c;\(Data("secret".utf8).base64EncodedString())\u{07}\u{07}$ "
        view.showEarlierOutput(Array(earlier.utf8)[...])
        // Modes a program had on then (mouse reports, bracketed paste) are not kept by the restore.
        session.attach(sink: view)
        session.showEarlierOutput(Array("\u{1b}[?1000h\u{1b}[?2004h\u{1b}(0q".utf8))
        #expect(view.getTerminal().mouseMode == .off)
        #expect(!view.getTerminal().bracketedPasteMode)
        view.feed(Array("q".utf8)[...])
        #expect(view.getTerminal().getLine(row: view.getTerminal().getCursorLocation().y)?.translateToString(trimRight: true).hasSuffix("q") == true,
                "line-drawing characters left on")
        #expect(view.getTerminal().getLine(row: 1)?.translateToString(trimRight: true) == "file-a")
        #expect(session.remoteTitle.isEmpty)
        #expect(session.reportedDirectory == nil)
        #expect(session.lastInputAt == .distantPast, "a query in earlier output was answered to the server")
        // Live output afterwards is handled as always.
        view.feed(Array("\u{1b}]0;new title\u{07}".utf8)[...])
        #expect(session.remoteTitle == "new title")
    }
}
