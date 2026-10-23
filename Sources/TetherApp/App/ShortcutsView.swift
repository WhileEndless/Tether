import SwiftUI

/// Help ▸ Keyboard Shortcuts: every shortcut, grouped and searchable.
struct ShortcutsView: View {
    @State private var filter = ""
    var compact = false

    private var groups: [(Shortcut.Category, [Shortcut])] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return Shortcut.Category.allCases.compactMap { c in
            let items = Shortcut.all.filter { s in
                s.category == c && (q.isEmpty || s.title.lowercased().contains(q) || s.display.lowercased().contains(q)
                                    || (s.note?.lowercased().contains(q) ?? false))
            }
            return items.isEmpty ? nil : (c, items)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter shortcuts", text: $filter).textFieldStyle(.plain)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
            .padding(compact ? 0 : 12)
            .padding(.bottom, compact ? 8 : 0)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(groups, id: \.0) { category, items in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(category.rawValue, systemImage: category.symbol)
                                .font(.headline)
                                .foregroundStyle(Color.accentColor)
                                .padding(.bottom, 2)
                            ForEach(items) { ShortcutRow(shortcut: $0) }
                        }
                    }
                    if groups.isEmpty {
                        Text("No shortcuts match \u{201C}\(filter)\u{201D}.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, compact ? 0 : 16)
                .padding(.bottom, 12)
            }
            if !compact {
                Divider()
                HStack {
                    Text("Keys without ⌘ always go to the terminal. Menu shortcuts can be changed in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ App Shortcuts.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open…") { Self.openSystemShortcuts() }
                }
                .padding(12)
            }
        }
    }

    static func openSystemShortcuts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct ShortcutRow: View {
    let shortcut: Shortcut

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(shortcut.title)
                if let note = shortcut.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                ForEach(Array(shortcut.display.components(separatedBy: "  ").enumerated()), id: \.offset) { _, part in
                    Text(part)
                        .font(.callout.monospaced())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.14)))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.25)))
                }
            }
            .fixedSize()
        }
        .padding(.vertical, 3)
    }
}
