import SwiftUI
import Observation
import TetherCore
import SessionKit
import FileTransferKit
import TerminalUI

/// Files dropped on (or pasted into) a terminal, waiting for the user to pick a destination.
struct UploadRequest: Identifiable {
    let id = UUID()
    let session: TerminalSession
    let files: [URL]
}

/// A running upload for a terminal: when every file has arrived, their paths are typed into it.
@MainActor
@Observable
final class UploadBatch: Identifiable {
    let id = UUID()
    let sessionID: UUID
    let directory: String
    var items: [TransferItem] = []
    var paths: [String] = []
    var error: String?
    var finished = false
    var pastePaths = true
    var fileCount = 0

    init(sessionID: UUID, directory: String) {
        self.sessionID = sessionID
        self.directory = directory
    }

    var progress: Double {
        guard !items.isEmpty else { return 0 }
        return items.reduce(0) { $0 + ($1.state == .completed ? 1 : $1.progress) } / Double(items.count)
    }
}

extension AppModel {
    /// Uploads files next to each other in `directory` (never overwriting: clashing names get a
    /// suffix), then types their full paths into the terminal if asked to. Many files are packed
    /// into one stream unless `pack` is false.
    func upload(_ files: [URL], for session: TerminalSession, to directory: String, pastePaths: Bool,
                pack: Bool? = nil, size: TransferSize? = nil) {
        var dir = directory.isEmpty ? "/tmp" : directory
        let batch = UploadBatch(sessionID: session.id, directory: dir)
        batch.pastePaths = pastePaths
        uploadBatches[session.id] = batch
        let target = session.descriptor.target
        Task {
            let fs = RemoteFileSystem(executor: executor(for: target))
            let names: [String]
            let measured: TransferSize
            do {
                // On Windows, ~ and /tmp become the user's real folders.
                dir = try await fs.resolveDirectory(dir)
                names = try await fs.uniqueNames(in: dir, for: files.map(\.lastPathComponent))
                if let size { measured = size } else { measured = await Task.detached { LocalFiles.measure(files) }.value }
            } catch {
                batch.error = error.localizedDescription
                batch.finished = true
                return
            }
            batch.paths = names.map { (dir.hasSuffix("/") ? dir : dir + "/") + $0 }
            batch.fileCount = measured.files
            batch.items = transfers.uploadGroup(files, names: names, to: dir, target: target, fileCount: measured.files,
                                                totalBytes: measured.bytes, pack: pack) { items in
                for item in items {
                    if case .failed(let message) = item.state { batch.error = message }
                    if item.state == .cancelled, batch.error == nil { batch.error = "Upload cancelled" }
                }
                batch.finished = true
                if batch.error == nil && pastePaths {
                    let text = batch.paths.map(\.shellQuoted).joined(separator: " ") + " "
                    session.send(Array(text.utf8)[...])
                }
                FileBrowserModel.invalidate(target)
                // Keep the confirmation visible for a moment.
                DispatchQueue.main.asyncAfter(deadline: .now() + (batch.error == nil ? 3 : 8)) {
                    if self.uploadBatches[session.id] === batch { self.uploadBatches[session.id] = nil }
                }
            }
        }
    }

    /// What a drop/paste of files does for a session: local terminals get the paths directly,
    /// remote ones ask where to upload.
    func handleFiles(_ files: [URL], for session: TerminalSession, in state: WindowState) {
        if session.descriptor.target.isLocal {
            let text = files.map { $0.path.shellQuoted }.joined(separator: " ") + " "
            session.send(Array(text.utf8)[...])
        } else {
            state.uploadRequest = UploadRequest(session: session, files: files)
        }
    }
}

/// Asks where on the server dropped files should go. Enter accepts /tmp.
struct UploadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: UploadRequest
    @State private var directory = ""
    @AppStorage("upload.pastePaths") private var pastePaths = true
    @FocusState private var focused: Bool
    @State private var size: TransferSize?
    @State private var pack = false


    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.up.doc.fill").font(.system(size: 28)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Upload \(request.files.count) item\(request.files.count == 1 ? "" : "s") to \(request.session.descriptor.target.displayName)")
                        .font(.headline)
                    if let size {
                        Text("\(size.files.formatted()) file\(size.files == 1 ? "" : "s") · \(size.bytes.byteString)")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Counting files…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(request.files.prefix(6), id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: url.hasDirectoryPath ? "folder" : "doc")
                        .lineLimit(1).truncationMode(.middle)
                }
                if request.files.count > 6 {
                    Text("and \(request.files.count - 6) more…").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            VStack(alignment: .leading, spacing: 4) {
                Text("Destination folder on the server").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("/tmp", text: $directory)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .focused($focused)
                        .onSubmit(upload)
                    if let cwd = request.session.currentDirectory, cwd != directory {
                        Button("Current folder") { directory = cwd }
                            .help(cwd)
                    }
                }
                Text("Files with the same name are kept: new copies get a suffix (name-1.ext).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TransferMethodPicker(fileCount: size?.files, pack: $pack)
            Toggle("Type the uploaded paths into the terminal", isOn: $pastePaths)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Upload") { upload() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { focused = true }
        .task {
            let files = request.files
            let measured = await Task.detached { LocalFiles.measure(files) }.value
            size = measured
            pack = model.transfers.policy.packs(fileCount: measured.files)
        }
    }

    private func upload() {
        let dir = directory.trimmingCharacters(in: .whitespaces)
        model.upload(request.files, for: request.session, to: dir.isEmpty ? "/tmp" : dir, pastePaths: pastePaths,
                     pack: size == nil ? nil : pack, size: size)
        dismiss()
    }
}

/// Progress of uploads started from a terminal, shown over it.
struct UploadBatchPill: View {
    let batch: UploadBatch

    var body: some View {
        GlassPill {
            HStack(spacing: 10) {
                if let error = batch.error {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Upload failed: \(error)").lineLimit(2)
                } else if batch.finished {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Uploaded to \(batch.directory)" + (batch.pastePaths ? " — path\(batch.paths.count == 1 ? "" : "s") typed into the terminal" : ""))
                } else {
                    ProgressView(value: batch.progress).frame(width: 90)
                    Text("Uploading \(batch.fileCount > 0 ? batch.fileCount.formatted() + " file" + (batch.fileCount == 1 ? "" : "s") : "…") to \(batch.directory)"
                         + (batch.items.first?.method == .archive ? " as one stream" : ""))
                    if let speed = batch.items.first(where: { $0.state == .running })?.speed, !speed.isEmpty {
                        Text(speed).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .font(.callout)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

/// Lets the user choose between one packed stream and parallel file-by-file copies.
struct TransferMethodPicker: View {
    @Environment(AppModel.self) private var model
    let fileCount: Int?
    @Binding var pack: Bool

    var body: some View {
        if let fileCount, fileCount > 1 {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Send", selection: $pack) {
                    Text("As one stream").tag(true)
                    Text("File by file").tag(false)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Text(pack
                     ? "Packed with tar here and unpacked on the other side in a single stream — much faster for many small files. Nothing is overwritten."
                     : "Each item is copied with scp, \(model.transfers.policy.parallel) at a time.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
