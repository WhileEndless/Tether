import AppKit
import Testing
import TetherCore
import SwiftTerm
@testable import RecordingKit
@testable import SessionKit
@testable import TerminalUI

/// Measures (prints) what scrolling back and finding cost in a long coding-agent session: output
/// interleaved with a status block the agent redraws in place many times a second. Reports how long
/// each step held the main thread at most. Not a pass/fail test: run it by name.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TETHER_HISTORY_PROBE"] != nil))
struct HistoryCostProbe {
    /// The longest the main thread went without running a 5 ms timer, while `work` ran.
    @MainActor final class Stall {
        var last = ProcessInfo.processInfo.systemUptime
        var worst: TimeInterval = 0
        var timer: Timer?
        func start() {
            last = ProcessInfo.processInfo.systemUptime
            worst = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.005, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    self.worst = max(self.worst, now - self.last)
                    self.last = now
                }
            }
        }
        func stop() -> TimeInterval {
            timer?.invalidate()
            return max(worst, ProcessInfo.processInfo.systemUptime - last)
        }
    }

    static func agentSession(blocks: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(blocks * 30_000)
        for b in 0..<blocks {
            for k in 0..<30 {
                let needle = (b % 25 == 0 && k == 3) ? " needle" : ""
                out += Array("\u{1b}[38;5;250m● block \(b) line \(k)\(needle) \u{1b}[1mreading\u{1b}[22m some/file/path.swift — \(String(repeating: "lorem ", count: 8))\u{1b}[0m\r\n".utf8)
            }
            // The agent's status block, drawn and redrawn in place (as Ink does) 25 times.
            for f in 0..<25 {
                var frame = f == 0 ? "" : "\u{1b}[11A"
                for k in 0..<12 {
                    frame += "\r\u{1b}[2K" + (k == 0 ? "\u{1b}[38;5;174m✻ Working… (\(f)s · ↓ \(f * 37) tokens · esc to interrupt)\u{1b}[0m"
                                              : "\u{1b}[2m│ \(k) " + String(repeating: "─", count: 70) + "\u{1b}[0m")
                    if k < 11 { frame += "\r\n" }
                }
                out += Array(frame.utf8)
            }
            out += Array("\r\n".utf8)
        }
        return out
    }

    @Test func measure() async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-hprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = try #require(SessionRecorder(targetKey: "p", sessionID: UUID(), directory: dir, key: nil, whileLocked: nil))
        defer { recorder.close() }
        var settings = AppSettings()
        settings.scrollbackLines = 2_000
        let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) { SessionConfiguration(settings: settings) }
        let view = TetherTerminalView(session: session, settings: settings)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1100, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        view.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        window.contentView = view
        window.alphaValue = 0
        window.orderFrontRegardless()

        let blocks = Int(ProcessInfo.processInfo.environment["TETHER_HISTORY_PROBE_BLOCKS"] ?? "") ?? 1500
        let data = Self.agentSession(blocks: blocks)
        // All of it to the recording; the terminal as it would be after it all (its last part).
        var i = 0
        while i < data.count {
            let end = min(i + 256 * 1024, data.count)
            recorder.append(Array(data[i..<end]))
            i = end
        }
        recorder.flush()
        // The terminal as it is after all of it (fed as it came, so memory and recording agree).
        var at = 0
        while at < data.count {
            let end = min(at + 1 << 20, data.count)
            view.feed(data[at..<end])
            at = end
        }
        view.historyReader = { reader in recorder.snapshot(then: reader); return true }
        view.historyIndex = { recorder.index }
        print("HPROBE session: \(data.count / 1_000_000) MB, \(recorder.index.lines) line breaks, window \(view.historyWindowLines) lines")

        print("HPROBE state: older=\(view.hasOlderOutput) onDisk=\(view.hasHistoryOnDisk) dropped=\(view.linesDropped) exact=\(recorder.index.isExact) url=\(recorder.url.lastPathComponent)")
        let stall = Stall()
        func waitLoaded() async throws {
            for _ in 0..<3000 where view.history?.loading != false { try await Task.sleep(for: .milliseconds(5)) }
        }
        // Into the recording, then on up.
        stall.start()
        var t0 = ProcessInfo.processInfo.systemUptime
        let started = view.loadOlderHistory()
        print("HPROBE load started: \(started) loading=\(String(describing: view.history?.loading))")
        try await waitLoaded()
        print("HPROBE first part: \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - t0)) s, main held \(String(format: "%.2f", stall.stop())) s")
        for k in 0..<4 {
            stall.start()
            t0 = ProcessInfo.processInfo.systemUptime
            view.displayedTerminal.scrollTo(row: 0)
            view.requestOlderHistory()
            try await Task.sleep(for: .milliseconds(30))
            try await waitLoaded()
            print("HPROBE older part \(k + 1): \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - t0)) s, main held \(String(format: "%.2f", stall.stop())) s, rows \(view.history?.bufferRows ?? 0)")
        }
        // As the wheel does: three rows at a time, sixty times a second, for a while.
        stall.start()
        t0 = ProcessInfo.processInfo.systemUptime
        var stuck: TimeInterval = 0, steps = 0
        var last = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - t0 < 15 {
            let h = view.displayedTerminal
            h.scrollUp(lines: 3)
            if h.getTerminal().buffer.yDisp == 0 {
                view.requestOlderHistory()
                if view.history?.loading == true { stuck += ProcessInfo.processInfo.systemUptime - last }
            }
            last = ProcessInfo.processInfo.systemUptime
            steps += 1
            try await Task.sleep(for: .milliseconds(16))
        }
        print("HPROBE wheel 15 s: \(steps) steps, waited at the edge \(String(format: "%.2f", stuck)) s, main held \(String(format: "%.2f", stall.stop())) s, at line \(view.history?.topLine ?? -1)")
        view.returnToLive()

        // Find: what is in memory at once, then the recording.
        var status = TerminalFindStatus()
        var firstCount: (TimeInterval, Int)?
        stall.start()
        t0 = ProcessInfo.processInfo.systemUptime
        view.onFindStatus = { s in
            status = s
            if firstCount == nil, s.total > 0 { firstCount = (ProcessInfo.processInfo.systemUptime - t0, s.total) }
        }
        view.setFind(TerminalFindQuery(term: "needle"))
        for _ in 0..<24000 where status.searchingRecording || status.total == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let findTime = ProcessInfo.processInfo.systemUptime - t0
        print("HPROBE find detail: earlier=\(view.findSession?.earlier.count ?? -1) memory=\(view.findSession?.matches.count ?? -1) searching=\(status.searchingRecording)")
        print("HPROBE find: first count \(firstCount.map { String(format: "%.2f s (%d)", $0.0, $0.1) } ?? "-"), all \(String(format: "%.2f", findTime)) s (\(status.total)), main held \(String(format: "%.2f", stall.stop())) s")
        stall.start()
        t0 = ProcessInfo.processInfo.systemUptime
        view.findStep(forward: true)    // the oldest: from the recording
        for _ in 0..<3000 where view.history?.loading != false || view.history?.selection.active != true { try await Task.sleep(for: .milliseconds(5)) }
        print("HPROBE first match shown: \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - t0)) s, main held \(String(format: "%.2f", stall.stop())) s")
    }
}
