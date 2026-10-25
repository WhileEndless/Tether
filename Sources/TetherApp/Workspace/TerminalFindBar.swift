import SwiftUI
import SwiftTerm
import SessionKit
import TerminalUI

/// A search running inside one terminal (started from the search window or ⌘F-style use).
struct TerminalFind: Equatable {
    var term: String
    var regex = false
    var caseSensitive = false
    var wholeWord = false

    var options: SearchOptions { SearchOptions(caseSensitive: caseSensitive, regex: regex, wholeWord: wholeWord) }
}

/// Floating find bar over a terminal: the query, "3 / 14", previous / next, close.
struct TerminalFindBar: View {
    @Environment(AppModel.self) private var model
    let session: TerminalSession
    let find: TerminalFind
    @State private var position = (index: 0, total: 0)

    private var view: TetherTerminalView? { TerminalRegistry.shared.existingView(for: session.id) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            Text(find.term)
                .font(.callout.monospaced().weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)
            if find.regex { Tag(".*") }
            if find.caseSensitive { Tag("Aa") }
            Text(position.total == 0 ? "no matches"
                 : position.index == 0 ? "\(position.total) match\(position.total == 1 ? "" : "es")"
                 : "\(position.index) / \(position.total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(position.total == 0 ? .orange : .secondary)
                .contentTransition(.numericText())
            Divider().frame(height: 14)
            Button { step(forward: false) } label: { Image(systemName: "chevron.up") }
                .help("Previous match (⇧⌘G)")
            Button { step(forward: true) } label: { Image(systemName: "chevron.down") }
                .help("Next match (⌘G)")
            Button { close() } label: { Image(systemName: "xmark") }
                .help("Close")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassBackground()
        .onAppear { refresh() }
        .onChange(of: model.terminalFindStep[session.id]) { _, _ in
            // Driven by Edit ▸ Find Next / Previous (⌘G, ⇧⌘G).
            if let forward = model.terminalFindStep[session.id]?.forward { step(forward: forward) }
        }
    }

    private func step(forward: Bool) {
        guard let view else { return }
        if forward { view.findNext(find.term, options: find.options) } else { view.findPrevious(find.term, options: find.options) }
        refresh()
    }

    private func refresh() {
        guard let view else { return }
        let r = view.searchMatchSummary(find.term, options: find.options)
        position = (r.index, r.total)
    }

    private func close() {
        view?.clearSearch()
        model.terminalFind[session.id] = nil
    }

    private struct Tag: View {
        let text: String
        init(_ text: String) { self.text = text }
        var body: some View {
            Text(text).font(.caption2.monospaced()).padding(.horizontal, 4)
                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
        }
    }
}
