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
    /// Shown at a time (Earlier / Later page through the rest): every line of it can be scrolled to.
    /// 16 MB, or less when its lines would take more memory than a transcript may
    /// (`ReadOnlyTerminalView.maxLines`): very short lines are many.
    @State private var sliceBytes = 16 * 1024 * 1024
    private static let maxSliceBytes = 16 * 1024 * 1024

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
                               message: archived?.reason.hasPrefix("Opened") == true
                                   ? "Nothing was run in this session, so only its opening is kept."
                                   : "Recording was turned off for this session.")
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
                    .prominentGlassButtonStyle()
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
            if reloadToken == 0 { position = request.revealText != nil ? request.revealFraction : 1 }
            let target = position, most = Self.maxSliceBytes
            let maxLines = ReadOnlyTerminalView.maxLines(cols: 80)
            // A long session's earlier output is in parts: they count (their names say how much they hold).
            let (size, d, local, used) = await Task.detached {
                let file = Int64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0)
                let size = RecordingParts.parts(of: url).reduce(file) { $0 + Int64($1.length) }
                var bytes = most
                var (d, local) = RecordingStore.slice(of: url, around: target, maxBytes: bytes)
                let lines = d.reduce(0) { $0 + ($1 == 0x0a ? 1 : 0) }
                if lines > maxLines {
                    bytes = max(Int(Double(bytes) * Double(maxLines) / Double(lines) * 0.9), 256 * 1024)
                    (d, local) = RecordingStore.slice(of: url, around: target, maxBytes: bytes)
                }
                return (size, d, local, bytes)
            }.value
            fileSize = size
            sliceBytes = used
            fraction = request.revealText != nil && reloadToken == 0 ? local : 0
            data = d
        }
    }
}
