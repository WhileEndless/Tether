import SwiftUI
import MonitorKit

struct LogsPanel: View {
    @Environment(AppModel.self) private var model
    let monitor: RemoteMonitor
    @State private var source: LogSource = .system
    @AppStorage("logs.level") private var level: LogLevel = .all
    @State private var customPath = ""
    @State private var filter = ""
    @State private var follow = false
    @State private var loading = false

    /// Split and filtered when the log or the filter changes, not on every redraw.
    @State private var lines: [Substring] = []
    @State private var newText = 0

    private func updateLines() {
        let all = monitor.logText.split(separator: "\n", omittingEmptySubsequences: false)
        lines = filter.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Picker("Source", selection: $source) {
                        // Windows: the System, Security and Application event logs.
                        ForEach(LogSource.allCases) { s in
                            Text(monitor.platform?.isWindows == true ? WindowsProbeScripts.logName(s) : s.title).tag(s)
                        }
                        Text("File…").tag(LogSource.file(customPath))
                    }
                    .labelsHidden()
                    Picker("Level", selection: $level) {
                        ForEach(LogLevel.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(minWidth: 70, maxWidth: 170)
                    .help("Chosen on the server: Errors brings the last errors, not the errors among the last lines")
                    Toggle("Follow", isOn: $follow).toggleStyle(.switch).controlSize(.small)
                    Button { load() } label: {
                        Image(systemName: "arrow.clockwise").rotationEffect(.degrees(loading ? 360 : 0))
                            .animation(loading ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: loading)
                    }
                    .buttonStyle(.borderless)
                }
                if case .file = source {
                    TextField("/var/log/nginx/error.log", text: $customPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { source = .file(customPath); load() }
                }
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            Divider()

            if lines.allSatisfy({ $0.allSatisfy(\.isWhitespace) }) {
                ContentUnavailableView(loading ? "Loading…" : emptyTitle, systemImage: level == .all ? "doc.text" : "checkmark.circle",
                                       description: Text(loading ? "" : emptyDescription))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 24)
            } else {
                ScrollViewReader { proxy in
                    // A few lines sit at the top left, as in any text view (a scroll view centres
                    // content smaller than itself).
                    GeometryReader { geo in
                        ScrollView([.vertical, .horizontal]) {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                                    Text(String(line))
                                        .uiFont(size: 11, design: .monospaced)
                                        .foregroundStyle(color(for: line))
                                        .textSelection(.enabled)
                                        .id(i)
                                }
                            }
                            .padding(8)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                        }
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: newText) { _, _ in
                        if let last = lines.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { updateLines() }
        .onChange(of: filter) { _, _ in updateLines() }
        .onChange(of: monitor.logText) { _, _ in
            updateLines()
            newText += 1   // the newest lines are at the bottom: shown
        }
        .task(id: LoadKey(source: source, level: level)) { load() }
        .task(id: follow) {
            while follow && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(model.settings.monitorRefreshInterval, 2)))
                // No window visible: skipped.
                if !monitor.paused { await monitor.loadLogs(source, lines: model.settings.logLines, level: level) }
            }
        }
    }

    private struct LoadKey: Hashable {
        var source: LogSource
        var level: LogLevel
    }

    private var summary: String {
        let count = lines.filter { !$0.allSatisfy(\.isWhitespace) }.count
        let what = level == .all ? "the last \(model.settings.logLines) lines" : "the last \(model.settings.logLines) \(level == .errors ? "errors" : "warnings and errors")"
        return "\(count) line\(count == 1 ? "" : "s") shown" + (filter.isEmpty ? "" : " (filtered)")
            + " · asked the server for \(what) · Settings ▸ Monitoring sets how many"
    }

    private var emptyTitle: String {
        if !filter.isEmpty { return "Nothing matches the filter" }
        switch level {
        case .all: return "No log lines"
        case .warnings: return "No warnings or errors"
        case .errors: return "No errors"
        }
    }

    private var emptyDescription: String {
        if let error = monitor.logError { return error }
        return level == .all ? "The server sent nothing for this log." : "The server found none in this log."
    }

    private func load() {
        Task {
            loading = true
            await monitor.loadLogs(source, lines: model.settings.logLines, level: level)
            loading = false
        }
    }

    private func color(for line: Substring) -> Color {
        let l = line.lowercased()
        if l.contains("error") || l.contains("fail") || l.contains("crit") || l.contains("panic") { return .red }
        if l.contains("warn") { return .orange }
        return .primary
    }
}
