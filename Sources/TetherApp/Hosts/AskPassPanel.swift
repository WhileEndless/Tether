import AppKit
import SwiftUI

/// Floating panel for ssh password / passphrase / host-key prompts. Independent of windows so it
/// works no matter which tab (or no window at all) triggered the prompt.
@MainActor
final class AskPassPanel {
    static let shared = AskPassPanel()
    private var panel: NSPanel?
    private var shownID: UUID?

    func update(_ prompt: PendingPrompt?) {
        // Behind the lock screen nothing is asked; the prompt waits and appears after unlocking.
        guard let prompt, !AppLock.shared.isLocked else {
            panel?.orderOut(nil)
            shownID = nil
            return
        }
        guard prompt.id != shownID else { return }
        shownID = prompt.id
        let view = AskPassPromptView(prompt: prompt).environment(AppModel.shared)
        let panel = self.panel ?? makePanel()
        let host = NSHostingController(rootView: view)
        panel.contentViewController = host
        // At its own size first (SwiftUI works it out from the content), then placed: centred
        // over the Tether window in front — where the user is looking — or on the screen.
        panel.setContentSize(host.view.fittingSize)
        place(panel)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

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
