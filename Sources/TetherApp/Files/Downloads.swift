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
    /// `completion` gets the local items that arrived and how many failed (not called when the
    /// count before the download was cancelled: nothing was sent).
    func downloadRemote(_ items: [RemoteFile], from target: ConnectionTarget, to local: URL,
                        completion: @escaping ([URL], Int) -> Void) {
        downloadRemoteItems(items, from: target, to: local) { outcome in
            guard let outcome else { return }
            completion(Array(outcome.arrived.values), outcome.failed)
        }
    }

    typealias DownloadOutcome = TransferManager.DownloadOutcome

    /// The one way several remote items are downloaded (the Download command, ⌘C, Download All,
    /// a drag to Finder): see `TransferManager.downloadItems`.
    func downloadRemoteItems(_ items: [RemoteFile], from target: ConnectionTarget, to local: URL,
                             completion: @escaping (DownloadOutcome?) -> Void) {
        transfers.downloadItems(items, from: target, to: local, fs: RemoteFileSystem(executor: executor(for: target)),
                                completion: completion)
    }
}
