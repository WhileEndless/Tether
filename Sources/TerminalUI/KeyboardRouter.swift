import AppKit
import TetherCore

/// Applies user key mappings (e.g. ⌘← → Ctrl-A) before the terminal sees the event.
/// Everything that is not mapped flows to the terminal unchanged, so vim, fzf, emacs etc.
/// receive their Ctrl/Meta keys as usual.
@MainActor
final class KeyboardRouter {
    static let shared = KeyboardRouter()
    private var monitor: Any?
    var mappings: [KeyMapping] = []

    private static let specialKeys: [UInt16: String] = [
        123: "left", 124: "right", 125: "down", 126: "up", 51: "delete", 117: "forwarddelete",
        115: "home", 119: "end", 116: "pageup", 121: "pagedown", 36: "return", 76: "return",
        48: "tab", 53: "escape", 49: "space",
    ]

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let view = event.window?.firstResponder as? TetherTerminalView else { return event }
            if view.handleNavigationKey(event) { return nil }
            if let mapping = self.match(event) {
                view.sendMapped(mapping.bytes)
                return nil
            }
            return event
        }
    }

    func match(_ event: NSEvent) -> KeyMapping? {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = Self.specialKeys[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "").lowercased()
        return mappings.first { m in
            m.enabled && m.key == key
                && m.command == flags.contains(.command) && m.option == flags.contains(.option)
                && m.control == flags.contains(.control) && m.shift == flags.contains(.shift)
        }
    }
}

/// When tabs show the number to press (⌘1…⌘9): while ⌘ alone is held in the active app.
public enum TabNumberHold {
    public static func shows(flags: NSEvent.ModifierFlags, appActive: Bool) -> Bool {
        appActive && flags.intersection([.command, .option, .control, .shift]) == .command
    }
}
