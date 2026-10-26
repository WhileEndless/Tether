import SwiftUI
import TetherCore
import TerminalUI

// Pickers and previews for Settings ▸ Appearance and the first-launch setup. Every choice shows
// what it looks like: drawn window and sidebar sketches, and terminal samples in the real colours.

extension TerminalTheme {
    var foregroundColor: Color { Color(nsColor: foreground) }
    var backgroundColor: Color { Color(nsColor: background.withAlphaComponent(1)) }

    func ansiColor(_ i: Int) -> Color { Color(nsColor: ansiNSColor(i)) }
}

// MARK: - Cards

/// A choice shown as a picture with a title; the chosen one gets an accent outline.
struct ChoiceCard<Preview: View>: View {
    let title: String
    var subtitle: String?
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var preview: Preview

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                preview
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1)
                    }
                    .padding(selected ? 0 : 0)
                VStack(spacing: 1) {
                    Text(title).font(.callout.weight(selected ? .semibold : .regular))
                    if let subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).lineLimit(2, reservesSpace: true)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Window and sidebar sketches

/// Colours of the drawn window sketches (not the live window: a sketch shows light or dark
/// whatever the app currently is).
private struct SketchPalette {
    let dark: Bool
    var window: Color { dark ? Color(white: 0.16) : Color(white: 0.965) }
    var sidebar: Color { dark ? Color(white: 0.21) : Color(white: 0.915) }
    var text: Color { dark ? Color(white: 0.88) : Color(white: 0.18) }
    var secondary: Color { dark ? Color(white: 0.58) : Color(white: 0.48) }
    var faint: Color { dark ? Color(white: 0.34) : Color(white: 0.78) }
    var divider: Color { dark ? Color.black.opacity(0.5) : Color.black.opacity(0.1) }
}

/// A small drawing of a Tether window: sidebar in the given style, a terminal in the given theme.
struct WindowSketch: View {
    let dark: Bool
    var accent: Color = .accentColor
    var style: SidebarStyle = .detailed
    var terminal: TerminalTheme

    var body: some View {
        let p = SketchPalette(dark: dark)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                    Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                    Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
                }
                .frame(height: 6)
                .padding(.leading, 6).padding(.top, 6).padding(.bottom, 4)
                SidebarSketch(style: style, dark: dark, accent: accent, scale: 0.78)
                    .padding(.horizontal, 3)
                Spacer(minLength: 0)
            }
            .frame(width: 70)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(p.sidebar)
            Rectangle().fill(p.divider).frame(width: 0.5)
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Capsule().fill(accent.opacity(0.85)).frame(width: 22, height: 5)
                    Capsule().fill(p.faint).frame(width: 18, height: 5)
                    Spacer()
                }
                .padding(.horizontal, 6).frame(height: 14)
                .background(p.window)
                TerminalSketch(theme: terminal)
            }
        }
        .background(p.window)
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// Lines of "text" in a terminal's colours, for small sketches.
struct TerminalSketch: View {
    let theme: TerminalTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3.5) {
            line([(2, 16), (4, 12), (-1, 5)])
            line([(-1, 10), (4, 14), (2, 9)])
            line([(2, 7), (1, 9), (-1, 12)])
            line([(6, 8), (3, 20), (-1, 6)])
            line([(2, 16), (-1, 4)])
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.backgroundColor)
    }

    private func line(_ parts: [(Int, CGFloat)]) -> some View {
        HStack(spacing: 2.5) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Capsule()
                    .fill(part.0 < 0 ? theme.foregroundColor.opacity(0.85) : theme.ansiColor(part.0))
                    .frame(width: part.1, height: 3.5)
            }
        }
    }
}

/// A miniature sidebar in one of the styles, with sample hosts (never real ones).
struct SidebarSketch: View {
    let style: SidebarStyle
    let dark: Bool
    var accent: Color = .accentColor
    var scale: CGFloat = 1

    private struct Row: Identifiable {
        enum Kind { case header, folder, host, session }
        let id = UUID()
        var kind: Kind
        var name: String
        var detail: String? = nil
        var state: Color? = nil
        var waiting = false
        var selected = false
        var indent = 0
        var open = false
        var count: String? = nil
        var tag: Color? = nil
    }

