import AppKit
import UniformTypeIdentifiers
import TetherCore
import SessionKit
import FileTransferKit
import TerminalUI
import SSHTransport

/// The remote files last copied in a file manager (⌘C). They are on the pasteboard at once — as
/// Tether's own type (server and paths) and as text (the paths) — and their download for Finder
/// starts at once too (one packed stream for many files, shown in Transfers); when it has arrived
/// the pasteboard also gets them as files, so Finder's Paste works from then on. (Finder cannot
/// paste promised files from the clipboard, so there is no way to start it at the moment of
/// pasting there.) Pasting into another server uses that download (waiting for it while it runs);
/// pasting into the same server copies there and does not wait for it.
@MainActor
final class ClipboardCopy {
    static var current: ClipboardCopy?

    let clip: RemoteClip
    let files: [RemoteFile]
    let target: ConnectionTarget
    /// The pasteboard's change count after the clip was written: while it is the same, the
    /// pasteboard still holds this clip (nothing else is ever replaced).
    var changeCount: Int
    /// The local copies, once downloaded (in a folder of their own under the clipboard folder).
    private(set) var localCopies: [URL]?
    private(set) var fetching = false
    private var waiters: [([URL]?) -> Void] = []

    init(clip: RemoteClip, files: [RemoteFile], target: ConnectionTarget, changeCount: Int) {
        self.clip = clip
        self.files = files
        self.target = target
        self.changeCount = changeCount
    }

    /// This clip is still what the pasteboard holds: unchanged since it was written, or written
    /// again with the same clip (Edit ▸ Copy: SwiftUI writes it once more after `copyRemoteFiles`).
    var isOnPasteboard: Bool {
        let pb = NSPasteboard.general
        return pb.changeCount == changeCount || RemoteClipboard.read(from: pb) == clip
    }

    /// Downloads the files for Finder (once); `then` gets the local copies (nil: failed or cancelled).
    func fetch(with model: AppModel, then: (([URL]?) -> Void)? = nil) {
        if let localCopies { then?(localCopies); return }
        if let then { waiters.append(then) }
        guard !fetching else { return }
        fetching = true
        let folder = AppPaths.clipboardDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.downloadRemoteItems(files, from: target, to: folder) { [weak self] outcome in
            guard let self else { return }
            self.fetching = false
            let urls = outcome.map { o in self.files.compactMap { o.arrived[$0.path] } } ?? []
            if !urls.isEmpty {
                self.localCopies = urls
                // Still this clip on the pasteboard: the files are added (Finder can paste them now).
                if self.isOnPasteboard {
                    self.changeCount = RemoteClipboard.write(self.clip, localCopies: urls, to: .general)
                }
            }
            let waiting = self.waiters
            self.waiters.removeAll()
            for w in waiting { w(urls.isEmpty ? nil : urls) }
        }
    }

}

extension UTType {
    /// Remote files copied or dragged in a file manager (`RemoteClipboard`; declared in Info.plist).
    static let tetherRemoteFiles = UTType(exportedAs: RemoteClipboard.typeIdentifier, conformingTo: .data)
}

extension RemoteClip {
    init(_ files: [RemoteFile], from target: ConnectionTarget) {
        self.init(target: target, items: files.map { Item(path: $0.path, name: $0.name, isDirectory: $0.isDirectory) })
    }
}

extension AppModel {
    /// ⌘C in a file manager: the items go on the pasteboard and their download for Finder starts
    /// (see `ClipboardCopy`); `ready` gets the local copies once they arrived (nil: they did not).
    func copyRemoteFiles(_ items: [RemoteFile], from target: ConnectionTarget, ready: (([URL]?) -> Void)? = nil) {
        guard !items.isEmpty else { return }
        let clip = RemoteClip(items, from: target)
        let count = RemoteClipboard.write(clip, to: .general)
        let copy = ClipboardCopy(clip: clip, files: items, target: target, changeCount: count)
        ClipboardCopy.current = copy
        copy.fetch(with: self, then: ready)
    }

    /// The remote clip on the general pasteboard: Tether's own type, or — when something wrote
    /// only the text — the last copy whose text it still is.
    var pastedRemoteClip: RemoteClip? {
        let pb = NSPasteboard.general
        if let clip = RemoteClipboard.read(from: pb) { return clip }
        if let copy = ClipboardCopy.current, pb.string(forType: .string) == copy.clip.text { return copy.clip }
        return nil
    }

