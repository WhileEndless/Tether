import Foundation
import Testing
import SwiftTerm
@testable import SessionKit

/// In a tmux tab the terminal's answers to a program's questions are not typed into the pane:
/// tmux answers (or keeps) them itself, and ours, a round trip later, were echoed as text when
/// the program had left raw mode (Claude Code starting in a tmux tab).
struct TmuxOwnAnswersTests {
    final class Sink: TerminalDelegate {
        var sent: [UInt8] = []
        func send(source: Terminal, data: ArraySlice<UInt8>) { sent += data }
    }

    /// What SwiftTerm itself answers to the questions a coding agent asks when it starts.
    static func answers(to queries: String) -> [UInt8] {
        let sink = Sink()
        var options = TerminalOptions.default
        options.cols = 80
        options.rows = 24
        let t = Terminal(delegate: sink, options: options)
        t.feed(text: queries)
        return sink.sent
    }

    @Test func theTerminalsAnswersToAnAgentsProbeAreLeftOut() {
        // Version, keyboard flags, device attributes (twice), a mode, the cursor, status, size, settings.
        let queries = "\u{1b}[>q\u{1b}[?u\u{1b}[c\u{1b}[?2026$p\u{1b}[c\u{1b}[6n\u{1b}[5n\u{1b}[18t\u{1b}[14t\u{1b}[>c\u{1b}P$qm\u{1b}\\\u{1b}[12$p"
        let sent = Self.answers(to: queries)
        #expect(!sent.isEmpty, "SwiftTerm answered")
        let left = TmuxOwnAnswers.strip(sent[...])
        #expect(left.isEmpty, "nothing typed into the pane: \(String(decoding: left, as: UTF8.self).debugDescription)")
    }

    @Test func theAnswersSeenEchoedAreLeftOut() {
        // As SwiftTerm sent them in a tmux tab (the focus report stays: tmux does not send it).
        let sent = Array("\u{1b}[I\u{1b}P>|SwiftTerm 1.20.0\u{1b}\\\u{1b}[?5u\u{1b}[?65;4;1;2;6;21;22;17;28c\u{1b}[?2026;2$y\u{1b}[?65;4;1;2;6;21;22;17;28c".utf8)
        #expect(Array(TmuxOwnAnswers.strip(sent[...])) == Array("\u{1b}[I".utf8))
    }

    @Test func mouseFocusColoursAndTextPass() {
        for keep in ["\u{1b}[<0;10;5M", "\u{1b}[<0;10;5m", "\u{1b}[M !!", "\u{1b}[O", "\u{1b}[I",
                     "\u{1b}]11;rgb:0000/0000/0000\u{1b}\\", "\u{1b}[?3;5;1R", "hello\r", "\u{1b}[", "\u{1b}"] {
            let bytes = Array(keep.utf8)
            #expect(Array(TmuxOwnAnswers.strip(bytes[...])) == bytes, "\(keep.debugDescription) passes")
        }
    }

    @Test func answersAmongOtherBytesAreCutOutAlone() {
        let bytes = Array("a\u{1b}[12;40Rb\u{1b}[<0;1;1Mc\u{1b}[0nd".utf8)
        #expect(Array(TmuxOwnAnswers.strip(bytes[...])) == Array("ab\u{1b}[<0;1;1Mcd".utf8))
    }
}
