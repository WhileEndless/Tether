import SwiftUI
import TetherCore
import TerminalUI
import RecordingKit

/// Which transcript to show: an archived session or any recording file, optionally scrolled to a line.
struct TranscriptRequest: Codable, Hashable {
    var archiveID: UUID?
    var path: String?
    /// Text of the line to reveal, and roughly where it is (0…1), for opening search results.
    var revealText: String?
    var revealFraction: Double = 0
}

/// Read-only replay of a recorded session.
struct TranscriptWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let request: TranscriptRequest
    @State private var data: Data?
    @State private var fraction: Double = 0
    /// Position of the loaded slice in the file (0 = start, 1 = end); only used for large files.
    @State private var position: Double = 1
    @State private var fileSize: Int64 = 0
    @State private var reloadToken = 0
    private let sliceBytes = 16 * 1024 * 1024

    private var archived: ArchivedSession? {
        request.archiveID.flatMap { id in model.sessions.archive.first { $0.id == id } }
    }

    /// Current file of the recording (it may have been compressed since it was archived).
    private var path: String? {
        (request.path ?? archived?.recordingPath).flatMap { RecordingStore.resolve($0)?.path ?? $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            if fileSize > Int64(sliceBytes) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary)
                    Text("Large recording (\(fileSize.byteString)) — showing \(Int64(sliceBytes).byteString) around")
                    Slider(value: $position, in: 0...1) { editing in if !editing { reloadToken += 1 } }
                        .frame(maxWidth: 260)
                    Text("\(Int(position * 100))%").monospacedDigit().frame(width: 40)
                    Button("Earlier") { position = max(position - Double(sliceBytes) / Double(fileSize), 0); reloadToken += 1 }
                    Button("Later") { position = min(position + Double(sliceBytes) / Double(fileSize), 1); reloadToken += 1 }
                }
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.bar)
            }
            if let data {
                TranscriptView(data: data, revealText: request.revealText, revealFraction: fraction)
                    .padding(.leading, 6)
                    .id(reloadToken)
            } else if path == nil {
                EmptyStateView(symbol: "record.circle", title: "No Recording",
                               message: "Recording was turned off for this session.")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 12) {
                Image(systemName: "archivebox")
                if let item = archived {
                    Text("\(item.startedAt.formatted(date: .abbreviated, time: .shortened)) – \(item.endedAt.formatted(date: .omitted, time: .shortened))")
                    Text(item.reason).foregroundStyle(.secondary).lineLimit(1)
                } else if let path {
                    Text((path as NSString).lastPathComponent).foregroundStyle(.secondary)
                }
                Spacer()
                if let path {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                if let item = archived {
                    Button("New Session") {
                        let s = model.sessions.open(item.target)
                        openWindow(id: "workspace", value: s.id)
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .font(.caption)
            .padding(10)
            .background(.bar)
        }
        .navigationTitle(archived?.title ?? "Recording")
        .navigationSubtitle("Read-only transcript")
        .task(id: reloadToken) {
            guard let path else { return }
            let url = URL(fileURLWithPath: path)
            fileSize = Int64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0)
            if reloadToken == 0 { position = request.revealText != nil ? request.revealFraction : 1 }
            let target = position
            let (d, local) = await Task.detached { RecordingStore.slice(of: url, around: target) }.value
            fraction = request.revealText != nil && reloadToken == 0 ? local : 0
            data = d
        }
    }
}