    private var rows: [Row] {
        let green = Color.green, gray = Color.gray
        switch style {
        case .detailed:
            return [
                Row(kind: .header, name: "PRODUCTION"),
                Row(kind: .host, name: "db-1", detail: "admin@db-1", state: green, count: "2"),
                Row(kind: .session, name: "zsh", state: green, indent: 1),
                Row(kind: .session, name: "claude", waiting: true, selected: true, indent: 1),
                Row(kind: .host, name: "api-1", detail: "deploy@api-1", state: gray),
                Row(kind: .header, name: "STAGING"),
                Row(kind: .host, name: "web-1", detail: "user@web-1", state: green, count: "1"),
            ]
        case .compact:
            return [
                Row(kind: .header, name: "PRODUCTION"),
                Row(kind: .host, name: "db-1", state: green, count: "2"),
                Row(kind: .session, name: "zsh", state: green, indent: 1),
                Row(kind: .session, name: "claude", waiting: true, selected: true, indent: 1),
                Row(kind: .host, name: "api-1", state: gray),
                Row(kind: .header, name: "STAGING"),
                Row(kind: .host, name: "web-1", state: green, count: "1"),
                Row(kind: .host, name: "web-2", state: gray),
            ]
        case .folders:
            return [
                Row(kind: .folder, name: "Favorites", open: false, count: "2"),
                Row(kind: .folder, name: "Production", open: true, count: "3", tag: .orange),
                Row(kind: .host, name: "db-1", state: green, indent: 1, open: true),
                Row(kind: .session, name: "zsh", state: green, indent: 2),
                Row(kind: .session, name: "claude", waiting: true, selected: true, indent: 2),
                Row(kind: .host, name: "api-1", state: gray, indent: 1),
                Row(kind: .folder, name: "Staging", open: false, count: "2", tag: .blue),
                Row(kind: .folder, name: "Other Hosts", open: false, count: "4"),
            ]
        case .minimal:
            return [
                Row(kind: .header, name: "Production"),
                Row(kind: .host, name: "db-1"),
                Row(kind: .session, name: "zsh", indent: 1),
                Row(kind: .session, name: "claude", waiting: true, selected: true, indent: 1),
                Row(kind: .host, name: "api-1"),
                Row(kind: .header, name: "Staging"),
                Row(kind: .host, name: "web-1"),
                Row(kind: .host, name: "web-2"),
            ]
        case .flat:
            return [
                Row(kind: .host, name: "api-1", detail: "deploy@api-1", state: gray, tag: .orange),
                Row(kind: .host, name: "db-1", detail: "admin@db-1", state: green, tag: .orange),
                Row(kind: .session, name: "claude", waiting: true, selected: true, indent: 1),
                Row(kind: .host, name: "web-1", detail: "user@web-1", state: green, tag: .blue),
                Row(kind: .host, name: "web-2", detail: "user@web-2", state: gray, tag: .blue),
            ]
        }
    }

