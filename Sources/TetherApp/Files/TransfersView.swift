import SwiftUI
import FileTransferKit

struct TransfersView: View {
    @Environment(AppModel.self) private var model

    private var summary: String {
        let items = model.transfers.items
        let running = items.filter { $0.state == .running }.count
        let queued = items.filter { $0.state == .queued }.count
        let preparing = model.transfers.preparations.count
        if running + queued + preparing == 0 { return items.isEmpty ? "" : "All done" }
        return "\(running) running" + (queued > 0 ? " · \(queued) queued" : "") + (preparing > 0 ? " · \(preparing) preparing" : "")
            + " · \(model.transfers.policy.parallel) at a time"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Transfers").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.transfers.activeCount > 0 {
                    Button("Cancel All") { model.transfers.cancelAll() }
                }
                Button("Clear Finished") { withAnimation { model.transfers.clearFinished() } }
                    .disabled(!model.transfers.items.contains { $0.isFinished })
            }
            .padding(12)
            Divider()
            if model.transfers.items.isEmpty && model.transfers.preparations.isEmpty {
                EmptyStateView(symbol: "arrow.up.arrow.down", title: "No Transfers",
                               message: "Drop files on a terminal or the file manager to upload them.")
                    .frame(height: 180)
            } else {
                // As tall as the rows need, scrolling only beyond the maximum height.
                ViewThatFits(in: .vertical) {
                    rows
                    ScrollView { rows }
                }
                .frame(maxHeight: Self.maxListHeight)
            }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.snappy(duration: 0.25), value: model.transfers.items.map(\.id))
    }

    static let maxListHeight: CGFloat = 520

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(model.transfers.preparations) { prep in
                PreparationRow(prep: prep)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Divider().padding(.leading, 46)
            }
            ForEach(model.transfers.items) { item in
                TransferRow(item: item)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))))
                if item.id != model.transfers.items.last?.id { Divider().padding(.leading, 46) }
            }
        }
    }
}

