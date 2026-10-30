import AppKit
import Testing
import TetherCore
import RecordingKit
@testable import SessionKit
@testable import TerminalUI

/// A closed tab gives its memory back: the view (with the whole scrollback) and the session.
@MainActor
struct ClosedTabMemoryTests {
    @Test func closingATabFreesItsViewAndSession() async throws {
        _ = NSApplication.shared
        weak var weakSession: TerminalSession?
        weak var weakView: TetherTerminalView?
        do {
            let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) {
                SessionConfiguration(settings: AppSettings())
            }
            let view = TerminalRegistry.shared.view(for: session)
            // The window's callbacks capture the session, as SessionPane's do.
            view.onReachedHistoryLimit = { _ in _ = session.id }
            view.onFindStatus = { _ in _ = session.id }
            view.feed(Array("some output\r\n".utf8)[...])
            weakSession = session
            weakView = view
            TerminalRegistry.shared.remove(session.id)
        }
        // Display updates already queued finish first.
        for _ in 0..<20 where weakView != nil { try await Task.sleep(for: .milliseconds(50)) }
        #expect(weakView == nil)
        #expect(weakSession == nil)
    }
}

/// A tab off screen keeps only its last lines in memory when its recording holds the rest; the
/// rest comes back from disk when scrolled to.
@MainActor
struct HiddenTabMemoryTests {
    @Test func aHiddenTabKeepsItsLastLinesAndGetsTheRestBack() async throws {
        _ = NSApplication.shared
        var settings = AppSettings()
        settings.scrollbackLines = 10_000
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-hidden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = try #require(SessionRecorder(targetKey: "hidden", sessionID: UUID(), directory: dir))
        defer { recorder.close() }
        var view: TetherTerminalView!
        do {   // the session is gone (only the view and its recording matter here)
            let session = TerminalSession(descriptor: SessionDescriptor(target: .local, persistence: .off)) {
                SessionConfiguration(settings: settings)
            }
            view = TetherTerminalView(session: session, settings: settings)
        }
        view.getTerminal().resize(cols: 80, rows: 24)
        for i in 1...12_000 {
            let bytes = Array("line \(i)\r\n".utf8)
            view.feed(bytes[...])
            recorder.append(bytes)
        }
        view.historyReader = { reader in recorder.snapshot(then: reader); return true }
        let before = view.bufferLineCount
        #expect(before > 9_000)
        view.shrinkHidden()
        #expect(view.bufferLineCount <= TetherTerminalView.hiddenScrollbackLines + 24)
        let last = view.getTerminal().getLine(row: view.getTerminal().rows - 2)?.translateToString(trimRight: true) ?? ""
        #expect(last.contains("line 12000"), "the end of the output is still there")

        view.scrollTo(row: 0)
        let loaded = await withCheckedContinuation { done in
            view.onHistoryLoaded = { view.onHistoryLoaded = nil; done.resume(returning: $0) }
            if !view.loadOlderHistory() { done.resume(returning: false) }
        }
        #expect(loaded)
        #expect(view.isBrowsingHistory)
        #expect((view.history?.bufferRows ?? 0) > TetherTerminalView.hiddenScrollbackLines + 1_000)
    }
}
