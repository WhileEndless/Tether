import SwiftUI
import TetherCore
import TerminalUI

/// First launch (no saved settings) and Settings ▸ Appearance ▸ Set Up Appearance Again: a few
/// steps that ask how Tether should look. Every choice applies at once, so the app behind the
/// window already shows it; everything can be changed later in Settings ▸ Appearance.
struct AppearanceSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.colorScheme) private var scheme
    // TETHER_DEMO_SETUP_STEP opens a later step (screenshots of the setup).
    @State private var step: Step = AppPaths.debugOverride("TETHER_DEMO_SETUP_STEP").flatMap { Int($0) }
        .flatMap(Step.init(rawValue:)) ?? .welcome

    enum Step: Int, CaseIterable {
        case welcome, window, sidebar, terminal, done
    }

    var body: some View {
        @Bindable var store = model.settingsStore
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    content(settings: $store.settings)
                }
                .padding(.horizontal, 36)
                .padding(.top, 28)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            footer
        }
        .frame(width: 720, height: 640)
        .background(.background)
        .animation(.smooth(duration: 0.25), value: step)
        .onChange(of: model.settings) { _, _ in model.settingsChanged() }
        // Seen once is enough, also when every default was kept.
        .onDisappear { store.save() }
    }

    // MARK: Parts

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if step != .welcome && step != .done {
                Text("Step \(step.rawValue) of 3")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tint)
                    .textCase(.uppercase)
            }
            Text(title).font(.largeTitle.weight(.semibold))
            Text(subtitle).font(.title3).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        switch step {
        case .welcome: "Welcome to Tether"
        case .window: "Light or dark?"
        case .sidebar: "Your sidebar"
        case .terminal: "Terminal colors"
        case .done: "All set"
        }
    }

    private var subtitle: String {
        switch step {
        case .welcome: "Choose how Tether looks in a few steps. Each choice shows right away, and you can change everything later in Settings ▸ Appearance."
        case .window: "The window follows your Mac, or stays light or dark. Pick an accent color for selections and buttons."
        case .sidebar: "From everything at a glance to names only. Pick the layout and the size of text and icons."
        case .terminal: "The terminal has its own colors: keep it dark in a light window, or let it follow the window."
        case .done: "Tether looks the way you chose. Settings ▸ Appearance has all of these, and more."
        }
    }

    @ViewBuilder
    private func content(settings: Binding<AppSettings>) -> some View {
        let s = settings.wrappedValue
        let accent = s.accentColor.color ?? .accentColor
        switch step {
        case .welcome:
            WindowSketch(dark: scheme == .dark, accent: accent, style: s.sidebarStyle,
                         terminal: TerminalTheme.resolve(s, dark: scheme == .dark))
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
                .padding(.top, 8)
        case .window:
            VStack(alignment: .leading, spacing: 22) {
                AppearanceModePicker(settings: settings)
                    .frame(height: 120)
                labeled("Accent color") { AccentPicker(accent: settings.accentColor) }
            }
        case .sidebar:
            VStack(alignment: .leading, spacing: 22) {
                SidebarStylePicker(style: settings.sidebarStyle, accent: accent)
                labeled("Text and icon size") { TextSizePicker(size: settings.uiTextSize).labelsHidden() }
            }
        case .terminal:
            VStack(alignment: .leading, spacing: 16) {
                TerminalColorsPicker(settings: settings)
                labeled("Font size") {
                    Stepper("\(Int(s.fontSize)) pt", value: settings.fontSize, in: 8...40)
                        .disabled(s.terminalColors == .terminalApp && s.fontFromProfile)
                }
            }
        case .done:
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 24) {
                    WindowSketch(dark: scheme == .dark, accent: accent, style: s.sidebarStyle,
                                 terminal: TerminalTheme.resolve(s, dark: scheme == .dark))
                        .frame(width: 320, height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                        summary("Window", s.appearance.title, step: .window)
                        summary("Accent", s.accentColor == .none ? "System" : s.accentColor.title, step: .window)
                        summary("Sidebar", s.sidebarStyle.title, step: .sidebar)
                        summary("Text size", s.uiTextSize.title, step: .sidebar)
                        summary("Terminal", terminalSummary(s), step: .terminal)
                    }
                }
                Text("⌥⌘+ and ⌥⌘− change the size of text and icons; ⌘+ and ⌘− the terminal's font. The View menu switches the sidebar style.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func terminalSummary(_ s: AppSettings) -> String {
        switch s.terminalColors {
        case .followApp: "\(s.terminalLightTheme.title) / \(s.terminalDarkTheme.title)"
        case .alwaysLight: s.terminalLightTheme.title
        case .alwaysDark: s.terminalDarkTheme.title
        case .terminalApp: "Terminal.app profile"
        }
    }

    private func summary(_ label: String, _ value: String, step target: Step) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
            Button("Change") { step = target }.buttonStyle(.link).font(.callout)
        }
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step != .done {
                Button("Skip") { finish() }
                    .help("Keep the defaults; Settings ▸ Appearance has every option")
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Circle().fill(s == step ? Color.accentColor : Color.primary.opacity(0.18))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)
            Spacer()
            if step != .welcome {
                Button("Back") { move(-1) }
            }
            Button(step == .done ? "Start Using Tether" : (step == .welcome ? "Get Started" : "Continue")) {
                step == .done ? finish() : move(1)
            }
            .keyboardShortcut(.defaultAction)
            .prominentGlassButtonStyle()
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func move(_ by: Int) {
        if let next = Step(rawValue: step.rawValue + by) { step = next }
    }

    private func finish() {
        model.settingsStore.save()
        dismissWindow(id: "setup")
    }
}
