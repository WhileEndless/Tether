import AppKit
import SwiftUI
import Testing
import SwiftTerm
import TetherCore
@testable import SessionKit
@testable import TerminalUI

/// Measures (prints) what a terminal costs on the main thread while a program redraws it
/// continuously, as a coding agent's spinner does. Not a pass/fail test: run it by name.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TETHER_RENDER_PROBE"] != nil))
struct RenderCostProbe {
    final class CountingHost: NSView {
        var layouts = 0
        override func layout() { layouts += 1; super.layout() }
    }

    func run(metal: Bool, shown: Bool = true) async throws -> (cpu: Double, layouts: Int) {
        _ = NSApplication.shared
        let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) { SessionConfiguration(settings: AppSettings()) }
        let view = TerminalRegistry.shared.view(for: session)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let host = CountingHost(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        window.contentView = host
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        host.addSubview(view)
        if shown { window.orderFrontRegardless() } else { view.removeFromSuperview() }
        if metal { try? view.setUseMetal(true) }
        for i in 0..<60 { view.feed(Array(("line \(i) " + String(repeating: "x", count: 80) + "\r\n").utf8)[...]) }
        let start = ProcessInfo.processInfo.systemUptime
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let cpu0 = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        var frame = 0
        while ProcessInfo.processInfo.systemUptime - start < 5 {
            // A spinner and a status block redrawn in place, 30 times a second (an agent at work:
            // its last dozen lines erased and written again every frame).
            let spin = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴"][frame % 6]
            // As Ink does: up to the block's first line, then each line erased and written again
            // (no line break after the last, so nothing scrolls).
            var redraw = frame == 0 ? "" : "\u{1b}[11A"
            for k in 0..<12 {
                redraw += "\r\u{1b}[2K" + (k == 0 ? "\(spin) Working… \(frame) tokens · esc to interrupt" : "│ status line \(k) " + String(repeating: "─", count: 60))
                if k < 11 { redraw += "\r\n" }
            }
            view.feed(Array(redraw.utf8)[...])
            frame += 1
            // Back to the main queue between frames: the terminal's own timers (drawing) run there.
            try await Task.sleep(for: .milliseconds(33))
        }
        getrusage(RUSAGE_SELF, &usage)
        let cpu1 = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        window.orderOut(nil)
        TerminalRegistry.shared.remove(session.id)
        return ((cpu1 - cpu0) / 5 * 100, host.layouts)
    }

    @Test func measure() async throws {
        defer { TetherTerminalView.drawHoldOverride = nil }
        for (name, hold) in [("every update", 0.0), ("in front, nobody typing", TetherTerminalView.foregroundHold),
                             ("held 0.066 s", 0.066), ("held 0.1 s", 0.1),
                             ("in the background", TetherTerminalView.backgroundHold)] {
            TetherTerminalView.drawHoldOverride = hold
            let r = try await run(metal: false)
            print("RENDER CoreGraphics, \(name): \(String(format: "%.1f", r.cpu))% CPU")
        }
        TetherTerminalView.drawHoldOverride = 0
        let hidden = try await run(metal: false, shown: false)
        print("RENDER not in a window (output only): \(String(format: "%.1f", hidden.cpu))% CPU")
        let cg = try await run(metal: false)
        print("RENDER CoreGraphics: \(String(format: "%.1f", cg.cpu))% CPU, \(cg.layouts) layouts in 5 s")
        let mt = try await run(metal: true)
        print("RENDER Metal: \(String(format: "%.1f", mt.cpu))% CPU, \(mt.layouts) layouts in 5 s")
    }
}
