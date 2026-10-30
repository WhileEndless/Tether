import SwiftUI
import AppKit
import SessionKit
import TerminalUI

/// A find running inside one terminal (⌘F, or a match opened from the search window).
struct TerminalFind: Hashable {
    var term: String
    var regex = false
    var caseSensitive = false
    var wholeWord = false
    /// Scroll-invariant row to start at (a match picked in the search window).
    var anchorRow: Int?
    /// About where in the recording the match to start at is (a match in earlier output picked in
    /// the search window): shown in the history view.
    var earlierOffset: Int?
    /// Changed each time ⌘F is pressed, so the field takes the keyboard again.
    var focusToken = UUID()

    var query: TerminalFindQuery {
        TerminalFindQuery(term: term, isRegex: regex, caseSensitive: caseSensitive, wholeWord: wholeWord)
    }
}

/// Floating find bar over a terminal: the query, its options, "3 of 14" with where the match is
/// in the history, previous / next, close. The terminal draws the matches (`TetherTerminalView.setFind`).
struct TerminalFindBar: View {
    @Environment(AppModel.self) private var model
    let session: TerminalSession
    let find: TerminalFind
    @State private var status = TerminalFindStatus()
    @FocusState private var fieldFocused: Bool
    /// Bumped by every step, so stepping counts as use of the bar (see `autoDismiss`).
    @State private var steps = 0
    /// The search waiting for typing to pause (Settings ▸ Terminal ▸ Find in Terminal ▸ delay).
    /// Each change cancels the one before, so searches never pile up.
    @State private var pendingSearch: Task<Void, Never>?

    private var view: TetherTerminalView? { TerminalRegistry.shared.existingView(for: session.id) }

