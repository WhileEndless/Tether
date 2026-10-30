import SwiftUI
import TetherCore
import SessionKit
import SearchKit
import RecordingKit
import TerminalUI

/// ⇧⌘F: search every open terminal, the archive and old recordings.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var search = SearchModel()
    @State private var debounce: Task<Void, Never>?
    @AppStorage("search.contextHeight") private var contextHeight = 160.0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        @Bindable var search = search
        VStack(spacing: 0) {
            queryBar
            filterBar
            Divider()
            ResizablePane(axis: .vertical, size: $contextHeight, range: 100...480) {
                results
            } secondary: {
                ContextPane(search: search, open: open)
            }
            statusBar
        }
        .onAppear {
            fieldFocused = true
            if let preset = model.searchPreset { search.apply(preset); model.searchPreset = nil }
        }
        .onChange(of: model.searchPreset) { _, preset in
            if let preset { search.apply(preset); model.searchPreset = nil; search.run() }
        }
        .onChange(of: search.query) { _, _ in scheduleSearch() }
        .onChange(of: search.filters) { _, _ in scheduleSearch() }
        .navigationTitle("Search")
    }

    // MARK: Bars

    /// The prominent search field with its options.
    private var queryBar: some View {
        @Bindable var search = search
        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3.weight(.semibold))
                .foregroundStyle(fieldFocused ? Color.accentColor : .secondary)
            TextField(search.query.isRegex ? "Regular expression, e.g. fail(ed|ure)" : "Search all terminals…",
                      text: $search.query.pattern)
                .textFieldStyle(.plain)
                .font(.title2)
                .focused($fieldFocused)
                .onSubmit { search.run() }
            if search.busy {
                ProgressView().controlSize(.small)
            }
            if !search.query.pattern.isEmpty {
                Button { search.query.pattern = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear")
            }
            OptionToggle(label: ".*", help: "Regular expression", isOn: $search.query.isRegex, mono: true)
            OptionToggle(label: "Aa", help: "Match case", isOn: $search.query.caseSensitive)
            OptionToggle(label: "ab", help: "Whole words", isOn: $search.query.wholeWord, underline: true)
            Menu {
                ForEach([0, 1, 2, 3, 5, 10], id: \.self) { n in
                    Button("\(n) line\(n == 1 ? "" : "s") of context") { search.query.contextLines = n }
                }
            } label: {
                Text("±\(search.query.contextLines)").font(.callout.monospacedDigit())
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .help("Lines of context around each match")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(fieldFocused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: fieldFocused ? 2 : 1))
        .animation(.snappy(duration: 0.15), value: fieldFocused)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var filterBar: some View {
        @Bindable var search = search
        return HStack(spacing: 8) {
            Text("Search in").font(.caption).foregroundStyle(.secondary)
            ScopeChip(title: "Open sessions", symbol: "terminal", isOn: $search.filters.openSessions,
                      help: "Everything visible in open and background terminals")
            ScopeChip(title: "Archive", symbol: "archivebox", isOn: $search.filters.archive,
                      help: "Recordings of sessions that have ended")
            ScopeChip(title: "All recordings", symbol: "tray.full", isOn: $search.filters.otherRecordings,
                      help: "Older recordings that are no longer in the archive list")
            ScopeChip(title: "Compressed", symbol: "doc.zipper", isOn: $search.filters.includeCompressed,
                      help: "Recordings older than a few days are compressed. Searching them is slower.")
            Divider().frame(height: 16)
            Picker("Host", selection: $search.filters.host) {
                Text("All hosts").tag(String?.none)
                Text("This Mac").tag(String?.some("local"))
                ForEach(hostKeys, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Status", selection: $search.filters.status) {
                ForEach(SearchFilters.Status.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Time", selection: $search.filters.dates) {
                ForEach(SearchFilters.DateRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Only sessions that were active in this period")
            if search.filters.dates == .custom {
                DatePicker("From", selection: $search.filters.customFrom)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                Text("–").foregroundStyle(.secondary)
                DatePicker("To", selection: $search.filters.customTo)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
            if let id = search.filters.session, let s = model.sessions.session(id) {
                HStack(spacing: 4) {
                    Text("Only: \(s.displayTitle)").lineLimit(1)
                    Button { search.filters.session = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(.quaternary))
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    /// Shown before anything is typed: what can be searched and how.
    private var guide: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search every terminal at once").font(.headline)
            Text("Type text to find it in all open sessions and the archive. Results are grouped per session; double-click a line to jump to that exact place in the terminal.")
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow { Text(".*").font(.body.monospaced().weight(.semibold)); Text("Regular expressions, e.g. \(Text("fail(ed|ure)|timeout").font(.body.monospaced()))") }
                GridRow { Text("Aa").fontWeight(.semibold); Text("Match upper/lower case exactly") }
                GridRow { Text("ab").underline().fontWeight(.semibold); Text("Whole words only") }
                GridRow { Text("±2").font(.body.monospacedDigit().weight(.semibold)); Text("Lines of context shown around each match") }
                GridRow { Image(systemName: "line.3.horizontal.decrease.circle"); Text("Narrow by host, status and date; include the archive or compressed recordings") }
                GridRow { Image(systemName: "square.and.arrow.up"); Text("Copy lines or just the matches, or export results as text, CSV or JSON") }
            }
            .font(.callout)
        }
        .padding(24)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hostKeys: [String] {
        var keys = model.ordered(model.hosts).compactMap(\.alias)
        for s in model.sessions.sessions where !keys.contains(s.descriptor.target.key) && !s.descriptor.target.isLocal {
            keys.append(s.descriptor.target.key)
        }
        return keys
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            if search.phase == .waiting {
                ProgressView().controlSize(.mini)
                Text("Searching…")
            } else if search.running && search.searchedSources > 0 {
                ProgressView(value: Double(search.progressIndex), total: Double(max(search.searchedSources, 1)))
                    .frame(width: 140)
                Text("Searching \(min(search.progressIndex + 1, search.searchedSources)) of \(search.searchedSources) — \(search.progressTitle)"
                     + (search.totalMatches > 0 ? " · \(search.totalMatches) match\(search.totalMatches == 1 ? "" : "es") so far" : ""))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Stop") { search.cancel() }
            } else if let error = search.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if search.query.pattern.isEmpty {
                Text("Type to search \(model.sessions.sessions.count) open sessions and \(model.sessions.archive.count) archived ones.")
            } else {
                Text((search.phase == .stopped ? "Stopped · " : "") + "\(search.totalMatches) match\(search.totalMatches == 1 ? "" : "es") in \(search.groups.count) of \(search.searchedSources) sources"
                     + (search.skippedCompressed > 0 && !search.filters.includeCompressed
                        ? " · \(search.skippedCompressed) compressed skipped" : ""))
            }
            Spacer()
            Menu("Copy") {
                Button("Selected Lines") { search.copy(search.selectedMatches, matchesOnly: false, context: false) }
                Button("Selected Lines with Context") { search.copy(search.selectedMatches, matchesOnly: false, context: true) }
                Button("Matched Text Only (Selected)") { search.copy(search.selectedMatches, matchesOnly: true, context: false) }
                Divider()
                Button("All Matched Text") {
                    search.copy(search.groups.flatMap { g in g.matches.map { (g.source, $0) } }, matchesOnly: true, context: false)
                }
            }
            .fixedSize()
            .disabled(search.groups.isEmpty)
            Menu("Export") {
                ForEach(SearchExport.Format.allCases) { f in
                    Button("All Results as \(f.rawValue)…") { search.export(format: f, context: false, onlySelected: false) }
                }
                Button("All Results with Context…") { search.export(format: .text, context: true, onlySelected: false) }
                Button("Selected Results…") { search.export(format: .text, context: true, onlySelected: true) }
                    .disabled(search.selection.isEmpty)
                Divider()
                Button("Full Transcripts of Matching Sessions…") { search.exportTranscripts() }
            }
            .fixedSize()
            .disabled(search.groups.isEmpty)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: Results

    private var results: some View {
        @Bindable var search = search
        return List(selection: $search.selection) {
            ForEach(search.groups) { group in
                Section {
                    ForEach(group.matches) { m in
                        MatchRow(match: m)
                            .tag(m.id)
                            .contextMenu {
                                Button("Open at This Line") { open(group.source, m) }
                                Divider()
                                Button("Copy Line") { search.copy([(group.source, m)], matchesOnly: false, context: false) }
                                Button("Copy Match") { search.copy([(group.source, m)], matchesOnly: true, context: false) }
                                Button("Copy with Context") { search.copy([(group.source, m)], matchesOnly: false, context: true) }
                            }
                    }
                } header: {
                    GroupHeader(group: group) { if let m = group.matches.first { open(group.source, m) } }
                }
            }
        }
        .contextMenu(forSelectionType: SearchMatch.ID.self) { _ in
        } primaryAction: { ids in
            if let id = ids.first, let (source, match) = search.match(id) { open(source, match) }
        }
        .overlay {
            if search.query.pattern.isEmpty {
                guide
            } else if search.groups.isEmpty && search.error == nil {
                switch search.phase {
                case .waiting, .running:
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Searching…").font(.headline)
                        Text(search.running && search.searchedSources > 0
                             ? "Looking through \(min(search.progressIndex + 1, search.searchedSources)) of \(search.searchedSources) sources"
                             : "Gathering sessions and recordings")
                            .font(.callout).foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    .transition(.opacity)
                case .stopped:
                    EmptyStateView(symbol: "stop.circle", title: "Search Stopped", message: "Nothing was found before the search was stopped. Press ↩ to search again.")
                case .finished:
                    EmptyStateView(symbol: "text.magnifyingglass", title: "No Matches", message: "Try other filters or a different pattern.")
                case .idle:
                    EmptyView()
                }
            }
        }
    }

    // MARK: Actions

    private func scheduleSearch() {
        debounce?.cancel()
        search.willRun()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            search.run()
        }
    }

    /// Jumps to the match: the live terminal (scrolled and selected) or the transcript.
    private func open(_ source: SearchSource, _ match: SearchMatch) {
        switch source.kind {
        case .live(let sessionID, let base):
            guard let session = model.sessions.session(sessionID) else { return }
            if !model.workspaces.focus(sessionID) {
                // A background session: show it in a new window.
                let ws = UUID()
                model.workspaces.add(session.id, to: ws)
                openWindow(id: "workspace", value: ws)
            }
            let columns = match.ranges.first.map { $0.location..<($0.location + $0.length) }
            let q = search.query
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                TerminalRegistry.shared.existingView(for: sessionID)?.reveal(invariantRow: base + match.line, columns: columns)
                // Keep searching inside that terminal: its find bar steps through the other matches.
                model.terminalFind[sessionID] = TerminalFind(term: q.pattern, regex: q.isRegex,
                                                            caseSensitive: q.caseSensitive, wholeWord: q.wholeWord,
                                                            anchorRow: base + match.line)
            }
        case .recording(let url, let archiveID):
            // Earlier output of an open terminal: shown in that terminal, which browses its
            // recording from there (and its find bar steps through the matches).
            if source.id.hasPrefix("earlier-"), let id = UUID(uuidString: String(source.id.dropFirst("earlier-".count))),
               let offset = match.offset, let session = model.sessions.session(id),
               TerminalRegistry.shared.existingView(for: id)?.showsAlternateScreen != true {
                if !model.workspaces.focus(id) {
                    let ws = UUID()
                    model.workspaces.add(session.id, to: ws)
                    openWindow(id: "workspace", value: ws)
                }
                let q = search.query
                // The terminal shows it in its history view, with its find bar on the match (the find
                // picks it once it has searched the recording: `earlierOffset`).
                guard TerminalRegistry.shared.existingView(for: id)?.hasHistoryOnDisk == true else {
                    openTranscript(transcriptRequest(url: url, archiveID: archiveID, match: match), match: match, url: url)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    model.terminalFind[id] = TerminalFind(term: q.pattern, regex: q.isRegex, caseSensitive: q.caseSensitive,
                                                          wholeWord: q.wholeWord, earlierOffset: offset)
                }
                return
            }
            openTranscript(transcriptRequest(url: url, archiveID: archiveID, match: match), match: match, url: url)
        }
    }

    private func transcriptRequest(url: URL, archiveID: UUID?, match: SearchMatch) -> TranscriptRequest {
        TranscriptRequest(archiveID: archiveID, path: archiveID == nil ? url.path : nil, revealText: match.text, revealFraction: 0)
    }

    /// The transcript window at the match: where it is, as a share of the output, is worked out in
    /// the background (never by reading the recording here).
    private func openTranscript(_ request: TranscriptRequest, match: SearchMatch, url: URL) {
        Task {
            var r = request
            if let offset = match.offset {
                let length = await Task.detached { RecordingReader.length(of: url) }.value
                r.revealFraction = length > 0 ? min(Double(offset) / Double(length), 1) : 0
            }
            openWindow(id: "transcript", value: r)
        }
    }
}

private struct GroupHeader: View {
    @Environment(AppModel.self) private var model
    let group: SearchResultGroup
    let open: () -> Void

    var body: some View {
        let hostColor = model.metadata(for: group.source.host).color.color ?? Color.accentColor
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(hostColor).frame(width: 4, height: 18)
            Image(systemName: icon).foregroundStyle(hostColor)
            Text(group.source.title).fontWeight(.semibold).lineLimit(1)
            Text(group.source.host).foregroundStyle(.secondary).lineLimit(1)
            Text(group.source.status)
                .font(.caption2)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(statusColor.opacity(0.2)))
            if let d = group.source.date {
                Text(d, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(group.matches.count)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(Capsule().fill(hostColor.opacity(0.2)))
            Button("Open", action: open).buttonStyle(.borderless).font(.caption)
        }
    }

    private var icon: String {
        if case .live = group.source.kind { return "terminal" }
        return "archivebox"
    }

    private var statusColor: Color {
        switch group.source.status {
        case "Online": .green
        case "Waiting": .orange
        case "Background": .blue
        default: .secondary
        }
    }
}

/// One matching line with the matches highlighted.
private struct MatchRow: View {
    let match: SearchMatch

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(match.line + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
            Text(highlighted(match.text, match.ranges))
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

func highlighted(_ text: String, _ ranges: [NSRange]) -> AttributedString {
    var s = AttributedString(text)
    for r in ranges {
        guard let range = Range(r, in: text),
              let lower = AttributedString.Index(range.lowerBound, within: s),
              let upper = AttributedString.Index(range.upperBound, within: s) else { continue }
        s[lower..<upper].backgroundColor = .yellow.opacity(0.55)
        s[lower..<upper].foregroundColor = .black
        s[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
    }
    return s
}

/// Context of the selected match; text can be selected and copied freely.
private struct ContextPane: View {
    let search: SearchModel
    let open: (SearchSource, SearchMatch) -> Void

    var body: some View {
        if let id = search.selection.first, let (source, m) = search.match(id) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("\(source.title) — line \(m.line + 1)").font(.caption.weight(.semibold))
                    Spacer()
                    Button("Open at This Line") { open(source, m) }.font(.caption)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(m.before.enumerated()), id: \.offset) { i, l in
                            line(m.line - m.before.count + i, AttributedString(l), dim: true)
                        }
                        line(m.line, highlighted(m.text, m.ranges), dim: false)
                        ForEach(Array(m.after.enumerated()), id: \.offset) { i, l in
                            line(m.line + 1 + i, AttributedString(l), dim: true)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        } else {
            Text("Select a result to see the lines around it here. Double-click a result to open it in its terminal.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func line(_ n: Int, _ text: AttributedString, dim: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n + 1)").foregroundStyle(.tertiary).frame(width: 54, alignment: .trailing)
            Text(text).foregroundStyle(dim ? .secondary : .primary)
        }
        .font(.system(size: 12, design: .monospaced))
    }
}

/// A labelled on/off chip for search scopes.
private struct ScopeChip: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    let help: String

    var body: some View {
        Button { isOn.toggle() } label: {
            Label(title, systemImage: isOn ? "checkmark.circle.fill" : symbol)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(isOn ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1)))
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// An on/off option next to the search field (regex, case, whole word).
private struct OptionToggle: View {
    let label: String
    let help: String
    @Binding var isOn: Bool
    var mono = false
    var underline = false

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(label)
                .font(mono ? .callout.monospaced().weight(.semibold) : .callout.weight(.semibold))
                .underline(underline)
                .frame(width: 30, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? Color.accentColor : Color.secondary.opacity(0.12)))
                .foregroundStyle(isOn ? Color.white : .secondary)
        }
        .buttonStyle(.plain)
        .help(help + (isOn ? " (on)" : ""))
        .animation(.snappy(duration: 0.15), value: isOn)
    }
}
