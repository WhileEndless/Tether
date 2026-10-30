import SwiftUI
import UniformTypeIdentifiers
import SSHTransport

/// Help ▸ Connection Log: what happened to connections (sign-ins and how long they took, checks,
/// connections closed, tabs connecting, letting go and re-attaching, sleep and network events),
/// newest first, to read or copy into a bug report. Kept in memory only; passwords are never in it.
///
/// The bar at the top stays where it is whatever is shown below: what to show (everything,
/// notices and problems, problems), one host, one kind of event, words to look for.
struct ConnectionLogView: View {
    enum Severity: String, CaseIterable, Identifiable {
        case all, notices, problems
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .notices: "Notices"
            case .problems: "Problems"
            }
        }
        var lowest: ConnectionLog.Level {
            switch self {
            case .all: .info
            case .notices: .notice
            case .problems: .problem
            }
        }
    }

    @State private var entries: [ConnectionLog.Entry] = []
    @AppStorage("connectionLog.severity") private var severity: Severity = .all
    @State private var host: String?
    @State private var category: ConnectionLog.Category?
    @State private var search = ""
    @State private var expanded: Set<UUID> = []

    private var hosts: [String] { Array(Set(entries.compactMap(\.host))).sorted() }

    /// What the bar lets through, newest first.
    private var shown: [ConnectionLog.Entry] {
        let words = search.trimmingCharacters(in: .whitespaces)
        return entries.reversed().filter { e in
            e.level >= severity.lowest
                && (host == nil || e.host == host)
                && (category == nil || e.category == category)
                && (words.isEmpty || [e.message, e.host, e.tab, e.detail].contains { $0?.localizedCaseInsensitiveContains(words) == true })
        }
    }

    private var filtered: Bool { severity != .all || host != nil || category != nil || !search.isEmpty }

    var body: some View {
        let shown = self.shown
        VStack(spacing: 0) {
            bar(shown)
            Divider()
            if shown.isEmpty {
                empty
            } else {
                List(shown) { row($0) }
                    .listStyle(.inset)
            }
        }
        // The bar stays at the top however little is shown below it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            reload()
            ConnectionLog.shared.onChange = { DispatchQueue.main.async { ConnectionLogView.refreshSoon() } }
            ConnectionLogView.refresh = { reload() }
        }
        .onDisappear {
            ConnectionLog.shared.onChange = nil
            ConnectionLogView.refresh = nil
        }
    }

    // MARK: The bar

    private func bar(_ shown: [ConnectionLog.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Side by side when the window is wide enough, otherwise the menus go below: nothing
            // is ever wider than the window.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    severityPicker
                    filterMenus
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    severityPicker
                    HStack(spacing: 8) { filterMenus }
                }
            }
            HStack(spacing: 8) {
                TextField("Search", text: $search, prompt: Text("Search messages, hosts, tabs and ssh's words"))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 120, maxWidth: .infinity)
                Button("Copy") { copy(shown) }
                    .disabled(shown.isEmpty)
                    .help(filtered ? "Copies the events shown, oldest first" : "Copies every event, oldest first")
                Button("Save…") { save(shown) }
                    .disabled(shown.isEmpty)
                Button("Clear") {
                    ConnectionLog.shared.clear()
                    expanded = []
                    reload()
                }
                .disabled(entries.isEmpty)
            }
            .fixedSize(horizontal: false, vertical: true)
            Text(summary(shown))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var severityPicker: some View {
        Picker("Show", selection: $severity) {
            ForEach(Severity.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Notices: notices and problems")
    }

    /// Host and kind: menus that may be narrowed (a long host name is cut, not the window widened).
    @ViewBuilder private var filterMenus: some View {
        Picker("Host", selection: $host) {
            Text("All Hosts").tag(String?.none)
            if !hosts.isEmpty { Divider() }
            ForEach(hosts, id: \.self) { Text($0).tag(String?.some($0)) }
        }
        .labelsHidden()
        .frame(minWidth: 110, maxWidth: 240)
        Picker("Kind", selection: $category) {
            Text("All Events").tag(ConnectionLog.Category?.none)
            Divider()
            ForEach(ConnectionLog.Category.allCases, id: \.self) { Text($0.title).tag(ConnectionLog.Category?.some($0)) }
        }
        .labelsHidden()
        .frame(minWidth: 110, maxWidth: 180)
    }

    private func summary(_ shown: [ConnectionLog.Entry]) -> String {
        let problems = entries.filter { $0.level == .problem }.count
        let total = "\(entries.count) event\(entries.count == 1 ? "" : "s")" + (problems > 0 ? ", \(problems) problem\(problems == 1 ? "" : "s")" : "")
        let kept = "Tether keeps the last \(ConnectionLog.limit.formatted()) in memory while it runs."
        return (filtered ? "Showing \(shown.count) of \(total)." : total + ", newest first.") + " " + kept
    }

    @ViewBuilder private var empty: some View {
        if entries.isEmpty {
            ContentUnavailableView("Nothing yet", systemImage: "point.3.connected.trianglepath.dotted",
                                   description: Text("Sign-ins, connection checks and reconnects appear here while Tether runs."))
        } else {
            ContentUnavailableView {
                Label(severity == .problems && host == nil && category == nil && search.isEmpty ? "No problems" : "Nothing matches",
                      systemImage: severity == .problems ? "checkmark.circle" : "line.3.horizontal.decrease.circle")
            } description: {
                Text("\(entries.count) event\(entries.count == 1 ? " is" : "s are") hidden by what the bar above shows.")
            } actions: {
                Button("Show Everything") {
                    severity = .all
                    host = nil
                    category = nil
                    search = ""
                }
            }
        }
    }

    // MARK: Rows

    private func row(_ e: ConnectionLog.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: e.level == .problem ? "exclamationmark.triangle.fill" : e.level == .notice ? "info.circle.fill" : "circle.fill")
                .foregroundStyle(e.level == .problem ? .orange : e.level == .notice ? .blue : .secondary)
                .imageScale(e.level == .info ? .small : .medium)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(e.message)
                    .fontWeight(e.level == .info ? .regular : .medium)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(([time(e.date), e.host, e.tab, e.category.title] as [String?]).compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = e.detail { detailView(detail, id: e.id) }
            }
        }
        .padding(.vertical, 2)
    }

    /// ssh's or the server's words: the first lines, the rest on request.
    @ViewBuilder private func detailView(_ detail: String, id: UUID) -> some View {
        let lines = detail.split(separator: "\n", omittingEmptySubsequences: false)
        let open = expanded.contains(id)
        let shortLength = 4
        Text(open || lines.count <= shortLength ? detail : lines.prefix(shortLength).joined(separator: "\n"))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        if lines.count > shortLength {
            Button(open ? "Show less" : "Show all \(lines.count) lines") {
                if open { expanded.remove(id) } else { expanded.insert(id) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private func time(_ date: Date) -> String {
        let clock = date.formatted(.dateTime.hour().minute().second())
        return Calendar.current.isDateInToday(date) ? clock : date.formatted(date: .abbreviated, time: .omitted) + " " + clock
    }

    // MARK: Copy and save

    private func copy(_ shown: [ConnectionLog.Entry]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ConnectionLog.text(shown.reversed()), forType: .string)
    }

    private func save(_ shown: [ConnectionLog.Entry]) {
        let text = ConnectionLog.text(shown.reversed())
        let panel = NSSavePanel()
        panel.title = "Save Connection Log"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "Tether Connection Log \(Date().formatted(.iso8601.year().month().day())).txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.global(qos: .utility).async { try? Data(text.utf8).write(to: url, options: .atomic) }
        }
    }

    private func reload() { entries = ConnectionLog.shared.all }

    /// The open window's reload (one Connection Log window at a time).
    @MainActor static var refresh: (() -> Void)?
    @MainActor private static var refreshPending = false

    /// Events come in bursts (fifty tabs re-attaching): the list is read again at most five times a second.
    @MainActor static func refreshSoon() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            refreshPending = false
            refresh?()
        }
    }
}
