import AppKit
import TetherCore
import SSHTransport
import FileTransferKit

extension AppModel {
    /// Where downloads go without asking (Settings ▸ Transfers): the chosen folder while it exists,
    /// otherwise Downloads.
    var defaultDownloadFolder: URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        guard !settings.downloadFolder.isEmpty else { return downloads }
        let url = URL(fileURLWithPath: (settings.downloadFolder as NSString).expandingTildeInPath, isDirectory: true)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue ? url : downloads
    }

    /// The default folder's name for menus, without touching the disk (a slow or unmounted volume
    /// must not stall drawing a menu).
    var downloadFolderName: String {
        settings.downloadFolder.isEmpty ? "Downloads" : (settings.downloadFolder as NSString).lastPathComponent
    }

    /// The folder for a download: the default one, or — with `ask`, or when Settings say to ask —
    /// one the user picks (nil when cancelled).
    func downloadFolder(ask: Bool = false) -> URL? {
        guard ask || settings.askWhereToDownload else { return defaultDownloadFolder }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Download Here"
        panel.message = "Choose where the downloaded items go. Nothing there is replaced: clashing names get a number (name 2)."
        panel.directoryURL = defaultDownloadFolder
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Downloads remote items into a local folder without replacing anything there (Finder-style
    /// "name 2" names). Many files travel as one packed stream (see Settings ▸ Transfers).
    /// `completion` gets the local items that arrived and how many failed.
    func downloadRemote(_ items: [RemoteFile], from target: ConnectionTarget, to local: URL,
                        completion: @escaping ([URL], Int) -> Void) {
        guard !items.isEmpty else { return }
        let names = LocalFiles.uniqueNames(in: local, for: items.map(\.name))
        let parents = Set(items.map { ($0.path as NSString).deletingLastPathComponent })
        let fs = RemoteFileSystem(executor: executor(for: target))
        let transfers = self.transfers
        Task {
            // Only folders need counting; plain files are counted as they are.
            var size = TransferSize(files: items.count, bytes: items.reduce(0) { $0 + $1.size })
            if items.contains(where: \.isDirectory), transfers.policy.archiveMode != .never {
                size = (try? await fs.measure(items.map(\.path))) ?? size
            }
            let finish: ([TransferItem]) -> Void = { made in
                let ok = made.filter { $0.state == .completed }
                let urls = ok.flatMap { $0.entries.map { URL(fileURLWithPath: $0.to) } }
                completion(urls, made.count - ok.count)
            }
            if parents.count == 1, let parent = parents.first {
                transfers.downloadGroup(items.map(\.name), from: parent, to: local, as: names, target: target,
                                        fileCount: size.files, totalBytes: size.bytes, completion: finish)
            } else {
                var made: [TransferItem] = []
                var remaining = items.count
                for (f, name) in zip(items, names) {
                    made.append(transfers.download(f.path, to: local.appendingPathComponent(name), target: target) { _ in
                        remaining -= 1
                        if remaining == 0 { finish(made) }
                    })
                }
            }
        }
    }
}