struct TransferRow: View {
    @Environment(AppModel.self) private var model
    let item: TransferItem
    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: item.state == .completed)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    if item.method == .archive {
                        Text("ONE STREAM")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                            .help("Packed with tar and unpacked on the other side in a single stream")
                    }
                }
                route
                status
                if let note = item.note {
                    Text(note).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
                if item.entries.count > 1 {
                    DisclosureGroup(isExpanded: $expanded) {
                        EntryList(entries: item.entries)
                    } label: {
                        Text("\(item.entries.count) items").font(.caption)
                    }
                }
            }
            Spacer(minLength: 4)
            actions
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Destination Path\(item.entries.count > 1 ? "s" : "")") { copy(item.entries.map(\.to)) }
            Button("Copy Source Path\(item.entries.count > 1 ? "s" : "")") { copy(item.entries.map(\.from)) }
            if let local = localURLs.first {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(localURLs.isEmpty ? [local] : localURLs) }
            }
            Divider()
            if item.isFinished {
                if item.canRetry { Button("Retry") { model.transfers.retry(item) } }
                Button("Remove from List") { withAnimation { model.transfers.remove(item) } }
            } else {
                Button("Cancel") { model.transfers.cancel(item) }
            }
        }
    }

    private var title: String {
        if item.entries.count > 1 {
            let files = item.fileCount.map { " (\($0.formatted()) files)" } ?? ""
            return "\(item.entries.count) items\(files)"
        }
        return item.name
    }

    /// "from → to", with the full paths on hover.
    private var route: some View {
        HStack(spacing: 4) {
            Text(item.sourceDescription).lineLimit(1).truncationMode(.middle)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
            Text(item.destinationDescription).lineLimit(1).truncationMode(.middle)
        }
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .help("\(item.sourceDescription) → \(item.destinationDescription)")
    }

    @ViewBuilder
    private var status: some View {
        switch item.state {
        case .queued:
            Text("Queued — waiting for a free slot").font(.caption).foregroundStyle(.secondary)
        case .running where item.isStopping:
            ProgressView(value: item.progress)
            Text("Stopping…").font(.caption).foregroundStyle(.secondary)
        case .running:
            if let question = item.question {
                QuestionView(item: item, question: question)
            } else {
                ProgressView(value: item.progress).animation(.smooth, value: item.progress)
                if let stage = item.stageText {
                    Text(stage).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if item.stage == nil || item.stage == .streaming || item.bytesDone > 0 {
                    Text(runningText).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        case .completed:
            Text(completedText).font(.caption).foregroundStyle(.green)
        case .failed(let msg):
            Text(msg).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
        case .cancelled:
            Text("Cancelled — what it had copied so far was removed")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var runningText: String {
        var parts: [String] = []
        if item.method == .archive {
            parts.append("Sent " + (item.totalBytes.map { "\(item.bytesDone.byteString) of \($0.byteString)" } ?? item.bytesDone.byteString))
        } else {
            parts.append("\(Int(item.progress * 100))%")
            if !item.transferred.isEmpty { parts.append(item.transferred) }
            if !item.currentFile.isEmpty, item.currentFile != item.name { parts.append(item.currentFile) }
            if item.filesDone > 0 { parts.append("\(item.filesDone) files done") }
        }
        if !item.speed.isEmpty { parts.append(item.speed) }
        if !item.eta.isEmpty && item.eta != "--:--" { parts.append("ETA \(item.eta)") }
        return parts.joined(separator: "  ·  ")
    }

    private var completedText: String {
        guard let s = item.startedAt, let e = item.finishedAt else { return "Completed" }
        let secs = max(e.timeIntervalSince(s), 0.1)
        var text = String(format: "Completed in %.1f s", secs)
        let bytes = item.method == .archive ? item.bytesDone : (item.totalBytes ?? 0)
        if bytes > 0 {
            text += " · \(bytes.byteString) · \(Int64(Double(bytes) / secs).byteString)/s"
        } else if !item.speed.isEmpty {
            text += " · \(item.speed)"
        }
        let renamed = item.entries.filter(\.renamed).count
        if renamed > 0 { text += " · \(renamed) renamed to avoid overwriting" }
        return text
    }

    @ViewBuilder
    private var actions: some View {
        if item.isFinished {
            HStack(spacing: 6) {
                if item.canRetry {
                    Button { model.transfers.retry(item) } label: {
                        Label("Retry", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon).font(.caption)
                    }
                    .help("Send it again from the start (nothing is overwritten)")
                }
                if item.state == .completed, !localURLs.isEmpty, item.direction == .download {
                    Button { NSWorkspace.shared.activateFileViewerSelecting(localURLs) } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .help("Show in Finder")
                }
                Button { copy(item.entries.map(\.to)) } label: {
                    Label(copied ? "Copied" : "Copy Path", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(copied ? Color.green : .accentColor)
                        .contentTransition(.symbolEffect(.replace))
                }
                .help("Copy destination path\(item.entries.count > 1 ? "s" : ""): \(item.entries.first?.to ?? "")")
                Button { withAnimation { model.transfers.remove(item) } } label: { Image(systemName: "xmark") }
                    .help("Remove from list")
            }
            .buttonStyle(.borderless)
        } else {
            Button { model.transfers.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .help("Cancel")
        }
    }

    /// The Mac side of the transfer.
    private var localURLs: [URL] {
        item.entries.map { URL(fileURLWithPath: item.direction == .upload ? $0.from : $0.to) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func copy(_ paths: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        withAnimation(.snappy) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.snappy) { copied = false }
        }
    }

    private var tint: Color {
        switch item.state {
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        default: .accentColor
        }
    }
}

/// Every item of a group transfer: where it came from and where it went.
private struct EntryList: View {
    let entries: [TransferEntry]
    private let limit = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(entries.prefix(limit), id: \.self) { e in
                HStack(spacing: 4) {
                    Text((e.from as NSString).lastPathComponent)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    Text(e.to).truncationMode(.middle)
                    if e.renamed {
                        Text("renamed").font(.caption2).foregroundStyle(.orange)
                    }
                }
                .lineLimit(1)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .help("\(e.from) → \(e.to)")
            }
            if entries.count > limit {
                Text("and \(entries.count - limit) more").font(.caption).foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .padding(.top, 2)
    }
}

/// Work before a transfer starts (checking names, counting files), with what it found so far.
private struct PreparationRow: View {
    @Environment(AppModel.self) private var model
    let prep: TransferPreparation

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: prep.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(prep.title).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(prep.statusText).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button { model.transfers.cancel(prep) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .help("Cancel — nothing has been sent yet")
        }
    }
}

/// "<host> is slow to compress (2 cores, load 3.4)." with the two ways on, and whether to keep
/// the answer for the host.
struct QuestionView: View {
    @Environment(AppModel.self) private var model
    let item: TransferItem
    let question: CompressionQuestion
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.text).font(.caption).foregroundStyle(.orange)
            HStack(spacing: 8) {
                Button("Send Without Compressing") { model.transfers.answer(item, compress: false, remember: remember) }
                Button("Compress Anyway (\(question.method.rawValue))") { model.transfers.answer(item, compress: true, remember: remember) }
                Toggle("Remember for this host", isOn: $remember).toggleStyle(.checkbox)
            }
            .controlSize(.small)
        }
    }
}
