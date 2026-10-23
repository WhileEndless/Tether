import SwiftUI
import TetherCore

/// Tether ▸ About Tether.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text(AppInfo.name).font(.title.weight(.semibold))
                Text("Version \(AppInfo.bundleVersion)").foregroundStyle(.secondary)
                Text("SSH sessions that survive the network.").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Link(destination: AppInfo.repository) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .buttonStyle(.glassProminent)
                Link(destination: AppInfo.issues) {
                    Label("Report an Issue", systemImage: "exclamationmark.bubble")
                }
                .buttonStyle(.glass)
            }
            Text(AppInfo.repository.absoluteString.replacingOccurrences(of: "https://", with: ""))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Divider()
            Text("MIT License · Terminal emulation by SwiftTerm")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 360)
    }
}
