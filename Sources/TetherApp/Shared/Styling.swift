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
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: size + 4, height: size + 4)
            case .waiting:
                TimelineView(.periodic(from: .now, by: 0.6)) { context in
                    let on = Int(context.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
                    Circle().fill(phase.tint.opacity(on ? 1 : 0.35)).frame(width: size, height: size)
                }
            case .suspended:
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: size + 3))
                    .foregroundStyle(phase.tint)
            case .dead:
                Circle().strokeBorder(phase.tint, lineWidth: 1.5).frame(width: size, height: size)
            case .online:
                Circle().fill(phase.tint).frame(width: size, height: size)
                    .shadow(color: phase.tint.opacity(0.6), radius: 3)
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
            .glassEffect(.regular, in: .capsule)
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
