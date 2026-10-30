import AppKit
import os
import SessionKit
import TetherCore

/// Owns one terminal view per session so views (and their scrollback) survive tab switches
/// and moving between windows.
@MainActor
public final class TerminalRegistry {
    public static let shared = TerminalRegistry()
    private var views: [UUID: TetherTerminalView] = [:]

    public func view(for session: TerminalSession) -> TetherTerminalView {
        if let v = views[session.id] { return v }
        let v = TetherTerminalView(session: session, settings: SettingsStore.shared.settings)
        // The size the tabs have now: a tab made off screen (restored, opened in the background)
        // takes its output at the width it will be shown at, so showing it rewraps nothing.
        if let size = Self.lastHostSize { v.setFrameSize(size) }
        views[session.id] = v
        v.batchesWhileHidden = true
        session.attach(sink: v)
        // Scrolling past what is in memory reads earlier output back from the recording (also for
        // a tab that kept only its last lines while off screen).
        v.historyReader = { [weak session] reader in session?.readRecording(reader) ?? false }
        v.historyIndex = { [weak session] in session?.recordingIndex }
        return v
    }

    public func existingView(for id: UUID) -> TetherTerminalView? { views[id] }

    /// The size a tab's terminal was last given (see `view(for:)`).
    static var lastHostSize: NSSize?

    /// The tab closed: its view goes, and with it the whole scrollback. The callbacks the window
    /// set capture the session, which holds the view: they are let go of so neither keeps the other.
    public func remove(_ id: UUID) {
        guard let v = views.removeValue(forKey: id) else { return }
        v.removeFromSuperview()
        v.releaseCallbacks()
    }

    /// Tether locks: every terminal lets go of earlier output it read back from its recording.
    public func releaseEarlierOutput() {
        for v in views.values { v.releaseEarlierOutput() }
    }

    /// Watches for the Mac running short of memory (macOS says so before it starts swapping hard):
    /// then every terminal gives back what it can at once (`TetherTerminalView.relieveMemory`).
    private lazy var memoryPressure: DispatchSourceMemoryPressure = {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Logger(subsystem: "io.github.whileendless.tether", category: "app")
                    .notice("The Mac is short of memory: terminals off screen keep only their last lines")
                for v in self.views.values { v.relieveMemory() }
            }
        }
        return source
    }()

    private init() {
        memoryPressure.resume()
    }

    public func applySettings(_ settings: AppSettings) {
        for v in views.values { v.apply(settings: settings) }
    }
}
