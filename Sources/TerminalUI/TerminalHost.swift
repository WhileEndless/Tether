import SwiftUI
import SessionKit

/// Hosts a session's persistent terminal view inside SwiftUI.
///
/// A session has one terminal view, so only one host may hold it. When a tab moves to another
/// window, the old window's host can still be updated for a moment (e.g. during its fade-out); it
/// must not take the view back, or the new window is left with an empty terminal that cannot be
/// typed in. `isCurrent` says whether this host's window is where the session's tab is now.
public struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    let focused: Bool
    let isCurrent: () -> Bool

    public init(session: TerminalSession, focused: Bool = true, isCurrent: @escaping () -> Bool = { true }) {
        self.session = session
        self.focused = focused
        self.isCurrent = isCurrent
    }

    public final class Container: NSView {
        var session: TerminalSession?
        var isCurrent: () -> Bool = { true }
        var wantsFocus = true

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            claim()
            focusTerminal()
        }

        /// Takes the session's terminal view, unless another window's tab now owns it. Only once
        /// this host has its size: given a passing one (none yet, while SwiftUI lays it out), the
        /// terminal would wrap its whole scrollback for it and then again for the real one.
        func claim() {
            guard let session, isCurrent() else { return }
            let terminal = TerminalRegistry.shared.view(for: session)
            guard terminal.superview !== self else { return }
            guard bounds.width >= 40, bounds.height >= 20 else { claimWhenSized = true; return }
            claimWhenSized = false
            subviews.forEach { $0.removeFromSuperview() }
            terminal.removeFromSuperview()
            // At its place before the constraints say so: no other size on the way. Then held by
            // its constraints only (no fixed size of its own), so it follows the host's size.
            terminal.frame = bounds
            terminal.translatesAutoresizingMaskIntoConstraints = false
            addSubview(terminal)
            NSLayoutConstraint.activate([
                terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
                terminal.topAnchor.constraint(equalTo: topAnchor),
                terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        private var claimWhenSized = false

        public override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            if newSize.width >= 40, newSize.height >= 20, window != nil { TerminalRegistry.lastHostSize = newSize }
            if claimWhenSized { claim() }
        }

        /// Gives the terminal the keyboard once it is really in a window (after a move, the first
        /// attempt can come before the window exists). `takeBack` false (a mere SwiftUI update of the
        /// same terminal): never from a view `TerminalHost.keepsFocus` names — a list beside the
        /// terminal that was clicked keeps the keyboard, or its ⌘C and ⌘V would reach nothing.
        func focusTerminal(takeBack: Bool = true) {
            guard wantsFocus else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.claim()   // in case a stale host held it a moment ago
                guard let window = self.window, let terminal = self.subviews.first,
                      window.firstResponder !== terminal else { return }
                // A text field over the terminal is being typed in (the find bar, renaming a tab):
                // SwiftUI updates this host as the text changes, and must not take the keyboard away.
                if window.firstResponder is NSText { return }
                if !takeBack, let current = window.firstResponder, TerminalHost.keepsFocus?(current) == true { return }
                window.makeFirstResponder(terminal)
            }
        }
    }

    public func makeNSView(context: Context) -> Container {
        let container = Container()
        container.wantsLayer = true
        // Never draw outside the area SwiftUI gave us (views do not clip by default since macOS 14).
        container.clipsToBounds = true
        return container
    }

    public func updateNSView(_ container: Container, context: Context) {
        let changed = container.session !== session || container.wantsFocus != focused
        container.session = session
        container.isCurrent = isCurrent
        container.wantsFocus = focused
        container.claim()
        container.focusTerminal(takeBack: changed)
    }

    /// Views beside a terminal that keep the keyboard once the user gave it to them (set by the app:
    /// the file manager's list).
    @MainActor public static var keepsFocus: ((NSResponder) -> Bool)?
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
