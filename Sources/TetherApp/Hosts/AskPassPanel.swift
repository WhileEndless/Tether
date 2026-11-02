import AppKit
import SwiftUI
import SSHTransport

/// Floating panel for ssh password / passphrase / host-key prompts. Independent of windows so it
/// works no matter which tab (or no window at all) triggered the prompt.
@MainActor
final class AskPassPanel {
    static let shared = AskPassPanel()
    private var panel: NSPanel?
    /// The prompt the panel holds (also while hidden: shown again, it keeps what was typed).
    private var shownID: UUID?

    /// Set while the panel is being shown: making it key posts notifications whose observers may
    /// ask for the panel again. Such a request is not followed inside the showing (that is how it
    /// once recursed until the stack ran out); one refresh after it answers it.
    private var presenting = false
    private var askedWhilePresenting = false

    func update(_ prompt: PendingPrompt?) {
        guard !presenting else { askedWhilePresenting = true; return }
        // Behind the lock screen nothing is asked; the prompt waits and appears after unlocking.
        // Locking forgets what was typed into it.
        if AppLock.shared.isLocked { shownID = nil }
        guard let prompt, !AppLock.shared.isLocked else {
            panel?.orderOut(nil)
            return
        }
        // The same question again (its tab is in front again): the panel as it was, text and all.
        if prompt.id == shownID, let panel {
            // Hidden because another app is in front (the user may be copying the password from a
            // password manager): it comes back by itself when Tether does — not pulled forward.
            if NSApp.isActive, !panel.isVisible, !panel.isKeyWindow { present(panel) }
            notePresented(prompt)
            return
        }
        let panel = self.panel ?? makePanel()
        // Known before it is shown: showing it may lead straight back here.
        self.panel = panel
        shownID = prompt.id
        let view = AskPassPromptView(prompt: prompt).environment(AppModel.shared)
        let host = NSHostingController(rootView: view)
        panel.contentViewController = host
        // At its own size first (SwiftUI works it out from the content), then placed: centred
        // over the Tether window in front — where the user is looking — or on the screen.
        panel.setContentSize(host.view.fittingSize)
        place(panel)
        present(panel)
        notePresented(prompt)
    }

    /// Whether the panel is on screen now (not merely made: activating Tether may be refused).
    var isShowing: Bool { panel?.isVisible == true }

    /// In front of the user now: what waits for its answer may wait (see `waitsOnUser`). Only once
    /// it really is on screen — a question nobody saw must not switch the time limits off.
    private func notePresented(_ prompt: PendingPrompt) {
        guard isShowing else { return }
        AskPassBridge.shared.notePresented(token: prompt.request.token)
    }

    private func present(_ panel: NSPanel) {
        presenting = true
        askedWhilePresenting = false
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        presenting = false
        if askedWhilePresenting {
            askedWhilePresenting = false
            AppModel.shared.refreshPromptPanel()
        }
    }

    /// For the self-test: how many panels were made, and whether one is being shown now.
    private(set) var panelsMade = 0
    var isPresenting: Bool { presenting }

    private func place(_ panel: NSPanel) {
        let over = (NSApp.keyWindow ?? NSApp.mainWindow).flatMap { $0 === panel || !$0.isVisible ? nil : $0 }
            ?? NSApp.orderedWindows.first { $0 !== panel && $0.isVisible && $0.canBecomeMain }
        guard let over, let screen = over.screen ?? NSScreen.main else { panel.center(); return }
        let size = panel.frame.size
        var origin = NSPoint(x: over.frame.midX - size.width / 2, y: over.frame.midY - size.height / 2 + over.frame.height / 10)
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrameOrigin(origin)
    }

    private func makePanel() -> NSPanel {
        panelsMade += 1
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isFloatingPanel = true
        p.level = .modalPanel
        p.isMovableByWindowBackground = true
        return p
    }
}