    var body: some View {
        let p = SketchPalette(dark: dark)
        VStack(alignment: .leading, spacing: 1.5 * scale) {
            ForEach(rows) { row in
                rowView(row, p)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rowView(_ r: Row, _ p: SketchPalette) -> some View {
        let font: CGFloat = 8 * scale
        HStack(spacing: 3 * scale) {
            if r.kind == .header {
                Text(r.name)
                    .font(.system(size: (style == .minimal ? 7 : 6.5) * scale, weight: .semibold))
                    .foregroundStyle(style == .minimal ? p.faint : p.secondary)
                    .padding(.top, 2.5 * scale)
            } else {
                if style == .folders, r.kind != .session {
                    Image(systemName: r.open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 5 * scale, weight: .bold)).foregroundStyle(p.secondary)
                        .frame(width: 5 * scale)
                }
                icon(r, p)
                VStack(alignment: .leading, spacing: 0) {
                    Text(r.name).font(.system(size: font, weight: r.kind == .folder ? .medium : .regular))
                        .foregroundStyle(r.selected ? Color.white : p.text)
                    if let detail = r.detail, r.kind == .host {
                        Text(detail).font(.system(size: 6 * scale)).foregroundStyle(r.selected ? Color.white.opacity(0.8) : p.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                if let count = r.count, style != .minimal {
                    if style == .detailed {
                        Text(count).font(.system(size: 6 * scale, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 3 * scale)
                            .background(Capsule().fill(Color.green.opacity(0.85)))
                    } else {
                        Text(count).font(.system(size: 6.5 * scale)).foregroundStyle(p.secondary)
                    }
                }
            }
        }
        .padding(.leading, CGFloat(r.indent) * 7 * scale + 2 * scale)
        .padding(.trailing, 3 * scale)
        .padding(.vertical, (r.kind == .header ? 0 : (style == .detailed && r.kind == .host ? 1.5 : 1)) * scale)
        .background {
            if r.selected {
                RoundedRectangle(cornerRadius: 3 * scale).fill(accent)
            }
        }
    }

    @ViewBuilder
    private func icon(_ r: Row, _ p: SketchPalette) -> some View {
        let size: CGFloat = 7 * scale
        Group {
            if r.waiting {
                Image(systemName: "hand.raised.fill").foregroundStyle(r.selected ? Color.white : Color.orange)
            } else {
                switch r.kind {
                case .folder:
                    Image(systemName: r.name == "Favorites" ? "star.fill" : (r.name == "Other Hosts" ? "tray.fill" : "folder.fill"))
                        .foregroundStyle(r.name == "Favorites" ? Color.yellow : (r.tag ?? p.secondary))
                case .host:
                    switch style {
                    case .minimal: EmptyView()
                    case .compact: Circle().fill(r.state ?? p.faint).frame(width: 4.5 * scale, height: 4.5 * scale)
                    case .flat:
                        Circle().fill(r.tag ?? p.faint).frame(width: 4.5 * scale, height: 4.5 * scale)
                    default: Image(systemName: "server.rack").foregroundStyle(r.state == .green ? Color.accentColor : p.secondary)
                    }
                case .session:
                    if style == .minimal { EmptyView() } else {
                        Image(systemName: "terminal").foregroundStyle(r.selected ? Color.white : p.secondary)
                    }
                case .header: EmptyView()
                }
            }
        }
        .font(.system(size: size))
        .frame(width: style == .minimal && !r.waiting ? 0 : size + 1)
    }
}

// MARK: - Terminal sample

/// A few lines of typical terminal output in a theme's real colours and the chosen font.
struct TerminalSample: View {
    let theme: TerminalTheme
    var fontName: String = ""
    var size: CGFloat = 11

    private var font: Font {
        if !fontName.isEmpty, NSFont(name: fontName, size: size) != nil { return .custom(fontName, size: size) }
        return .system(size: size, design: .monospaced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            line([("user@web-1", 2), (" ~/app ", 4), ("$ ls", -1)])
            line([("README.md  ", -1), ("src/  ", 12), ("deploy.sh  ", 10), ("notes.txt", -1)])
            line([("$ git diff --stat", -1)])
            line([(" app.swift | 9 ", -1), ("+++++", 2), ("----", 1)])
            line([("CPU ", 6), ("[", -1), ("||||||", 2), ("|||", 3), ("||", 1), ("     58%", -1), ("]", -1)])
            line([("warning: ", 3), ("disk 81% full  ", -1), ("error: ", 1), ("timeout", -1)])
        }
        .font(font)
        .lineLimit(1)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.backgroundColor)
    }

    private func line(_ parts: [(String, Int)]) -> some View {
        parts.reduce(Text("")) { text, part in
            text + Text(part.0).foregroundColor(part.1 < 0 ? theme.foregroundColor : theme.ansiColor(part.1))
        }
    }
}

/// A theme as a small swatch: its background with "Aa" and the six colours.
struct ThemeSwatch: View {
    let palette: TerminalPalette

    var body: some View {
        let t = TerminalTheme.palette(palette)
        VStack(alignment: .leading, spacing: 5) {
            Text("Aa").font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(t.foregroundColor)
            HStack(spacing: 3) {
                ForEach(1..<7, id: \.self) { i in
                    Circle().fill(t.ansiColor(i)).frame(width: 7, height: 7)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .background(t.backgroundColor)
    }
}

// MARK: - Pickers

struct AppearanceModePicker: View {
    @Binding var settings: AppSettings

    var body: some View {
        HStack(spacing: 14) {
            ForEach(AppAppearance.allCases) { mode in
                ChoiceCard(title: mode.title, selected: settings.appearance == mode, action: { settings.appearance = mode }) {
                    sketch(for: mode).frame(height: 84)
                }
            }
        }
    }

    @ViewBuilder
    private func sketch(for mode: AppAppearance) -> some View {
        let accent = settings.accentColor.color ?? .accentColor
        switch mode {
        case .light: WindowSketch(dark: false, accent: accent, style: settings.sidebarStyle, terminal: TerminalTheme.resolve(settings, dark: false))
        case .dark: WindowSketch(dark: true, accent: accent, style: settings.sidebarStyle, terminal: TerminalTheme.resolve(settings, dark: true))
        case .system:
            // Half light, half dark.
            ZStack {
                WindowSketch(dark: false, accent: accent, style: settings.sidebarStyle, terminal: TerminalTheme.resolve(settings, dark: false))
                WindowSketch(dark: true, accent: accent, style: settings.sidebarStyle, terminal: TerminalTheme.resolve(settings, dark: true))
                    .mask {
                        GeometryReader { g in
                            Path { p in
                                p.move(to: CGPoint(x: g.size.width * 0.62, y: 0))
                                p.addLine(to: CGPoint(x: g.size.width, y: 0))
                                p.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                                p.addLine(to: CGPoint(x: g.size.width * 0.38, y: g.size.height))
                                p.closeSubpath()
                            }
                        }
                    }
            }
        }
    }
}

struct AccentPicker: View {
    @Binding var accent: TagColor

    var body: some View {
        HStack(spacing: 9) {
            ForEach(TagColor.accentChoices) { c in
                Button { accent = c } label: {
                    ZStack {
                        if let color = c.color {
                            Circle().fill(color)
                        } else {
                            Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red], center: .center))
                        }
                        if accent == c {
                            Circle().fill(.white).frame(width: 6, height: 6)
                        }
                    }
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
                    .padding(2)
                    .overlay(Circle().strokeBorder(accent == c ? (c.color ?? .accentColor) : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .help(c == .none ? "System accent color" : c.title)
                .accessibilityLabel(c == .none ? "System accent color" : c.title)
                .accessibilityAddTraits(accent == c ? .isSelected : [])
            }
        }
    }
}

struct TextSizePicker: View {
    @Binding var size: UITextSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Text and icon size", selection: $size) {
                ForEach(UITextSize.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            // A sidebar row and a caption at the chosen size.
            HStack(spacing: 8) {
                Image(systemName: "server.rack").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("web-1").uiFont(.body)
                    Text("user@web-1.example.com").uiFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "terminal").uiFont(size: 12).foregroundStyle(.secondary)
            }
            .imageScale(size == .small ? .small : (size == .standard ? .medium : .large))
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
            .environment(\.uiScale, CGFloat(size.scale))
        }
    }
}

struct SidebarStylePicker: View {
    @Binding var style: SidebarStyle
    var accent: Color = .accentColor
    var columns = 3
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns), spacing: 12) {
            ForEach(SidebarStyle.allCases) { s in
                ChoiceCard(title: s.title, subtitle: s.summary, selected: style == s, action: { style = s }) {
                    SidebarSketch(style: s, dark: scheme == .dark, accent: accent, scale: 1)
                        .padding(6)
                        .frame(height: 104, alignment: .top)
                        .background(scheme == .dark ? Color(white: 0.21) : Color(white: 0.915))
                }
            }
        }
    }
}

struct ThemeGrid: View {
    let palettes: [TerminalPalette]
    @Binding var selection: TerminalPalette

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 10)], spacing: 10) {
            ForEach(palettes) { p in
                ChoiceCard(title: p.title, selected: selection == p, action: { selection = p }) {
                    ThemeSwatch(palette: p)
                }
            }
        }
    }
}

