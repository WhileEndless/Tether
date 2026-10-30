import AppKit
import Observation
import TetherCore
import SessionKit
import RecordingKit
import SearchKit
import FileTransferKit
import TerminalUI

/// Which sessions/transcripts a search covers.
struct SearchFilters: Equatable {
    /// When the searched sessions were active.
    enum DateRange: String, CaseIterable, Identifiable {
        case any = "Any time", last15m = "Last 15 minutes", lastHour = "Last hour", today = "Today",
             last24h = "Last 24 hours", week = "Last 7 days", month = "Last 30 days", custom = "Custom range…"
        var id: String { rawValue }

        var start: Date? {
            switch self {
            case .any, .custom: nil
            case .last15m: Date().addingTimeInterval(-15 * 60)
            case .lastHour: Date().addingTimeInterval(-3600)
            case .today: Calendar.current.startOfDay(for: Date())
            case .last24h: Date().addingTimeInterval(-86_400)
            case .week: Date().addingTimeInterval(-7 * 86_400)
            case .month: Date().addingTimeInterval(-30 * 86_400)
            }
        }
    }

    enum Status: String, CaseIterable, Identifiable {
        case any = "Any status", online = "Online", background = "Background", waiting = "Waiting", ended = "Ended"
        var id: String { rawValue }
    }

    var openSessions = true
    var archive = true
    var otherRecordings = false
    /// Recordings compressed after a few days are skipped unless asked for (they are slower to search).
    var includeCompressed = false
    /// Host key, or nil for all hosts.
    var host: String?
    /// Only this session (from "Search in Session…").
    var session: UUID?
    var status: Status = .any
    var dates: DateRange = .any
    /// Used when `dates == .custom`.
    var customFrom = Date().addingTimeInterval(-86_400)
    var customTo = Date()

    /// The selected period, or nil for "any time".
    var interval: (from: Date, to: Date)? {
        switch dates {
        case .any: nil
        case .custom: (min(customFrom, customTo), max(customFrom, customTo))
        default: dates.start.map { ($0, Date()) }
        }
    }

    /// Whether something active from `start` to `end` overlaps the selected period.
    func overlaps(start: Date?, end: Date?) -> Bool {
        guard let i = interval else { return true }
        let s = start ?? .distantPast, e = end ?? Date()
        return s <= i.to && e >= i.from
    }
}

/// Presets set by "Search on This Host…" / "Search in Session…".
struct SearchPreset: Equatable {
    var host: String?
    var session: UUID?
    var query: String?
}

/// A group of results from one source.
struct SearchResultGroup: Identifiable {
    var source: SearchSource
    var matches: [SearchMatch]
    var id: String { source.id }
}

@MainActor
@Observable
final class SearchModel {
    var query = SearchQuery(pattern: "")
    var filters = SearchFilters()
    private(set) var groups: [SearchResultGroup] = []
    /// Where the search for the current query stands. "No matches" is only true once `finished`.
    enum Phase { case idle, waiting, running, finished, stopped }
    private(set) var phase = Phase.idle
    /// A search is under way (or about to start for what was just typed).
    var running: Bool { phase == .running }
    var busy: Bool { phase == .waiting || phase == .running }
    private(set) var error: String?
    private(set) var searchedSources = 0
    /// Progress while running: index of the source being searched, and its name.
    private(set) var progressIndex = 0
    private(set) var progressTitle = ""
    private(set) var skippedCompressed = 0
    var selection = Set<SearchMatch.ID>()

    private var task: Task<Void, Never>?

    var totalMatches: Int { groups.reduce(0) { $0 + $1.matches.count } }

    func apply(_ preset: SearchPreset) {
        filters.host = preset.host
        filters.session = preset.session
        if let q = preset.query { query.pattern = q }
        if preset.session != nil { filters.archive = false; filters.otherRecordings = false }
    }

    /// The query or filters changed and a search starts in a moment: earlier results no longer
    /// count, and nothing says "no matches" before the new search has looked.
    func willRun() {
        task?.cancel()
        phase = query.pattern.isEmpty ? .idle : .waiting
    }