    /// Local copies of a clip's files for pasting them into another server: the copies already
    /// made for Finder when there are some (kept: they belong to the clipboard), otherwise a
    /// download made for this paste, whose folder `madeHere` names — the caller removes it once
    /// the upload has ended. nil: nothing arrived.
    func localCopies(of clip: RemoteClip, then: @escaping (_ urls: [URL]?, _ madeHere: URL?) -> Void) {
        // The copy's own download (done or under way): used as it is, and kept for Finder. One
        // that failed, or whose files were removed meanwhile, is not waited for: this paste
        // downloads them itself.
        if let copy = ClipboardCopy.current, copy.clip == clip, copy.fetching
            || copy.localCopies.map({ $0.allSatisfy { LocalFiles.exists($0.path) } }) == true {
            copy.fetch(with: self) { urls in then(urls, nil) }
            return
        }
        let files = clip.items.map { item in
            RemoteFile(name: item.name, path: item.path, kind: item.isDirectory ? .directory : .file, permissions: 0,
                       owner: "", group: "", size: 0, modified: Date(), linkTarget: nil)
        }
        let folder = AppPaths.clipboardDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        downloadRemoteItems(files, from: clip.target, to: folder) { outcome in
            let urls = outcome.map { o in files.compactMap { o.arrived[$0.path] } } ?? []
            if urls.isEmpty {
                Self.removeTemporaryCopy(folder)
                then(nil, nil)
            } else {
                then(urls, folder)
            }
        }
    }

    /// Removes a folder of local copies a paste made (only one inside the clipboard folder).
    static func removeTemporaryCopy(_ folder: URL?) {
        guard let folder else { return }
        let base = AppPaths.clipboardDirectory.standardizedFileURL.path + "/"
        let path = folder.standardizedFileURL.path
        guard path.hasPrefix(base), !path.dropFirst(base.count).contains("/") else { return }
        LocalFiles.discard(folder)
    }

    /// ⌘V in a terminal with remote files on the pasteboard. The same server: their paths are
    /// typed (quoted for its shell). Another server: they come through this Mac — downloaded,
    /// uploaded where the terminal's uploads go (Settings ▸ Transfers), the temporary copy
    /// removed — and their new paths are typed as for any upload. Returns false when the
    /// pasteboard holds no remote files (the paste goes on as usual).
    /// `dropped`: remote files dragged onto the terminal (handled the same way) instead of the pasteboard's.
    @discardableResult
    func pasteRemoteClip(into session: TerminalSession, in state: WindowState, dropped: RemoteClip? = nil) -> Bool {
        guard let clip = dropped ?? pastedRemoteClip else { return false }
        if clip.targetKey == session.descriptor.target.key {
            typePaths(clip.paths, into: session)
            return true
        }
        // Shown over the terminal while the files come to this Mac (a large folder takes a while).
        let fetching = UploadBatch(sessionID: session.id, directory: "")
        fetching.fetching = (clip.items.count, clip.target.displayName)
        uploadBatches[session.id] = fetching
        let fetched: ([URL]?) -> Bool = { urls in
            guard urls == nil else {
                if self.uploadBatches[session.id] === fetching { self.uploadBatches[session.id] = nil }
                return true
            }
            fetching.fetching = nil
            fetching.error = "nothing arrived from \(clip.target.displayName) — see Transfers"
            fetching.finished = true
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(self.settings.floatingBars.uploadFailedHideAfter + 4)) {
                if self.uploadBatches[session.id] === fetching { self.uploadBatches[session.id] = nil }
            }
            return false
        }
        if session.descriptor.target.isLocal {
            // A terminal on this Mac: the files are fetched here and their paths typed.
            localCopies(of: clip) { urls, _ in
                if fetched(urls), let urls { self.typePaths(urls.map(\.path), into: session) }
            }
            return true
        }
        // Then sent like files pasted from Finder: where Settings ▸ Transfers says (the
        // terminal's folder, /tmp, or asked), the temporary copy removed afterwards.
        localCopies(of: clip) { urls, madeHere in
            guard fetched(urls), let urls else { return }
            self.handleFiles(urls, for: session, in: state, afterUpload: { Self.removeTemporaryCopy(madeHere) })
        }
        return true
    }
}