/// Where the terminal's colours come from, the light and dark themes and a live sample.
struct TerminalColorsPicker: View {
    @Binding var settings: AppSettings
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Terminal colors", selection: $settings.terminalColors) {
                ForEach(TerminalColorMode.allCases) { Text($0.title).tag($0) }
            }
            Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch settings.terminalColors {
            case .terminalApp:
                Picker("Terminal.app profile", selection: $settings.terminalProfile) {
                    Text("Default (\(TerminalAppProfile.defaultName ?? "Basic"))").tag("")
                    ForEach(TerminalAppProfile.availableNames(), id: \.self) { Text($0).tag($0) }
                }
                Toggle("Use the profile's font", isOn: $settings.fontFromProfile)
                TerminalSample(theme: TerminalTheme.resolve(settings, dark: scheme == .dark), fontName: settings.fontName)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            case .followApp:
                themeSection("Light theme", TerminalPalette.light, $settings.terminalLightTheme, dark: false)
                themeSection("Dark theme", TerminalPalette.dark, $settings.terminalDarkTheme, dark: true)
            case .alwaysLight:
                themeSection("Theme", TerminalPalette.light, $settings.terminalLightTheme, dark: false)
            case .alwaysDark:
                themeSection("Theme", TerminalPalette.dark, $settings.terminalDarkTheme, dark: true)
            }
        }
    }

    private var caption: String {
        switch settings.terminalColors {
        case .followApp: "The terminal turns light or dark with the app. Choose a theme for each."
        case .alwaysLight: "The terminal stays light, whether the app is light or dark."
        case .alwaysDark: "The terminal stays dark, whether the app is light or dark."
        case .terminalApp: "Colors, font and background translucency come from this Mac's Terminal settings. Programs on the server (ls, vim…) choose which of these colors to use."
        }
    }

    private func themeSection(_ title: String, _ palettes: [TerminalPalette], _ selection: Binding<TerminalPalette>, dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ThemeGrid(palettes: palettes, selection: selection)
            TerminalSample(theme: TerminalTheme.palette(selection.wrappedValue), fontName: settings.fontName)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
        }
    }
}
