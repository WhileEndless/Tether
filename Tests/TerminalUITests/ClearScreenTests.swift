import AppKit
import Testing
import SwiftTerm
import TetherCore
@testable import SessionKit
@testable import TerminalUI

/// Ctrl+L and `clear` must not lose history (Terminal.app behaviour).
@MainActor
@Suite struct ClearScreenTests {
    func makeView() -> TetherTerminalView {
        _ = NSApplication.shared
        let descriptor = SessionDescriptor(target: .local, persistence: .off)
        let session = TerminalSession(descriptor: descriptor) { SessionConfiguration(settings: AppSettings()) }
        let view = TetherTerminalView(session: session, settings: AppSettings())
        view.getTerminal().resize(cols: 40, rows: 10)
        return view
    }

    func feed(_ view: TetherTerminalView, _ text: String) {
        view.feed(Array(text.utf8)[...])
    }

    func screenRow(_ view: TetherTerminalView, _ row: Int) -> String {
        (view.getTerminal().getLine(row: row)?.translateToString(trimRight: true) ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// A program's notification (OSC 9/777) or the bell marks the session; seeing it clears it.
    @Test func notificationsAndBellMarkTheSession() {
        _ = NSApplication.shared
        let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) { SessionConfiguration(settings: AppSettings()) }
        let view = TetherTerminalView(session: session, settings: AppSettings())
        view.getTerminal().resize(cols: 40, rows: 10)
        var raised: [TerminalSession.Attention] = []
        session.onAttention = { _, a in raised.append(a) }
        feed(view, "work\u{1b}]9;Claude is done\u{7}more")
        #expect(session.attention == .message(TerminalNotification(body: "Claude is done")))
        feed(view, "\u{7}")
        // The message stays on the tab; the bell after it is still reported.
        #expect(session.attention == .message(TerminalNotification(body: "Claude is done")))
        #expect(raised.count == 2 && raised.last == .bell)
        session.clearAttention()
        feed(view, "\u{1b}]777;notify;Build;finished\u{1b}\\")
        #expect(session.attention == .message(TerminalNotification(title: "Build", body: "finished")))
        // Not shown as text on the screen.
        #expect(screenRow(view, 0) == "workmore")
    }

    /// Saving a session (⌘S) writes lines as the program wrote them: wrapped rows are joined.
    @Test func logicalTextJoinsWrappedRows() {
        let view = makeView()
        let long = String(repeating: "abcdefghij", count: 9)   // 90 columns: three rows at 40
        feed(view, "first\r\n" + long + "\r\nend   \r\n")
        let (trimmed, lines, logical) = view.logicalText()
        #expect(!trimmed)
        #expect(lines == ["first", long, "end"])
        #expect(logical >= 3)
    }

    @Test func ctrlLKeepsScreenInScrollbackAndPromptGoesToTop() {
        let view = makeView()
        feed(view, "line one\r\nline two\r\nline three\r\n$ ")
        // What a shell prints for Ctrl+L: home, erase screen, then the prompt again.
        feed(view, "\u{1b}[H\u{1b}[2J$ ")
        let text = view.scrollbackText().lines
        #expect(text.contains("line one") && text.contains("line three"))
        #expect(screenRow(view, 0) == "$")
        #expect(view.getTerminal().getCursorLocation().y == 0)
    }

    /// Inside tmux and screen, shells clear with "home, erase below" (ESC[H ESC[J): kept the same way.
    @Test func tmuxStyleClearKeepsScreenInScrollback() {
        let view = makeView()
        feed(view, "line one\r\nline two\r\n$ ")
        feed(view, "\u{1b}[H\u{1b}[J$ ")
        let text = view.scrollbackText().lines
        #expect(text.contains("line one") && text.contains("line two"))
        #expect(screenRow(view, 0) == "$")
        // Erasing below the cursor elsewhere on the screen is ordinary output, not a clear.
        let other = makeView()
        feed(other, "a\r\nb\r\nc\u{1b}[2;1H\u{1b}[J")
        #expect(!other.scrollbackText().lines.contains("a") || screenRow(other, 0) == "a")
        #expect(screenRow(other, 0) == "a" && screenRow(other, 1).isEmpty)
    }

    @Test func clearCommandCannotEraseScrollback() {
        let view = makeView()
        for i in 1...30 { feed(view, "output \(i)\r\n") }
        feed(view, "$ clear\r\n\u{1b}[H\u{1b}[2J\u{1b}[3J$ ")
        let text = view.scrollbackText().lines
        #expect(text.contains("output 1") && text.contains("output 30"))
        #expect(screenRow(view, 0) == "$")
    }

    @Test func commandKStillClearsEverything() {
        let view = makeView()
        for i in 1...30 { feed(view, "output \(i)\r\n") }
        view.clearBuffer()
        #expect(!view.scrollbackText().lines.contains("output 1"))
    }

    @Test func emptyScreenAddsNoBlankLines() {
        let view = makeView()
        feed(view, "\u{1b}[H\u{1b}[2J\u{1b}[H\u{1b}[2J$ ")
        #expect(view.scrollbackText().lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } == ["$"])
    }

    /// A clear cut in two by the network is held until it is whole (the scrollback rule must see it).
    @Test func partialEraseIsHeldBack() {
        #expect(TetherTerminalView.partialEraseStart(Array("abc\u{1b}[".utf8)) == 3)
        #expect(TetherTerminalView.partialEraseStart(Array("abc\u{1b}[3".utf8)) == 3)
        #expect(TetherTerminalView.partialEraseStart(Array("abc\u{1b}".utf8)) == 3)
        #expect(TetherTerminalView.partialEraseStart(Array("abc\u{1b}[31m".utf8)) == nil)
        #expect(TetherTerminalView.partialEraseStart(Array("abc\u{1b}[1".utf8)) == nil)
    }

    // MARK: Programs redrawing in place

    func history(_ view: TetherTerminalView) -> [String] { view.scrollbackText().lines.map { $0.trimmingCharacters(in: .whitespaces) } }

    /// A build's progress (BuildKit, npm) moves up to its first line and draws its frame again; once
    /// the frame fills the screen that is the top left. Only what it shows last stays.
    @Test func aProgressRedrawnFromTheTopLeavesOnlyItsLastFrame() {
        let view = makeView()
        feed(view, "$ docker compose build\r\n")
        view.ruleContext.typed()
        for f in 0..<8 {
            // Up to its first line (the top left, the frame filling the screen), erase below, draw.
            var frame = f == 0 ? "" : "\u{1b}[9A\r\u{1b}[J"
            for k in 0..<9 { frame += "frame \(f) step \(k)\u{1b}[K" + (k < 8 ? "\r\n" : "") }
            feed(view, frame)
        }
        let text = history(view)
        #expect(!text.contains { $0.hasPrefix("frame 3 ") }, "no frame on the way: \(text.suffix(12))")
        #expect(!text.contains { $0.hasPrefix("frame 0 ") }, "not even the first, right after the command was typed")
        #expect(text.contains("frame 7 step 8"))
    }

    /// A program clearing the screen again and again on its own (`docker stats`, a dashboard)
    /// leaves its last screen; the line it was started from stays above.
    @Test func aProgramClearingOnItsOwnLeavesItsLastScreen() {
        let view = makeView()
        for i in 1...4 { feed(view, "earlier \(i)\r\n") }
        feed(view, "$ docker stats")
        view.ruleContext.typed()
        feed(view, "\r\n")
        for f in 0..<6 { feed(view, "\u{1b}[2J\u{1b}[HCONTAINER CPU\r\nweb \(f)%\r\n") }
        let text = history(view)
        #expect(text.contains("$ docker stats") && text.contains("earlier 1"), "what came before is kept")
        #expect(!text.contains("web 2%"), "no screen on the way")
        #expect(text.contains("web 5%"))
        #expect(text.filter { $0 == "CONTAINER CPU" }.count == 1)
    }

    /// Typed clears keep the screen: `clear` and Ctrl+L, also with an erase cut from its home
    /// sequence or with the cursor hidden between them.
    @Test func typedClearsKeepTheScreen() {
        let view = makeView()
        feed(view, "one\r\n$ ")
        view.ruleContext.typed()
        feed(view, "\u{1b}[H")
        feed(view, "\u{1b}[J$ ")
        feed(view, "two\r\n$ ")
        view.ruleContext.typed()
        feed(view, "\u{1b}[H\u{1b}[?25l\u{1b}[0m\u{1b}[J$ ")
        let text = history(view)
        #expect(text.contains("one") && text.contains { $0.hasSuffix("two") }, "\(text)")
    }

    /// Commands run earlier without a clear do not add up: a dashboard started after twenty of
    /// them still leaves only its last screen.
    @Test func commandsRunEarlierDoNotAddUp() {
        let view = makeView()
        for i in 0..<20 {
            feed(view, "$ echo \(i)\r\n\(i)\r\n")
            view.ruleContext.typed()
        }
        feed(view, "$ watch df\r\n")
        view.ruleContext.typed()
        for f in 0..<6 { feed(view, "\u{1b}[2J\u{1b}[HEvery 2s: df\r\nused \(f)%\r\n") }
        let text = history(view)
        #expect(!text.contains("used 2%"), "no screen on the way: \(text.suffix(14))")
        #expect(text.contains("used 5%") && text.contains("$ watch df"))
    }

    /// A paste with two clears (`clear⏎ls⏎clear⏎`): each Return lets one clear keep the screen, so
    /// `ls`'s output stays.
    @Test func aPasteKeepsTheScreenOfEachClearInIt() {
        let view = makeView()
        view.sendsAreTyping = true
        defer { view.sendsAreTyping = nil }
        feed(view, "before\r\n$ ")
        view.send(source: view, data: Array("clear\rls\rclear\r".utf8)[...])
        feed(view, "\u{1b}[H\u{1b}[2J$ ls\r\nfile-a\r\n$ \u{1b}[H\u{1b}[2J$ ")
        let text = history(view)
        #expect(text.contains("before") && text.contains("file-a"), "\(text)")
    }

    /// The width made narrower than the scrollback can hold at: the lines SwiftTerm drops are
    /// counted, so scrolling up and Find go on into the recording.
    @Test func linesANarrowerWidthDropsAreCounted() {
        _ = NSApplication.shared
        var settings = AppSettings()
        settings.scrollbackLines = 200
        let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) { SessionConfiguration(settings: settings) }
        let view = TetherTerminalView(session: session, settings: settings)
        view.setFrameSize(NSSize(width: 900, height: 300))
        let wide = view.getTerminal().cols
        let line = String(repeating: "y", count: wide - 4)
        for i in 0..<150 { feed(view, "\(i) \(line)\r\n") }
        #expect(view.linesDropped == 0)
        view.setFrameSize(NSSize(width: 300, height: 300))
        #expect(view.getTerminal().cols < wide / 2)
        #expect(view.linesDropped > 0, "dropped by the narrower width")
    }