    private var term: Binding<String> {
        Binding { find.term } set: { value in edit { $0.term = value } }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find", text: term)
                .textFieldStyle(.plain)
                .font(.callout.monospaced().weight(.medium))
                .frame(width: 180)
                .focused($fieldFocused)
                .onSubmit { step(forward: !NSEvent.modifierFlags.contains(.shift)) }
                .onExitCommand { close() }
            HStack(spacing: 3) {
                OptionToggle(label: "Aa", help: "Match case", isOn: option(\.caseSensitive))
                OptionToggle(label: "W", help: "Whole words", isOn: option(\.wholeWord))
                OptionToggle(label: ".*", help: "Regular expression", isOn: option(\.regex))
            }
            counter
            Divider().frame(height: 14)
            // While earlier output is searched, a step waits for the first match there.
            Button { step(forward: false) } label: { Image(systemName: "chevron.up") }
                .help("Previous match (⇧⌘G or ⇧↩)")
                .disabled(status.total == 0 && !status.searchingRecording)
            Button { step(forward: true) } label: { Image(systemName: "chevron.down") }
                .help("Next match (⌘G or ↩)")
                .disabled(status.total == 0 && !status.searchingRecording)
            Button { close() } label: { Image(systemName: "xmark") }
                .help("Close (esc)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassBackground()
        // Matches under the bar are scrolled into sight (it floats over the terminal's top rows).
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { view?.findBarHeight = $0 + 10 }
        // Closes by itself once it has not been used for a while (Settings ▸ Terminal).
        .autoDismiss(after: model.settings.floatingBars.findBarHideAfter, activity: [AnyHashable(find), AnyHashable(steps)]) {
            close(focusTerminal: fieldFocused)
        }
        .onAppear {
            view?.onFindStatus = { status = $0 }
            view?.setFind(find.query, anchorRow: find.anchorRow, earlierOffset: find.earlierOffset)
            if find.anchorRow == nil, find.earlierOffset == nil { fieldFocused = true }
        }
        .onChange(of: find.query) { _, query in scheduleSearch(query) }
        .onDisappear { pendingSearch?.cancel() }
        .onChange(of: find.focusToken) { _, _ in fieldFocused = true }
        // Another match picked in the search window while the bar is open.
        .onChange(of: find.anchorRow) { _, row in if let row { view?.setFind(find.query, anchorRow: row) } }
        .onChange(of: find.earlierOffset) { _, offset in if let offset { view?.setFind(find.query, earlierOffset: offset) } }
        .onChange(of: model.terminalFindStep[session.id]) { _, _ in
            // Driven by Edit ▸ Find Next / Previous (⌘G, ⇧⌘G).
            if let forward = model.terminalFindStep[session.id]?.forward { step(forward: forward) }
        }
    }

    /// " 42 %" while the recording is searched (once that has started reading).
    private var percent: String {
        status.recordingProgress.map { " \(Int(($0 * 100).rounded())) %" } ?? ""
    }

    /// "3 of 14", "14 matches" before one is chosen, "No matches", or why the pattern is wrong.
    /// While earlier output is still searched: what was found so far ("3 of 14+", "14+ found"),
    /// with a small spinner and how far the search is.
    private var counter: some View {
        let text: String
        let color: Color
        if find.term.isEmpty {
            (text, color) = ("", .secondary)
        } else if status.invalidPattern {
            (text, color) = ("Invalid pattern", .red)
        } else if status.searchingRecording {
            let found = status.total > 0 ? "\(status.total.formatted())+" : ""
            let far = status.recordingProgress.map { " · \(Int(($0 * 100).rounded())) %" } ?? ""
            if status.current > 0 {
                (text, color) = ("\(status.current.formatted()) of \(found.isEmpty ? "…" : found)" + far, .primary)
            } else {
                (text, color) = ((found.isEmpty ? "Searching" : "\(found) found") + far, .secondary)
            }
        } else if status.total == 0 {
            (text, color) = ("No matches", .orange)
        } else {
            let total = status.total.formatted() + (status.limited ? "+" : "")
            (text, color) = status.current == 0 ? ("\(total) match\(status.total == 1 ? "" : "es")", .secondary)
                : ("\(status.current.formatted()) of \(total)", .primary)
        }
        return HStack(spacing: 4) {
            if status.searchingRecording && !find.term.isEmpty && !status.invalidPattern {
                ProgressView().controlSize(.mini)
                    .help("Searching earlier output" + percent)
                    .accessibilityLabel("Searching earlier output" + percent)
            }
            if status.recordingUnreadable && !status.searchingRecording {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Part of the earlier output could not be searched: it is encrypted and Tether is locked, or it was recorded with another key")
                    .accessibilityLabel("Part of the earlier output could not be searched")
            }
            if !text.isEmpty {
                Text(text)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(color == .primary ? .secondary : color)
                    .contentTransition(.numericText())
            }
        }
        .animation(.snappy(duration: 0.2), value: status)
        .lineLimit(1)
        .fixedSize()
    }

    private func option(_ key: WritableKeyPath<TerminalFind, Bool>) -> Binding<Bool> {
        Binding { find[keyPath: key] } set: { value in edit { $0[keyPath: key] = value } }
    }

    /// Changes this terminal's find in the model.
    private func edit(_ change: (inout TerminalFind) -> Void) {
        guard var f = model.terminalFind[session.id] else { return }
        change(&f)
        f.anchorRow = nil
        f.earlierOffset = nil
        model.terminalFind[session.id] = f
    }

    /// Searches once typing pauses; clearing the field clears the highlights at once.
    private func scheduleSearch(_ query: TerminalFindQuery) {
        pendingSearch?.cancel()
        pendingSearch = nil
        let delay = model.settings.findHighlight.searchDelay
        guard delay > 0, !query.term.isEmpty else { view?.setFind(query); return }
        pendingSearch = Task {
            try? await Task.sleep(for: .milliseconds(delay))
            guard !Task.isCancelled else { return }
            pendingSearch = nil
            view?.setFind(query)
        }
    }

    private func step(forward: Bool) {
        guard let view, !find.term.isEmpty else { return }
        // ↩ before the delay is over: search now (that already goes to the first match) — unless
        // the term shown is that one already (typed and taken back): then on to the next.
        if let pending = pendingSearch {
            pending.cancel()
            pendingSearch = nil
            if view.setFind(find.query) {
                steps += 1
                return
            }
        }
        FindPasteboard.set(find.term)
        view.findStep(forward: forward)
        steps += 1
    }

    private func close(focusTerminal: Bool = true) {
        view?.findBarHeight = 0
        view?.setFind(nil)
        view?.onFindStatus = nil
        model.terminalFind[session.id] = nil
        if focusTerminal, let view { view.window?.makeFirstResponder(view) }
    }

    private struct OptionToggle: View {
        let label: String
        let help: String
        @Binding var isOn: Bool
        var body: some View {
            Button { isOn.toggle() } label: {
                Text(label).font(.caption2.monospaced())
                    .padding(.horizontal, 4)
                    .foregroundStyle(isOn ? Color.primary : Color.secondary.opacity(0.7))
                    .background(Capsule().fill(Color.accentColor.opacity(isOn ? 0.2 : 0)))
            }
            .help(help)
        }
    }
}

/// The system-wide find string (⌘E, ⌘G in other apps), as macOS apps share it.
enum FindPasteboard {
    static func get() -> String? { NSPasteboard(name: .find).string(forType: .string) }
    static func set(_ text: String) {
        let pb = NSPasteboard(name: .find)
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