    /// Starts (or restarts) the search.
    func run() {
        task?.cancel()
        groups = []
        error = nil
        selection = []
        guard !query.pattern.isEmpty else { phase = .idle; return }
        do { _ = try query.makeRegex() } catch {
            self.error = error.localizedDescription
            phase = .finished
            return
        }
        let collected = collectSources()
        searchedSources = collected.sources.count
        progressIndex = 0
        progressTitle = ""
        phase = .running
        let q = query
        task = Task {
            do {
                // The disk is reached only from here: recordings of open sessions are written out
                // and other recordings are looked up in the background, never while typing.
                // What the recorders still keep in memory is searched with what is on disk: nothing
                // is written early for a search.
                var sources = collected.sources
                for session in collected.flush {
                    guard let snap = await session.currentRecording() else { continue }
                    for i in sources.indices where sources[i].id == "earlier-\(session.id)" { sources[i].pendingOutput = snap.pending }
                }
                try Task.checkCancellation()
                let (more, skipped) = await Task.detached(priority: .userInitiated) { collected.recordings() }.value
                try Task.checkCancellation()
                skippedCompressed += skipped
                sources += more
                searchedSources = sources.count
                for try await event in SearchEngine.events(q, in: sources) {
                    switch event {
                    case .searching(let index, _, let source):
                        progressIndex = index
                        progressTitle = "\(source.host) · \(source.title)"
                    case .found(let progress):
                        // A terminal's text was only needed to search it (the results keep the matches).
                        var source = progress.source
                        source.lines = nil
                        groups.append(SearchResultGroup(source: source, matches: progress.matches))
                    }
                }
                progressIndex = searchedSources
                phase = .finished
            } catch is CancellationError {
                // Restarted (the new run set the phase) or stopped (cancel did).
            } catch {
                self.error = error.localizedDescription
                phase = .finished
            }
        }
    }

    func cancel() {
        task?.cancel()
        if busy { phase = .stopped }
    }

    /// What a search looks through: open terminals' text (read here, on the main thread), and
    /// recordings, whose files are looked up in the background (`recordings()`).
    struct Collected: Sendable {
        var sources: [SearchSource] = []
        /// Sessions whose recording is searched: written out first.
        var flush: [TerminalSession] = []
        struct Archived: Sendable { var id: UUID; var path: String; var title, host: String; var date: Date? }
        var archived: [Archived] = []
        var usedRecordings = Set<String>()
        var otherRecordings = false
        var includeCompressed = false
        var host: String?
        var interval: (from: Date, to: Date)?

        /// Archived sessions' recordings and other recordings, with how many compressed ones were
        /// skipped. Touches the disk: called in the background.
        func recordings() -> ([SearchSource], Int) {
            var sources: [SearchSource] = []
            var skipped = 0
            var used = usedRecordings
            for a in archived {
                guard let url = RecordingStore.resolve(a.path) else { continue }
                if RecordingCompression.isCompressed(url) && !includeCompressed { skipped += 1; continue }
                sources.append(SearchSource(id: "archive-\(a.id)", kind: .recording(url: url, archiveID: a.id),
                                            title: a.title, host: a.host, date: a.date, status: "Ended"))
            }
            if otherRecordings {
                for r in RecordingStore.all() where !used.contains(r.url.path) {
                    used.insert(r.url.path)
                    if r.isCompressed && !includeCompressed { skipped += 1; continue }
                    if let host, RecordingStore.sanitize(host) != r.targetKey { continue }
                    if let interval, r.modified < interval.from { continue }
                    sources.append(SearchSource(id: "rec-\(r.url.path)", kind: .recording(url: r.url, archiveID: nil),
                                                title: "Recording \(r.modified.formatted(date: .abbreviated, time: .shortened))",
                                                host: r.targetKey, date: r.modified, status: "Recording"))
                }
            }
            return (sources, skipped)
        }
    }

    /// Gathers sources on the main thread (live terminal text must be read here; text of terminals
    /// that did not change since the last search is kept by the view).
    private func collectSources() -> Collected {
        let model = AppModel.shared
        var c = Collected()
        c.otherRecordings = filters.otherRecordings && filters.session == nil
        c.includeCompressed = filters.includeCompressed
        c.host = filters.host
        c.interval = filters.interval
        skippedCompressed = 0

        if filters.openSessions {
            for s in model.sessions.sessions {
                if let only = filters.session, s.id != only { continue }
                if let host = filters.host, s.descriptor.target.key != host { continue }
                if !filters.overlaps(start: s.startedAt, end: s.endedAt) { continue }
                let status = statusLabel(s)
                if !statusMatches(status) { continue }
                if let path = s.recordingURL?.path { c.usedRecordings.insert(path) }
                guard let view = TerminalRegistry.shared.existingView(for: s.id) else { continue }
                // A full-screen program (vim, less) is up: memory holds only its screen, so the
                // session's text all comes from the recording (without the program's screens).
                if view.showsAlternateScreen, let url = s.recordingURL {
                    c.flush.append(s)
                    c.sources.append(SearchSource(id: "earlier-\(s.id)", kind: .recording(url: url, archiveID: nil),
                                                  title: s.displayTitle, host: s.descriptor.target.displayName,
                                                  date: s.startedAt, status: status))
                    continue
                }
                let (base, lines, _) = view.scrollbackText()
                // Older output no longer in memory is searched in the session's recording.
                // Also lines a hidden tab let go of (they leave memory without being counted as trimmed).
                if base > 0 || view.hasOlderOutput, let url = s.recordingURL {
                    c.flush.append(s)
                    var earlier = SearchSource(id: "earlier-\(s.id)", kind: .recording(url: url, archiveID: nil),
                                               title: "\(s.displayTitle) — earlier output", host: s.descriptor.target.displayName,
                                               date: s.startedAt, status: status)
                    // Logical lines in memory (wrapped rows joined, empty rows below the cursor left out).
                    let memory = view.logicalText().lines
                    earlier.skipTrailingLines = memory.count
                    earlier.memoryHead = Array(memory.prefix(64))
                    c.sources.append(earlier)
                }
                c.sources.append(SearchSource(id: "live-\(s.id)", kind: .live(sessionID: s.id, lineBase: base),
                                              title: s.displayTitle, host: s.descriptor.target.displayName,
                                              date: s.startedAt, status: status, lines: lines))
            }
        }
        if filters.archive && filters.session == nil && (filters.status == .any || filters.status == .ended) {
            for a in model.sessions.archive {
                if let host = filters.host, a.target.key != host { continue }
                if !filters.overlaps(start: a.startedAt, end: a.endedAt) { continue }
                guard let path = a.recordingPath, !c.usedRecordings.contains(path) else { continue }
                c.usedRecordings.insert(path)
                c.usedRecordings.insert(path + "." + RecordingCompression.compressedExtension)
                c.archived.append(.init(id: a.id, path: path, title: a.title, host: a.target.displayName, date: a.endedAt))
            }
        }
        return c
    }

