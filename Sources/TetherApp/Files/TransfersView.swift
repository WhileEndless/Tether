import SwiftUI
import FileTransferKit

struct TransfersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                Button("Clear Finished") { withAnimation { model.transfers.clearFinished() } }
                    .disabled(!model.transfers.items.contains { $0.isFinished })
            }
            .padding(12)
            Divider()
            if model.transfers.items.isEmpty {
                EmptyStateView(symbol: "arrow.up.arrow.down", title: "No Transfers",
                               message: "Drop files on the file browser to upload them.")
            } else {
                List(model.transfers.items) { item in
                    TransferRow(item: item)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                .animation(.snappy, value: model.transfers.items.map(\.id))
            }
        }
    }
}

struct TransferRow: View {
    @Environment(AppModel.self) private var model
    let item: TransferItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.direction == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: item.state == .completed)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1)
                switch item.state {
                case .running, .queued:
                    ProgressView(value: item.progress).animation(.smooth, value: item.progress)
                    Text(item.state == .queued ? "Queued"
                         : "\(Int(item.progress * 100))%  \(item.transferred)  \(item.speed)  ETA \(item.eta)"
                           + (item.filesDone > 0 ? "  · \(item.filesDone) files done" : ""))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                case .completed:
                    Text(completedText).font(.caption).foregroundStyle(.green)
                case .failed(let msg):
                    Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
                case .cancelled:
                    Text("Cancelled").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if item.isFinished {
                if item.direction == .download, item.state == .completed {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([item.localURL]) } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                Button { model.transfers.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
    }

    private var completedText: String {
        guard let s = item.startedAt, let e = item.finishedAt else { return "Completed" }
        let secs = max(e.timeIntervalSince(s), 0.1)
        return String(format: "Completed in %.1f s", secs) + (item.speed.isEmpty ? "" : " · last \(item.speed)")
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
