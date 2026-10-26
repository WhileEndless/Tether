import SwiftUI
import AppKit
import TetherCore

// Settings ▸ Appearance applied to the app's windows: light/dark, the accent colour and the size
// of text and icons. macOS has no Dynamic Type, so the size is an environment value that views
// read through `uiFont` and `scaled`; at the default size both give exactly the system styles.

private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// Multiplier for text, icons and fixed row metrics in the main windows (Settings ▸ Appearance).
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

extension Font.TextStyle {
    /// The point sizes of the macOS text styles.
    var macPointSize: CGFloat {
        switch self {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption, .caption2: 10
        @unknown default: 13
        }
    }

    var macWeight: Font.Weight { self == .headline ? .semibold : .regular }
}

private struct UIFont: ViewModifier {
    @Environment(\.uiScale) private var scale
    let style: Font.TextStyle?
    let size: CGFloat?
    let weight: Font.Weight?
    let design: Font.Design?

    func body(content: Content) -> some View {
        content.font(font)
    }

    private var font: Font {
        if let style, scale == 1 {
            var f = Font.system(style, design: design)
            if let weight { f = f.weight(weight) }
            return f
        }
        let base = size ?? style?.macPointSize ?? 13
        return .system(size: (base * scale).rounded(.toNearestOrEven), weight: weight ?? style?.macWeight ?? .regular,
                       design: design ?? .default)
    }
}

extension View {
    /// A text style that follows the interface size (Settings ▸ Appearance).
    func uiFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(UIFont(style: style, size: nil, weight: weight, design: design))
    }

    /// A fixed point size (small glyphs, badges) that follows the interface size.
    func uiFont(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(UIFont(style: nil, size: size, weight: weight, design: design))
    }
}

extension AppAppearance {
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension UITextSize {
    var sidebarRowSize: SidebarRowSize {
        switch self {
        case .small: .small
        case .standard: .medium
        case .large, .extraLarge: .large
        }
    }
}

/// Accent colours offered in Settings ▸ Appearance (`.none` = the system's).
extension TagColor {
    static let accentChoices: [TagColor] = [.none, .blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .gray]
}

private struct TetherAppearance: ViewModifier {
    @Environment(AppModel.self) private var model
    var scalesInterface: Bool

    func body(content: Content) -> some View {
        let s = model.settings
        content
            .tint(s.accentColor.color)
            .environment(\.uiScale, scalesInterface ? CGFloat(s.uiTextSize.scale) : 1)
            .environment(\.sidebarRowSize, scalesInterface ? s.uiTextSize.sidebarRowSize : .medium)
    }
}

extension View {
    /// Accent colour, and with `scalesInterface` the interface size, from Settings ▸ Appearance.
    func tetherAppearance(scalesInterface: Bool = true) -> some View {
        modifier(TetherAppearance(scalesInterface: scalesInterface))
    }
}

extension AppModel {
    /// Light or dark for every window (and the terminals in them, whose themes follow the app).
    func applyAppearance() {
        let wanted = settings.appearance.nsAppearance
        if NSApp.appearance?.name != wanted?.name { NSApp.appearance = wanted }
    }
}
