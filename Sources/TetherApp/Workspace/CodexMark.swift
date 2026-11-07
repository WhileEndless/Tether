import SwiftUI

/// A compact, six-loop mark for Codex. SF Symbols has no OpenAI/Codex mark; this remains legible
/// at tab-icon size while making Codex distinct from the generic hexagon used before.
struct CodexMark: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                    .stroke(tint, style: StrokeStyle(lineWidth: max(size * 0.15, 1), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.42, height: size * 0.78)
                    .rotationEffect(.degrees(Double(index) * 60))
            }
        }
        .frame(width: size + 2, height: size + 2)
        .accessibilityLabel("Codex")
    }
}
