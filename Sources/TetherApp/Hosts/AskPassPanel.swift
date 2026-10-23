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
        guard let prompt else {
            panel?.orderOut(nil)
            shownID = nil
            return
        }
        guard prompt.id != shownID else { return }
        shownID = prompt.id
        let view = AskPassPromptView(prompt: prompt).environment(AppModel.shared)
        let panel = self.panel ?? makePanel()
        panel.contentViewController = NSHostingController(rootView: view)
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
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