    /// The window resized while a full-screen program (vim) is up: the command jumped to stays on
    /// its line once the program ends, though the lines under it wrapped again out of sight.
    @Test func placesSurviveAResizeUnderAFullScreenProgram() {
        let view = makeView()
        view.setFrameSize(NSSize(width: 900, height: 300))
        let wide = view.getTerminal().cols
        for i in 0..<30 { feed(view, "long \(i) " + String(repeating: "z", count: wide - 12) + "\r\n") }
        feed(view, "$ the-command\r\n")
        for i in 0..<5 { feed(view, "after \(i)\r\n") }
        let t = view.getTerminal()
        func row(of text: String) -> Int? {
            (0..<2000).first { t.getScrollInvariantLine(row: $0 + t.buffer.totalLinesTrimmed)?.translateToString(trimRight: true).hasPrefix(text) == true }
        }
        view.jumpCursor = row(of: "$ the-command")
        #expect(view.jumpCursor != nil)
        feed(view, "\u{1b}[?1049h\u{1b}[Hvim screen")
        view.setFrameSize(NSSize(width: 400, height: 300))
        feed(view, "\u{1b}[?1049l")
        #expect(view.getTerminal().cols < wide)
        #expect(view.jumpCursor == row(of: "$ the-command"), "\(String(describing: view.jumpCursor)) vs \(String(describing: row(of: "$ the-command")))")
    }

    @Test func everyFrameIsKeptWhenAsked() {
        let view = makeView()
        view.ruleContext.keepRedraws = true
        var s = AppSettings()
        s.keepRedrawnFrames = true
        view.apply(settings: s)
        feed(view, "$ watch\r\n")
        for f in 0..<4 { feed(view, "\u{1b}[2J\u{1b}[Hscreen \(f)\r\n") }
        let text = history(view)
        #expect((0..<4).allSatisfy { f in text.contains("screen \(f)") })
    }
}
