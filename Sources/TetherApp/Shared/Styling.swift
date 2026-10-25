import SwiftUI
import TetherCore

extension TagColor {
    var color: Color? {
        switch self {
        case .none: nil
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }

    var title: String { self == .none ? "None" : rawValue.capitalized }
}

extension SessionPhase {
    var tint: Color {
        switch self {
        case .connecting: .secondary
        case .online: .green
        case .waiting: .orange
        case .suspended: .blue
        case .dead: .red
        }
    }
}

/// Small status light. Blinks while waiting, spins while connecting.
/// The blink ticks twice a second instead of animating every frame, so many dots stay cheap.
struct StatusDot: View {
    let phase: SessionPhase
    var size: CGFloat = 8

    var body: some View {
        ZStack {
            switch phase {
            case .connecting:
                // A static ring: a spinner in every tab and sidebar row while many sessions connect
                // means dozens of animations redrawing at once.
                Circle().trim(from: 0, to: 0.7)
                    .stroke(phase.tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: size + 1, height: size + 1)
            case .waiting:
                // Static (a blinking dot redraws every row that shows it, for as long as it waits).
                Circle().strokeBorder(phase.tint, lineWidth: 1.5)
                    .background(Circle().fill(phase.tint.opacity(0.35)).padding(2.5))
                    .frame(width: size, height: size)
            case .suspended:
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: size + 3))
                    .foregroundStyle(phase.tint)
            case .dead:
                Circle().strokeBorder(phase.tint, lineWidth: 1.5).frame(width: size, height: size)
            case .online:
                // A soft ring instead of a shadow: shadows are blurred in software on every redraw.
                Circle().fill(phase.tint).frame(width: size, height: size)
                    .background(Circle().fill(phase.tint.opacity(0.25)).frame(width: size + 4, height: size + 4))
            }
        }
        .frame(width: size * 2, height: size * 2)
        .animation(.smooth, value: phase)
        .accessibilityLabel(phase.label)
    }
}

extension Int64 {
    var byteString: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false   // "0 bytes", not "Zero KB"
        return f.string(fromByteCount: self)
    }
}

extension Double {
    /// "1.2 MB/s" for a bytes-per-second value.
    var rateString: String {
        self < 1 ? "0 B/s" : ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file) + "/s"
    }
}

extension TimeInterval {
    /// "0:42", "12:04", "1:02:03", "2d 3:04:05" — a running time, like a stopwatch.
    var clockString: String {
        let s = Int(max(self, 0))
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60, sec = s % 60
        let hms = h > 0 || d > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
        return d > 0 ? "\(d)d \(hms)" : hms
    }

    var uptimeString: String {
        let s = Int(self)
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

/// A glass capsule used for floating status pills.
struct GlassPill<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassBackground()
    }
}

// MARK: Newer SwiftUI, with a fallback for earlier macOS

extension View {
    /// A symbol that wiggles when `value` changes (macOS 15); it bounces on earlier systems.
    @ViewBuilder func wiggleEffect<V: Equatable>(value: V) -> some View {
        if #available(macOS 15, *) { symbolEffect(.wiggle, value: value) } else { symbolEffect(.bounce, value: value) }
    }

    /// Reports how far a horizontal scroll view is scrolled: SwiftUI's scroll geometry on macOS 15,
    /// the enclosing NSScrollView's position on earlier systems.
    @ViewBuilder func onHorizontalScroll(_ action: @escaping (CGFloat) -> Void) -> some View {
        if #available(macOS 15, *) {
            onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in action(x) }
        } else {
            background(ScrollOffsetReader(action: action))
        }
    }
}

/// Watches the NSScrollView it is placed in (macOS 14, for `onHorizontalScroll`).
private struct ScrollOffsetReader: NSViewRepresentable {
    let action: (CGFloat) -> Void
    func makeNSView(context: Context) -> Reader { Reader() }
    func updateNSView(_ view: Reader, context: Context) { view.action = action }

    final class Reader: NSView {
        var action: ((CGFloat) -> Void)?
        private var observer: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            guard window != nil, let clip = enclosingScrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                let x = clip.bounds.origin.x
                MainActor.assumeIsolated { self?.action?(x) }
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: Liquid Glass, with a look for earlier macOS

/// Tether runs on macOS 14.4 and later. Liquid Glass (macOS 26) is used where it exists; earlier
/// systems get the standard look in its place (bordered buttons, a material background). Built with
/// an SDK before macOS 26 (Xcode 16), the glass code is left out.
extension View {
    /// The main button of a view (`.glassProminent` on macOS 26).
    @ViewBuilder func prominentGlassButtonStyle() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
        #else
        buttonStyle(.borderedProminent)
        #endif
    }

    /// A secondary button (`.glass` on macOS 26).
    @ViewBuilder func glassButtonStyle() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) { buttonStyle(.glass) } else { buttonStyle(.bordered) }
        #else
        buttonStyle(.bordered)
        #endif
    }

    /// A floating glass background: a capsule, or a rounded rectangle with `cornerRadius`.
    @ViewBuilder func glassBackground(cornerRadius: CGFloat? = nil, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            if let cornerRadius {
                glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: cornerRadius))
            } else {
                glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
            }
        } else {
            materialBackground(cornerRadius: cornerRadius)
        }
        #else
        materialBackground(cornerRadius: cornerRadius)
        #endif
    }

    @ViewBuilder private func materialBackground(cornerRadius: CGFloat?) -> some View {
        if let cornerRadius {
            background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator.opacity(0.6)))
        } else {
            background(.regularMaterial, in: .capsule)
                .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
        }
    }
}

/// Placeholder for empty panes.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// This Mac's network name, as shown in the sidebar and host panel.
var localMachineName: String {
    #if DEBUG
    if let demo = DemoMode.localMachineName { return demo }
    #endif
    return ProcessInfo.processInfo.hostName
}
