import Testing
@testable import TmuxControl

@Suite struct TmuxControlParserTests {
    func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    @Test func detectsControlModeAndOutput() {
        var p = TmuxControlParser()
        let events = p.feed(bytes("noise\u{1b}P1000p%begin 1 2 0\r\n%end 1 2 0\r\n%output %3 hi\\015\\012\r\n"))
        #expect(events == [
            .passthrough(bytes("noise")),
            .enteredControlMode,
            .commandReply(number: 2, success: true, lines: []),
            .output(pane: "%3", data: [0x68, 0x69, 0x0d, 0x0a]),
        ])
    }

    @Test func handlesSplitInput() {
        var p = TmuxControlParser()
        var events = p.feed(bytes("\u{1b}P10"))
        #expect(events.isEmpty)
        events = p.feed(bytes("00p%outp"))
        #expect(events == [.enteredControlMode])
        events = p.feed(bytes("ut %1 a\\134b\n"))
        #expect(events == [.output(pane: "%1", data: bytes("a\\b"))])
    }

    @Test func commandReplyCollectsLines() {
        var p = TmuxControlParser()
        _ = p.feed(bytes("\u{1b}P1000p"))
        let events = p.feed(bytes("%begin 9 7 1\n%1 0 3 4 80 24\n%end 9 7 1\n"))
        #expect(events == [.commandReply(number: 7, success: true, lines: [bytes("%1 0 3 4 80 24")])])
    }

    @Test func errorAndExit() {
        var p = TmuxControlParser()
        _ = p.feed(bytes("\u{1b}P1000p"))
        let events = p.feed(bytes("%begin 1 4 1\nbad\n%error 1 4 1\n%exit detached\n\u{1b}\\"))
        #expect(events == [.commandReply(number: 4, success: false, lines: [bytes("bad")]),
                           .exit(reason: "detached"), .leftControlMode])
    }

    @Test func sendKeysUsesHexAndChunks() {
        let cmd = TmuxCommands.sendKeys(pane: "%1", bytes: bytes("ls\r"))
        #expect(cmd == "send-keys -t %1 -H 6c 73 0d\n")
        let big = TmuxCommands.sendKeys(pane: "%1", bytes: [UInt8](repeating: 0x41, count: 1030), chunkSize: 512)
        #expect(big.split(separator: "\n").count == 3)
    }

    @Test func paneInfoParses() {
        let info = TmuxPaneInfo(line: "%5 1 10 3 120 40")
        #expect(info?.paneID == "%5")
        #expect(info?.alternateScreen == true)
        #expect(info?.width == 120)
        #expect(info?.modes == TmuxPaneModes(""))
    }

    /// What Claude Code's full-screen mode leaves on: alternate screen, mouse (1003 + SGR), bracketed
    /// paste, application cursor keys, a hidden cursor and a scroll region.
    @Test func paneModesComeBackAsEscapeSequences() {
        let line = "%3 1 2 20 120 40 0 cursor=0;keypad=0;keys=1;insert=0;origin=0;wrap=1;top=1;bottom=38;m1000=0;m1002=0;"
            + "m1003=1;m1006=1;m1005=0;paste=1;shape=bar;blink=1"
        let info = TmuxPaneInfo(line: line)!
        let seq = info.modes.sequence(cursorX: info.cursorX, cursorY: info.cursorY, height: info.height)
        #expect(seq == "\u{1b}[2;39r\u{1b}[?1h\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?2004h\u{1b}[5 q\u{1b}[21;3H\u{1b}[?25l")
        // A plain shell: nothing but the cursor position.
        let shell = TmuxPaneInfo(line: "%1 0 4 7 80 24 100 cursor=1;keypad=0;keys=0;insert=0;origin=0;wrap=1;top=0;bottom=23;"
            + "m1000=0;m1002=0;m1003=0;m1006=0;m1005=0;paste=0;shape=default;blink=0")!
        #expect(shell.modes.sequence(cursorX: 4, cursorY: 7, height: 24) == "\u{1b}[8;5H")
        // An older tmux leaves fields empty: they are skipped, never misread.
        let old = TmuxPaneInfo(line: "%1 0 0 0 80 24 0 cursor=;paste=;top=;bottom=;m1003=1")!
        #expect(old.modes.sequence(cursorX: 0, cursorY: 0, height: 24) == "\u{1b}[?1003h\u{1b}[1;1H")
    }
}
