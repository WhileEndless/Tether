import AppKit
import SwiftUI
import Testing
import TestSupport
import SwiftTerm
import TetherCore
@testable import SessionKit
@testable import TerminalUI

/// Quitting and reopening Tether re-attaches to tmux and rebuilds the screen from it. Full-screen
/// style programs on the normal screen (Claude Code, other TUIs that redraw in place) must come back
/// exactly as tmux shows them — same rows, same cursor — or their next relative redraw lands in the
/// wrong place.
extension TerminalWindowTests {
    /// This suite's private tmux server (never the user's).
    func privateTmux(_ args: [String]) -> String {
        var env = ProcessInfo.processInfo.environment
        env["TMUX_TMPDIR"] = dir.path
        env["TMUX"] = nil
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        return BoundedProcess.run("/usr/bin/env", ["tmux"] + args, environment: env, timeout: 10).output
    }

    func openWindow(_ session: TerminalSession) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: TerminalHost(session: session))
        window.contentView = host
        window.alphaValue = 0
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        return window
    }

    @Test func reopenedAppShowsTheTUIExactlyAsTmuxHasIt() async throws {
        // A screen like Claude Code's: history, full-width rules, a box whose right border sits in
        // the last column, a status line without a newline, the cursor inside the box.
        let ui = dir.appendingPathComponent("ui.sh")
        try """
        echo "start $(stty size)" > "$0.start"
        cols=$(stty size | cut -d' ' -f2)
        i=1; while [ $i -le 40 ]; do echo "history line $i"; i=$((i+1)); done
        rule=$(printf '%*s' "$cols" '' | tr ' ' '-')
        echo "$rule"
        printf '|%-*s|\\n' $((cols-2)) ' > hello'
        echo "$rule"
        printf '  ? for shortcuts'
        printf '\\033[2A\\033[5G'
        trap 'stty size >> "$0.sizes"' WINCH
        while :; do sleep 0.1; done
        """.write(to: ui, atomically: true, encoding: .utf8)

        let cfg = config()
        let descriptor = SessionDescriptor(target: .alias("local"), persistence: .tmux)
        let first = TerminalSession(descriptor: descriptor) { cfg }
        let window1 = openWindow(first)
        try await pump(0.3)
        first.start()
        try await pump(10) { first.phase.isOnline }
        try #require(first.phase.isOnline)
        try await pump(1)
        let firstView = TerminalRegistry.shared.existingView(for: first.id)!
        print("SIZES view=\(firstView.getTerminal().cols)x\(firstView.getTerminal().rows) tmux=" + privateTmux(["list-windows", "-a", "-F", "#{window_width}x#{window_height} clients=#{session_attached} wsize=#{window-size}"])
              + " clients=" + privateTmux(["list-clients", "-F", "#{client_width}x#{client_height} ctl=#{client_control_mode}"]))
        first.send(Array("clear; sh '\(ui.path)'\r".utf8)[...])
        try await pump(2)
        let before = screen(TerminalRegistry.shared.existingView(for: first.id)!)

        // Quit: the client goes, the tmux session stays.
        first.abandon()
        // A reopened app starts with new, empty terminal views.
        TerminalRegistry.shared.remove(first.id)
        window1.orderOut(nil)
        try await pump(0.5)
        let name = descriptor.remoteSessionName
        let truth = privateTmux(["capture-pane", "-p", "-t", "=\(name):"]).split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        let cursor = privateTmux(["display-message", "-p", "-t", "=\(name):", "#{cursor_x} #{cursor_y}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Reopen: a fresh, empty terminal re-attaches.
        let second = TerminalSession(descriptor: descriptor) { cfg }
        let window2 = openWindow(second)
        try await pump(0.3)
        second.restore(previous: .tmux)
        try await pump(10) { second.phase.isOnline }
        try await pump(1)
        let view = TerminalRegistry.shared.existingView(for: second.id)!
        let after = screen(view).map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        let t = view.getTerminal()
        let shownCursor = "\(t.buffer.x) \(t.buffer.y)"

        let rows = min(after.count, truth.count)
        var diffs: [String] = []
        for r in 0..<rows where after[r] != truth[r] { diffs.append("row \(r): tmux=\(truth[r].debugDescription) tether=\(after[r].debugDescription)") }
        let report = "screen differs after reopening:\n" + diffs.prefix(8).joined(separator: "\n")
            + "\nbefore quit:\n" + before.suffix(6).joined(separator: "\n")
        #expect(diffs.isEmpty, "\(report)")
        #expect(shownCursor == cursor, "cursor: tmux \(cursor), tether \(shownCursor)")
        // Re-attaching must not resize the program's terminal on the way (each size change makes
        // programs like Claude Code redraw, and a temporary 80x24 leaves their old frame behind).
        let sizes = (try? String(contentsOf: URL(fileURLWithPath: ui.path + ".sizes"), encoding: .utf8)) ?? ""
        print("REATTACH " + ((try? String(contentsOf: URL(fileURLWithPath: ui.path + ".start"), encoding: .utf8)) ?? "") + " winch: \(sizes.split(separator: "\n"))")
        #expect(sizes.isEmpty, "the program saw size changes while re-attaching: \(sizes.split(separator: "\n"))")

        second.close(killRemote: true)
        window2.orderOut(nil)
        killTmuxServer()
    }

    /// After a restart only the visible tab is drawn. A tab in the background re-attaches with a
    /// terminal that was never laid out (the emulator's default 80x24): that size must not reach the
    /// server, and showing the tab later must not resize anything either.
    @Test func backgroundTabReattachDoesNotResizeTheProgram() async throws {
        let ui = dir.appendingPathComponent("bg.sh")
        try """
        stty size > "$0.start"
        trap 'stty size >> "$0.sizes"' WINCH
        while :; do sleep 0.1; done
        """.write(to: ui, atomically: true, encoding: .utf8)
        let cfg = config()
        let descriptor = SessionDescriptor(target: .alias("local"), persistence: .tmux)
        let first = TerminalSession(descriptor: descriptor) { cfg }
        let window1 = openWindow(first)
        try await pump(0.3)
        first.start()
        try await pump(10) { first.phase.isOnline }
        try await pump(1)
        first.send(Array("sh '\(ui.path)'\r".utf8)[...])
        try await pump(1)
        first.abandon()
        // A reopened app starts with new, empty terminal views.
        TerminalRegistry.shared.remove(first.id)
        window1.orderOut(nil)
        try await pump(0.5)

        // Restored in the background: a view exists (it receives output) but is in no window.
        let second = TerminalSession(descriptor: descriptor) { cfg }
        let view = TerminalRegistry.shared.view(for: second)
        #expect(!view.hasRealSize)
        second.restore(previous: .tmux)
        try await pump(10) { second.phase.isOnline }
        try await pump(1)
        let start = (try? String(contentsOf: URL(fileURLWithPath: ui.path + ".start"), encoding: .utf8)) ?? ""
        var sizes = (try? String(contentsOf: URL(fileURLWithPath: ui.path + ".sizes"), encoding: .utf8)) ?? ""
        #expect(sizes.isEmpty, "background re-attach resized the program (started at \(start)): \(sizes)")

        // Showing the tab in a window of the same size changes nothing for the program.
        let window2 = openWindow(second)
        try await pump(1.5)
        sizes = (try? String(contentsOf: URL(fileURLWithPath: ui.path + ".sizes"), encoding: .utf8)) ?? ""
        #expect(sizes.isEmpty, "showing the tab resized the program (started at \(start)): \(sizes)")

        second.close(killRemote: true)
        window2.orderOut(nil)
        killTmuxServer()
    }

    /// Claude Code's full-screen mode: alternate screen with mouse reporting, bracketed paste and
    /// application cursor keys. A reopened Tether must give the program the same terminal — or wheel
    /// scrolling and clicks never reach it, and a pasted block runs line by line.
    @Test func reopenedAppRestoresTheProgramsTerminalModes() async throws {
        let ui = dir.appendingPathComponent("modes.sh")
        try """
        printf '\\033[?1049h\\033[?1003h\\033[?1006h\\033[?2004h\\033[?1h\\033[?25l\\033[H\\033[2J'
        printf 'full screen program\\033[5;3H> input'
        while :; do sleep 0.1; done
        """.write(to: ui, atomically: true, encoding: .utf8)
        let cfg = config()
        let descriptor = SessionDescriptor(target: .alias("local"), persistence: .tmux)
        let first = TerminalSession(descriptor: descriptor) { cfg }
        let w1 = openWindow(first)
        try await pump(0.3)
        first.start()
        try await pump(10) { first.phase.isOnline }
        try await pump(0.5)
        first.send(Array("sh '\(ui.path)'\r".utf8)[...])
        try await pump(1.5)
        let live = TerminalRegistry.shared.existingView(for: first.id)!.getTerminal()
        #expect(live.bracketedPasteMode && live.mouseMode != .off && live.applicationCursor)
        first.abandon()
        // A reopened app starts with new, empty terminal views.
        TerminalRegistry.shared.remove(first.id)
        w1.orderOut(nil)
        try await pump(0.5)

        let second = TerminalSession(descriptor: descriptor) { cfg }
        let w2 = openWindow(second)
        try await pump(0.3)
        second.restore(previous: .tmux)
        try await pump(10) { second.phase.isOnline }
        try await pump(1)
        let view = TerminalRegistry.shared.existingView(for: second.id)!
        let t = view.getTerminal()
        #expect(t.isCurrentBufferAlternate)
        #expect(t.bracketedPasteMode, "bracketed paste lost on re-attach")
        #expect(t.mouseMode == live.mouseMode, "mouse reporting lost on re-attach: \(t.mouseMode)")
        #expect(t.applicationCursor, "application cursor keys lost on re-attach")
        #expect(screen(view).first?.hasPrefix("full screen program") == true)
        #expect(t.buffer.y == 4 && t.buffer.x == 9, "cursor at \(t.buffer.x),\(t.buffer.y)")

        second.close(killRemote: true)
        w2.orderOut(nil)
        killTmuxServer()
    }

    /// Reopening Tether, the window settles (sidebar and panels come back) while the tab is still
    /// re-attaching. The size it ends with must reach the program — otherwise Claude Code keeps
    /// drawing its boxes for the earlier, wider terminal and they spill past the right edge.
    @Test func sizeChangedWhileReattachingReachesTheProgram() async throws {
        let cfg = config()
        let descriptor = SessionDescriptor(target: .alias("local"), persistence: .tmux)
        let first = TerminalSession(descriptor: descriptor) { cfg }
        let w1 = openWindow(first)
        try await pump(0.3)
        first.start()
        try await pump(10) { first.phase.isOnline }
        try await pump(1)
        first.send(Array("sleep 300\r".utf8)[...])
        try await pump(0.5)
        first.abandon()
        // A reopened app starts with new, empty terminal views.
        TerminalRegistry.shared.remove(first.id)
        w1.orderOut(nil)
        try await pump(0.5)

        let second = TerminalSession(descriptor: descriptor) { cfg }
        let w2 = openWindow(second)
        try await pump(0.3)
        second.restore(previous: .tmux)
        // The window changes size during the re-attach, several times.
        for width in [700.0, 760, 640] {
            try await pump(0.05)
            w2.setContentSize(NSSize(width: width, height: 460))
            w2.contentView?.layoutSubtreeIfNeeded()
        }
        try await pump(10) { second.phase.isOnline }
        try await pump(1.5)
        let t = TerminalRegistry.shared.existingView(for: second.id)!.getTerminal()
        let pane = privateTmux(["display-message", "-p", "-t", "=\(descriptor.remoteSessionName):", "#{pane_width}x#{pane_height}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(pane == "\(t.cols)x\(t.rows)", "tmux pane \(pane), terminal \(t.cols)x\(t.rows)")

        second.close(killRemote: true)
        w2.orderOut(nil)
        killTmuxServer()
    }
}