    private func statusLabel(_ s: TerminalSession) -> String {
        if AppModel.shared.sessions.background.contains(s.id) { return "Background" }
        switch s.phase {
        case .online, .connecting: return "Online"
        case .waiting, .suspended: return "Waiting"
        case .dead: return "Ended"
        }
    }

    private func statusMatches(_ label: String) -> Bool {
        switch filters.status {
        case .any: true
        case .online: label == "Online"
        case .background: label == "Background"
        case .waiting: label == "Waiting"
        case .ended: label == "Ended"
        }
    }

    // MARK: Selection helpers

    func match(_ id: SearchMatch.ID) -> (SearchSource, SearchMatch)? {
        for g in groups { if let m = g.matches.first(where: { $0.id == id }) { return (g.source, m) } }
        return nil
    }

    var selectedMatches: [(SearchSource, SearchMatch)] {
        groups.flatMap { g in g.matches.filter { selection.contains($0.id) }.map { (g.source, $0) } }
    }

    func copy(_ items: [(SearchSource, SearchMatch)], matchesOnly: Bool, context: Bool) {
        let text = items.map { _, m -> String in
            if matchesOnly { return m.matchedTexts.joined(separator: "\n") }
            return context ? (m.before + [m.text] + m.after).joined(separator: "\n") : m.text
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func export(format: SearchExport.Format, context: Bool, onlySelected: Bool) {
        var groups = self.groups.map { ($0.source, $0.matches) }
        if onlySelected {
            groups = groups.map { ($0.0, $0.1.filter { selection.contains($0.id) }) }.filter { !$0.1.isEmpty }
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "tether-search.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let list = groups.map { (source: $0.0, matches: $0.1) }
        // Rendered off the main thread and written whole (never half a file); a failure is shown.
        Task.detached(priority: .utility) {
            do {
                try Data(SearchExport.render(list, format: format, includeContext: context).utf8).write(to: url, options: [.atomic])
            } catch {
                _ = await MainActor.run { NSAlert(error: error).runModal() }
            }
        }
    }

    /// Saves the full plain text of every source with matches into a folder.
    func exportTranscripts() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        // Open terminals' text is read now, as it is.
        let sources = groups.map { group in
            var source = group.source
            if case .live(let id, _) = source.kind { source.lines = TerminalRegistry.shared.existingView(for: id)?.scrollbackText().lines ?? [] }
            return source
        }
        Task.detached {
            // Existing files are never replaced: a taken name becomes "name 2.txt".
            let names = sources.map { String((($0.host + " - " + $0.title).replacingOccurrences(of: "/", with: "-")).prefix(120)) + ".txt" }
            let free = LocalFiles.uniqueNames(in: dir, for: names)
            var failed: [String] = []
            for (s, name) in zip(sources, free) {
                do {
                    let lines: [String]
                    if let l = s.lines { lines = l }
                    else if case .recording(let url, _) = s.kind { lines = try SearchEngine.readLines(url) }
                    else { lines = [] }
                    try Data(lines.joined(separator: "\n").utf8).write(to: dir.appendingPathComponent(name), options: .withoutOverwriting)
                } catch {
                    failed.append("\(name): \(error.localizedDescription)")
                }
            }
            guard !failed.isEmpty else { return }
            let report = failed.prefix(10).joined(separator: "\n")
            _ = await MainActor.run {
                let alert = NSAlert()
                alert.messageText = "Some transcripts could not be exported"
                alert.informativeText = report
                alert.runModal()
            }
        }
    }
}
