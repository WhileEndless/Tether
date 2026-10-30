import SwiftUI
import TetherCore

/// Where updating stands — checking, downloading, building, ready, failed — with its progress and
/// what can be done about it. In Settings ▸ General (compact) and the Software Update window.
struct UpdateStatusPanel: View {
    var compact = false

    var body: some View {
        let updater = Updater.shared
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title(updater.state)).fontWeight(compact ? .regular : .semibold)
                    if let detail = Self.detail(updater.state) {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if case .checking = updater.state { ProgressView().controlSize(.small) }
            }
            switch updater.state {
            case .downloading(_, let received, let total):
                if let total, total > 0 {
                    ProgressView(value: Double(received), total: Double(total))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            case .building(_, let progress, _):
                if let progress { ProgressView(value: progress) } else { ProgressView().progressViewStyle(.linear) }
            default:
                EmptyView()
            }
            HStack(spacing: 8) {
                buttons(updater)
            }
        }
    }

    @ViewBuilder private func buttons(_ updater: Updater) -> some View {
        switch updater.state {
        case .ready:
            Button("Restart to Update") { updater.restartToUpdate() }
                .keyboardShortcut(.defaultAction)
            Button("Show Log") { updater.showLog() }
        case .downloading, .building:
            Button("Cancel") { updater.stop() }
            Button("Show Log") { updater.showLog() }
        case .available(let r, _):
            if updater.installFolder != nil {
                Button("Download and Install") { updater.prepare(r) }
                    .keyboardShortcut(.defaultAction)
            }
            Button("Release Page") { NSWorkspace.shared.open(r.page) }
        case .failed(let r, _):
            Button("Try Again") { if let r { updater.prepare(r) } else { updater.check(userAsked: true) } }
            if r != nil { Button("Show Log") { updater.showLog() } }
            if let r { Button("Release Page") { NSWorkspace.shared.open(r.page) } }
        case .checking:
            Button("Check Now") {}.disabled(true)
        case .idle, .upToDate:
            Button("Check Now") { updater.check(userAsked: true) }
        }
        if compact, updater.available != nil || updater.installed != nil {
            Button("What's New…") { updater.showWindow() }
        }
    }

    static func title(_ state: Updater.State) -> String {
        switch state {
        case .idle: "Tether \(AppInfo.bundleVersion)"
        case .checking: "Checking for updates…"
        case .upToDate: "Tether \(AppInfo.bundleVersion) is the newest version"
        case .available(let r, _): "Tether \(r.version) is available"
        case .downloading(let r, _, _): "Downloading Tether \(r.version)…"
        case .building(let r, _, let step): "Tether \(r.version): \(step)"
        case .ready(let r): "Tether \(r.version) is ready to install"
        case .failed(let r, _): r.map { "Tether \($0.version) could not be prepared" } ?? "The check did not work"
        }
    }

    static func detail(_ state: Updater.State) -> String? {
        switch state {
        case .idle: "You have \(AppInfo.bundleVersion)."
        case .upToDate(let date): "Checked at \(date.formatted(date: .omitted, time: .shortened))."
        case .available(_, let reason): reason ?? "You have \(AppInfo.bundleVersion)."
        case .downloading(_, let received, let total):
            ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                + (total.map { " of " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
        case .building(_, let progress, _):
            (progress.map { "\(Int(($0 * 100).rounded())) % · " } ?? "")
                + "In the background at low priority; it takes a few minutes. You can keep working."
        case .ready: "It is installed when you quit Tether, or now with Restart to Update. Tabs in tmux or screen come back."
        case .failed(_, let why): why
        case .checking: nil
        }
    }
}

/// A release's notes (the Markdown of its GitHub release): headings, bullet points and paragraphs.
struct ReleaseNotesView: View {
    let markdown: String

    private enum Block: Hashable {
        case heading(String, level: Int)
        case bullet(String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                let level = line.prefix { $0 == "#" }.count
                out.append(.heading(line.dropFirst(level).trimmingCharacters(in: .whitespaces), level: level))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                out.append(.bullet(String(line.dropFirst(2))))
            } else if case .bullet(let text)? = out.last, raw.hasPrefix("  ") {
                out[out.count - 1] = .bullet(text + " " + line)   // a bullet continued on the next line
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return out
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if blocks.isEmpty {
                Text("This release has no notes.").foregroundStyle(.secondary)
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text, let level):
                    inline(text)
                        .font(level <= 1 ? .title3.weight(.semibold) : .headline)
                        .padding(.top, level <= 2 ? 6 : 2)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        inline(text).fixedSize(horizontal: false, vertical: true)
                    }
                case .paragraph(let text):
                    inline(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Help ▸ Check for Updates…: the update's state and progress, and what the new version brings —
/// or, the first time an updated Tether opens, what it brought.
struct UpdateWindow: View {
    /// Not from the environment: this window can open before (or without) any other.
    private var model: AppModel { AppModel.shared }

    var body: some View {
        let updater = Updater.shared
        @Bindable var store = model.settingsStore
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 8) {
                    if let installed = updater.installed {
                        Text("Tether was updated to \(installed.version)").font(.title3.weight(.semibold))
                        Text("Here is what changed. Tabs in tmux or screen came back as they were.")
                            .foregroundStyle(.secondary)
                    } else {
                        UpdateStatusPanel()
                    }
                }
            }
            .padding(16)
            Divider()
            ScrollView {
                if let notes = updater.installed?.notes ?? updater.available?.notes {
                    ReleaseNotesView(markdown: notes).padding(16)
                } else {
                    Text("When a new version is found, what it brings is shown here.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            HStack(spacing: 14) {
                Toggle("Check daily", isOn: $store.settings.checkForUpdates)
                Toggle("Download and install updates", isOn: $store.settings.installUpdatesAutomatically)
                    .onChange(of: store.settings.installUpdatesAutomatically) { _, on in if !on { updater.stop() } }
                Spacer(minLength: 0)
                if updater.installed != nil {
                    Button("Done") { updater.dismissWhatIsNew(); NSApp.keyWindow?.close() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onDisappear { updater.dismissWhatIsNew() }
    }
}
