import SwiftUI
import SessionKit

/// Hosts a session's persistent terminal view inside SwiftUI.
public struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    let focused: Bool

    public init(session: TerminalSession, focused: Bool = true) {
        self.session = session
        self.focused = focused
    }

    public func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        // Never draw outside the area SwiftUI gave us (views do not clip by default since macOS 14).
        container.clipsToBounds = true
        return container
    }

    public func updateNSView(_ container: NSView, context: Context) {
        let terminal = TerminalRegistry.shared.view(for: session)
        if terminal.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            terminal.removeFromSuperview()
            terminal.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(terminal)
            NSLayoutConstraint.activate([
                terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                terminal.topAnchor.constraint(equalTo: container.topAnchor),
                terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        if focused {
            DispatchQueue.main.async {
                if let window = container.window, window.firstResponder !== terminal {
                    window.makeFirstResponder(terminal)
                }
            }
        }
    }
}

/// A read-only terminal that replays a recorded transcript.
public struct TranscriptView: NSViewRepresentable {
    let data: Data
    let revealText: String?
    let revealFraction: Double

    public init(data: Data, revealText: String? = nil, revealFraction: Double = 0) {
        self.data = data
        self.revealText = revealText
        self.revealFraction = revealFraction
    }

    public func makeNSView(context: Context) -> ReadOnlyTerminalView {
        let v = ReadOnlyTerminalView(frame: .zero)
        v.pending = data
        v.revealText = revealText
        v.revealFraction = revealFraction
        return v
    }

    public func updateNSView(_ nsView: ReadOnlyTerminalView, context: Context) {}
}
