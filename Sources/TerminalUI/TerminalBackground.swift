import SwiftUI
import TetherCore

/// Background behind a terminal: a solid colour, or a blurred translucent one for
/// translucent Terminal.app profiles such as "Clear Dark".
public struct TerminalBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    let settings: AppSettings

    public init(settings: AppSettings) { self.settings = settings }

    public var body: some View {
        let theme = TerminalTheme.resolve(settings, appearance: NSApp.effectiveAppearance)
        if theme.isTranslucent {
            VisualEffectBlur()
        } else {
            Color(nsColor: theme.background)
        }
    }
}

struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
