import SwiftUI
import MonitorKit

struct LogsPanel: View {
    @Environment(AppModel.self) private var model
    let monitor: RemoteMonitor
    @State private var source: LogSource = .system
    @State private var customPath = ""
    @State private var filter = ""
    @State private var follow = false
    @State private var loading = false

    private var lines: [Substring] {
        let all = monitor.logText.split(separator: "\n", omittingEmptySubsequences: false)
        return filter.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(filter) }
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
            }
            .padding(10)

            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            Text(String(line))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .id(i)
                        }
                    }
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: monitor.logText) { _, _ in
                    if let last = lines.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
        .task(id: source) { load() }
        .task(id: follow) {
            while follow && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(max(model.settings.monitorRefreshInterval, 2)))
                await monitor.loadLogs(source, lines: model.settings.logLines)
            }
        }
    }

    private func load() {
        Task {
            loading = true
            await monitor.loadLogs(source, lines: model.settings.logLines)
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
