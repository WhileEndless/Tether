import SwiftUI
import TetherCore
import SSHConfigKit

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    @State private var appeared = false

    var body: some View {
        // The ScrollView keeps the welcome content's minimum size independent of its width,
        // which avoids a layout feedback loop with the inspector column.
        ScrollView {
            content.frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { appeared = true } }
    }

    private var content: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .uiFont(size: 54, weight: .light)
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, value: appeared)
                Text("Tether").uiFont(.largeTitle, weight: .semibold)
                Text("Sessions that survive the network.")
                    .foregroundStyle(.secondary)
            }
            .scaleEffect(appeared ? 1 : 0.92)
            .opacity(appeared ? 1 : 0)

            HStack(spacing: 12) {
                Button {
                    state.showQuickConnect = true
                } label: {
                    Label("New Connection", systemImage: "bolt.fill").padding(.horizontal, 12)
                }
                .prominentGlassButtonStyle()
                .controlSize(.large)

                Button {
                    state.connect(.local)
                } label: {
                    Label("Local Terminal", systemImage: "laptopcomputer").padding(.horizontal, 12)
                }
                .glassButtonStyle()
                .controlSize(.large)

                Button {
                    model.openSearch?()
                } label: {
                    Label("Search", systemImage: "text.magnifyingglass").padding(.horizontal, 12)
                }
                .glassButtonStyle()
                .controlSize(.large)
                .help("Search every session and the archive (⇧⌘F)")

                Button {
                    state.hostEditor = HostEditorRequest()
                } label: {
                    Label("Add Host", systemImage: "plus").padding(.horizontal, 12)
                }
                .glassButtonStyle()
                .controlSize(.large)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)

            footer
                .opacity(appeared ? 1 : 0)

            if !recentHosts.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hosts").uiFont(.headline).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                        ForEach(Array(recentHosts.enumerated()), id: \.element.id) { index, host in
                            HostCard(host: host)
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 16)
                                .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.05 * Double(index)), value: appeared)
                        }
                    }
                }
                .frame(maxWidth: 720)
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 80)
        .padding(.bottom, 24)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("Version \(AppInfo.bundleVersion)")
            Text("·")
            Link(destination: AppInfo.repository) {
                Label("github.com/WhileEndless/tether", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Text("·")
            Link("Report an Issue", destination: AppInfo.issues)
        }
        .uiFont(.caption)
        .foregroundStyle(.secondary)
    }

    private var recentHosts: [SSHHostEntry] {
        let favs = model.hosts.filter { $0.alias.map { model.metadata(for: $0).favorite } ?? false }
        return Array((favs + model.hosts.filter { !favs.contains($0) }).prefix(12))
    }
}

struct HostCard: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let host: SSHHostEntry
    @State private var hovering = false

    var body: some View {
        Button {
            if let a = host.alias { state.connect(.alias(a)) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "terminal")
                    .uiFont(.title3)
                    .foregroundStyle(model.metadata(for: host.alias ?? "").color.color ?? .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.alias ?? "").fontWeight(.medium).lineLimit(1)
                    Text(host.hostName ?? "").uiFont(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .glassBackground(cornerRadius: 14, interactive: true)
        .scaleEffect(hovering ? 1.03 : 1)
        .animation(.snappy, value: hovering)
        .onHover { hovering = $0 }
    }
}
