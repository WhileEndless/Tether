import SwiftUI
import Observation
import TetherCore
import SessionKit
import FileTransferKit
import TerminalUI
import SSHTransport

/// Files dropped on (or pasted into) a terminal, waiting for the user to pick a destination.
struct UploadRequest: Identifiable {
    let id = UUID()
    let session: TerminalSession
    let files: [URL]
    /// Why the sheet opened although the setting says to upload without asking.
    var note: String? = nil
    /// The folder the field starts with (instead of the terminal's current one).
    var suggested: String? = nil
}

/// A running upload for a terminal: when every file has arrived, their paths are typed into it.
@MainActor
@Observable
final class UploadBatch: Identifiable {
    let id = UUID()
    let sessionID: UUID
    /// Where the files go (updated once resolved: on Windows /tmp becomes the real temp folder).
    var directory: String
    var items: [TransferItem] = []
    var paths: [String] = []
    var error: String?
    var finished = false
    var pastePaths = true
    /// The paths could not be typed (a full-screen program was in front): they were copied instead.
    var copiedInstead = false
    /// Still asking the terminal where it is (the files have not been sent yet).
    var findingFolder = false
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
    /// - Parameter create: make the folder if it does not exist (a folder the user typed); false for
    ///   one Tether chose itself (the terminal's current folder), which must exist.
    /// - Parameter onFolderProblem: called instead of failing when that chosen folder cannot take the
    ///   files (missing, not writable): nothing was sent yet, so the user can pick another one.
    func upload(_ files: [URL], for session: TerminalSession, to directory: String, pastePaths: Bool,
                pack: Bool? = nil, size: TransferSize? = nil, create: Bool = true,
                onFolderProblem: ((String) -> Void)? = nil) {
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
                batch.directory = dir
                do {
                    names = try await fs.uniqueNames(in: dir, for: files.map(\.lastPathComponent), create: create)
                } catch where onFolderProblem != nil {
                    if self.uploadBatches[session.id] === batch { self.uploadBatches[session.id] = nil }
                    onFolderProblem?(error.localizedDescription)
                    return
                }
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
                if batch.error == nil && pastePaths { batch.copiedInstead = !self.typePaths(batch.paths, into: session) }
                FileBrowserModel.invalidate(target)
                // Keep the confirmation visible for a moment.
                let bars = self.settings.floatingBars
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(batch.error == nil ? bars.uploadDoneHideAfter : bars.uploadFailedHideAfter)) {
                    if self.uploadBatches[session.id] === batch { self.uploadBatches[session.id] = nil }
                }
            }
        }
    }

    /// Types paths into a terminal as one paste: quoted for its shell (PowerShell on Windows), and
    /// bracketed when the shell asked for it, so nothing runs before the user presses Return.
    /// Not into a full-screen program (an upload can finish minutes later, with vim or htop in
    /// front, which would take the letters as commands), and not names with control characters:
    /// then the paths go to the clipboard instead. Returns whether they were typed.
    @discardableResult
    func typePaths(_ paths: [String], into session: TerminalSession) -> Bool {
        let quoted = paths.map { session.platform.isWindows ? $0.powerShellQuoted : $0.shellQuoted }
        let view = TerminalRegistry.shared.existingView(for: session.id)
        let unsafe = paths.contains { $0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } }
        guard !unsafe, view?.showsAlternateScreen != true else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(quoted.joined(separator: " "), forType: .string)
            return false
        }
        var text = quoted.joined(separator: " ") + " "
        if view?.getTerminal().bracketedPasteMode == true {
            text = "\u{1b}[200~" + text + "\u{1b}[201~"
        }
        session.send(Array(text.utf8)[...])
        return true
    }

    /// What a drop/paste of files does for a session: local terminals get the paths directly;
    /// remote ones upload to the folder chosen in Settings ▸ Transfers (the terminal's current folder
    /// by default), or ask — always while ⌥ is held, and when the current folder cannot be told.
    /// - Parameter askAnyway: show the sheet whatever the setting (Paste Files To…, ⌥ while dropping).
    func handleFiles(_ files: [URL], for session: TerminalSession, in state: WindowState, askAnyway: Bool? = nil) {
        if session.descriptor.target.isLocal {
            typePaths(files.map(\.path), into: session)
            return
        }
        // A network device or limited shell gets nothing but its login from Tether — no files.
        if PlatformCache.shared.isDevice(session.descriptor.target.key) {
            let batch = UploadBatch(sessionID: session.id, directory: "")
            batch.error = "This host is a network device or limited shell, so Tether sends it no files. Copy them with the device's own tools (scp from a terminal of this Mac, TFTP…)."
            batch.finished = true
            uploadBatches[session.id] = batch
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(settings.floatingBars.uploadFailedHideAfter + 4)) {
                if self.uploadBatches[session.id] === batch { self.uploadBatches[session.id] = nil }
            }
            return
        }
        let ask = askAnyway ?? NSEvent.modifierFlags.contains(.option)
        switch ask ? .ask : settings.uploadDestination {
        case .ask:
            state.uploadRequest = UploadRequest(session: session, files: files)
        case .tmp:
            upload(files, for: session, to: "/tmp", pastePaths: settings.uploadTypesPaths)
        case .currentFolder:
            // Say at once that something happens (a slow or filtered link can take seconds to answer).
            let finding = UploadBatch(sessionID: session.id, directory: "")
            finding.findingFolder = true
            uploadBatches[session.id] = finding
            Task {
                let found = await uploadDirectory(for: session)
                if uploadBatches[session.id] === finding { uploadBatches[session.id] = nil }
                switch found {
                case .folder(let dir):
                    upload(files, for: session, to: dir, pastePaths: settings.uploadTypesPaths, create: false) { problem in
                        state.uploadRequest = UploadRequest(session: session, files: files,
                                                            note: "The terminal's folder \(dir) cannot take the files (\(problem)). Choose another folder.",
                                                            suggested: "/tmp")
                    }
                case .unknown(let why):
                    state.uploadRequest = UploadRequest(session: session, files: files, note: why)
                }
            }
        }
    }

    enum UploadFolder {
        case folder(String)
        /// Why the folder could not be told (shown in the sheet).
        case unknown(String)
    }

    /// The folder the terminal's shell is in now, asked fresh: tmux's pane path, else the folder of
    /// the program in front in a plain shell (Linux /proc, otherwise lsof), else what the shell
    /// last reported (OSC 7). nil when it cannot be told (screen, Windows, a shell that says nothing).
    func uploadDirectory(for session: TerminalSession) async -> UploadFolder {
        guard session.phase.isOnline else { return .unknown("The terminal is not connected right now, so its folder cannot be asked.") }
        guard !session.platform.isWindows else { return .unknown("Windows servers do not tell Tether the terminal's folder.") }
        if session.persistence == .tmux {
            if let command = await session.tmuxForegroundCommand(), Self.connectsElsewhere(command) {
                return .unknown(Self.elsewhereNote(command))
            }
            if let dir = await session.workingDirectory(), dir.hasPrefix("/") { return .folder(dir) }
        }
        if session.persistence == .plain, case .posix(let pid)? = await session.shellAnchor() {
            // The folder of the program in front (the shell itself at its prompt). Exit 2: that
            // program connects to another machine; 3: it runs as another user (sudo -i, su) whose
            // folder cannot be read — the login shell's folder would be the wrong one.
            let script = #"""
p="$1"
t=$(ps -o tpgid= -p "$p" 2>/dev/null | tr -d ' ')
case "$t" in ''|-*|0) t="$p" ;; esac
c=$(ps -o comm= -p "$t" 2>/dev/null | sed 's|.*/||; s/^-//')
case "$c" in ssh|mosh-client|mosh|telnet|docker|kubectl|podman|lxc|incus) printf '%s
' "$c"; exit 2 ;; esac
d=$(readlink "/proc/$t/cwd" 2>/dev/null) || d=$(lsof -a -d cwd -p "$t" -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)
if [ -n "$d" ] && [ -d "$d" ]; then printf '%s
' "$d"; exit 0; fi
[ "$t" != "$p" ] && exit 3
exit 1
"""#
            let r = await executor(for: session.descriptor.target).run(script: script, arguments: [String(pid)], timeout: 5, purpose: "files")
            let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            switch r.status {
            case 0 where out.hasPrefix("/"): return .folder(out)
            case 2: return .unknown(Self.elsewhereNote(out))
            case 3: return .unknown("The program in front runs as another user (sudo, su), so its folder cannot be read.")
            default: break
            }
        }
        if session.persistence != .screen, let dir = session.reportedDirectory, dir.hasPrefix("/") { return .folder(dir) }
        return .unknown("The terminal's current folder could not be told (the shell does not report it).")
    }

    /// Programs that work on another machine: their folder is not where uploads to this host go.
    static func connectsElsewhere(_ command: String) -> Bool {
        ["ssh", "mosh-client", "mosh", "telnet", "docker", "kubectl", "podman", "lxc", "incus"].contains(command)
    }

    static func elsewhereNote(_ command: String) -> String {
        "“\(command)” runs in this terminal and may be connected to another machine; files go to this server, so choose its folder."
    }
}

/// Asks where on the server dropped files should go, suggesting the terminal's current folder.
/// Enter accepts what the field shows (/tmp when empty).
struct UploadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: UploadRequest
    @State private var directory = ""
    @State private var currentFolder: String?
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
                    if let cwd = currentFolder, cwd != directory {
                        Button("Current Folder") { directory = cwd }
                            .help(cwd)
                    }
                    if directory != "/tmp" {
                        Button("/tmp") { directory = "/tmp" }
                            .help("The server's folder for temporary files")
                    }
                }
                if let note = request.note {
                    Text(note)
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Files with the same name are kept: new copies get a suffix (name-1.ext). Settings ▸ Transfers sets where pasted files go without asking; ⌥⌘V (or ⌥ while dropping) always asks.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TransferMethodPicker(fileCount: size?.files, pack: $pack)
            Toggle("Type the uploaded paths into the terminal", isOn: Binding(
                get: { model.settings.uploadTypesPaths }, set: { model.settings.uploadTypesPaths = $0 }))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Upload") { upload() }
                    .keyboardShortcut(.defaultAction)
                    .prominentGlassButtonStyle()
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
        .task {
            // Suggested, not chosen: the field starts with the current folder when it is known.
            if let suggested = request.suggested { directory = suggested }
            guard request.note == nil else { return }
            if case .folder(let cwd) = await model.uploadDirectory(for: request.session) { currentFolder = cwd }
            if directory.isEmpty, let cwd = currentFolder { directory = cwd }
        }
    }

    private func upload() {
        let dir = directory.trimmingCharacters(in: .whitespaces)
        model.upload(request.files, for: request.session, to: dir.isEmpty ? "/tmp" : dir, pastePaths: model.settings.uploadTypesPaths,
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
                if batch.findingFolder {
                    ProgressView().controlSize(.small)
                    Text("Finding the terminal's folder…")
                } else if let error = batch.error {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Upload failed: \(error)").lineLimit(2)
                } else if batch.finished {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Uploaded to \(batch.directory)" + (!batch.pastePaths ? ""
                        : batch.copiedInstead ? " — a full-screen program is open, so the path\(batch.paths.count == 1 ? " was" : "s were") copied: paste with ⌘V"
                        : " — path\(batch.paths.count == 1 ? "" : "s") typed into the terminal"))
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
