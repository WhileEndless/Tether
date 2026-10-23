import SwiftUI
import TetherCore
import SessionKit

/// ⌘P: jump to any open or background session by typing part of its name or host.
struct SessionSwitcherView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var matches: [TerminalSession] {
        let all = model.sessions.sessions
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query)
                || $0.descriptor.target.displayName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack").foregroundStyle(.tint)
                TextField("Go to session", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(open)
                    .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(matches.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
            }
            .padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { i, s in
                            row(s, selected: i == highlighted)
                                .id(i)
                                .onTapGesture { highlighted = i; open() }
                        }
                        if matches.isEmpty {
                            Text("No sessions").foregroundStyle(.secondary).padding(20)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: highlighted) { _, v in proxy.scrollTo(v) }
            }
            .frame(height: 320)
        }
        .frame(width: 520)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onExitCommand { dismiss() }
    }

    private func row(_ s: TerminalSession, selected: Bool) -> some View {
        let background = model.sessions.background.contains(s.id)
        return HStack(spacing: 10) {
            StatusDot(phase: s.phase, size: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.displayTitle).fontWeight(.medium)
                Text("\(s.descriptor.target.displayName) · \(s.phase.label)\(background ? " · background" : "")")
                    .font(.caption)
                    .foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
            }
            Spacer()
        }
        .foregroundStyle(selected ? .white : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background { if selected { RoundedRectangle(cornerRadius: 8).fill(Color.accentColor) } }
        .contentShape(Rectangle())
    }

    private func open() {
        guard matches.indices.contains(highlighted) else { return }
        let s = matches[highlighted]
        dismiss()
        state.show(s)
    }
}
