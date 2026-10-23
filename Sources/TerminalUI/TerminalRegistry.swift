import AppKit
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
        views[session.id] = v
        session.attach(sink: v)
        return v
    }

    public func existingView(for id: UUID) -> TetherTerminalView? { views[id] }

    public func remove(_ id: UUID) {
        views[id]?.removeFromSuperview()
        views[id] = nil
    }

    public func applySettings(_ settings: AppSettings) {
        for v in views.values { v.apply(settings: settings) }
    }
}
