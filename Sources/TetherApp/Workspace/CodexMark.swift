import SwiftUI

/// An original, interlocking six-stroke mark for Codex. It is intentionally logo-like without
/// copying a vendor trademark, and keeps a clean silhouette at tab-icon size.
struct CodexMark: View {
    let size: CGFloat
    let tint: Color

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: max(size * 0.19, 1.5), height: size * 0.72)
                    .offset(y: -size * 0.11)
                    .rotationEffect(.degrees(Double(index) * 60))
            }
            Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: size * 0.22, height: size * 0.22)
        }
        .frame(width: size + 2, height: size + 2)
        .accessibilityLabel("Codex")
    }
}
