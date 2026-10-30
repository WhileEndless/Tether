import AppKit
import TetherCore

/// Remote files copied in the file manager (⌘C), as they travel on a pasteboard: the server and
/// the paths (Tether's own type), the paths as plain text (one per line, for pasting anywhere),
/// and — once they have been downloaded for Finder — the local copies as file URLs.
///
/// The private type is JSON: `{"targetKey": …, "target": …, "items": [{"path", "name", "isDirectory"}]}`;
/// `targetKey` is `ConnectionTarget.key`, so a reader can tell the server without decoding the target.
public struct RemoteClip: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var path: String
        public var name: String
        public var isDirectory: Bool

        public init(path: String, name: String, isDirectory: Bool) {
            self.path = path
            self.name = name
            self.isDirectory = isDirectory
        }
    }

    public var targetKey: String
    public var target: ConnectionTarget
    public var items: [Item]

    public init(target: ConnectionTarget, items: [Item]) {
        self.targetKey = target.key
        self.target = target
        self.items = items
    }

    public var paths: [String] { items.map(\.path) }

    /// One path per line: what pasting as text gives.
    public var text: String { paths.joined(separator: "\n") }

    /// All in one folder (what a server-side copy and a packed download need).
    public var parent: String? {
        let parents = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
        return parents.count == 1 ? parents.first : nil
    }
}

public enum RemoteClipboard {
    public static let typeIdentifier = "com.tether.remote-files"
    public static let type = NSPasteboard.PasteboardType(typeIdentifier)

    /// Puts a clip on the pasteboard (replacing what was there), with the local copies when there
    /// are some. Returns the pasteboard's change count afterwards (to tell later whether it is
    /// still this clip).
    @discardableResult
    public static func write(_ clip: RemoteClip, localCopies: [URL] = [], to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        let first = NSPasteboardItem()
        first.setString(clip.text, forType: .string)
        if let data = try? JSONEncoder().encode(clip) { first.setData(data, forType: type) }
        var items = [first]
        for (i, url) in localCopies.enumerated() {
            let item = i == 0 ? first : NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if i > 0 { items.append(item) }
        }
        pasteboard.writeObjects(items)
        return pasteboard.changeCount
    }

    /// The clip on the pasteboard, if it holds one (all its items' clips together: a drag puts one
    /// on each dragged row).
    public static func read(from pasteboard: NSPasteboard) -> RemoteClip? {
        merge((pasteboard.pasteboardItems ?? []).compactMap { $0.data(forType: type).flatMap(decode) })
    }

    /// The private type's data for a clip (what a drag carries beside the files it can download).
    public static func encode(_ clip: RemoteClip) -> Data? { try? JSONEncoder().encode(clip) }

    public static func decode(_ data: Data) -> RemoteClip? { try? JSONDecoder().decode(RemoteClip.self, from: data) }

    /// Several clips as one: the items of the first one's server, each path once, in order. Clips
    /// of another server are left out (one paste or drop never mixes servers). nil: no items.
    public static func merge(_ clips: [RemoteClip]) -> RemoteClip? {
        guard let first = clips.first(where: { !$0.items.isEmpty }) else { return nil }
        var seen = Set<String>()
        var items: [RemoteClip.Item] = []
        for clip in clips where clip.targetKey == first.targetKey {
            for item in clip.items where seen.insert(item.path).inserted { items.append(item) }
        }
        return RemoteClip(target: first.target, items: items)
    }

    /// Local files on the pasteboard (copied in Finder, or a clip's local copies) that exist.
    public static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return urls.filter { LocalFiles.exists($0.path) }
    }
}

/// What pasting into a file manager folder does.
public enum FilePaste: Equatable, Sendable {
    /// Copied from the same server: copied (or moved) there, under free names.
    case onServer([String])
    /// Copied from another server: through this Mac (downloaded, uploaded, the temporary copy removed).
    case fromOtherServer(RemoteClip)
    /// Files from this Mac (Finder, a screenshot): uploaded.
    case upload([URL])
    /// Nothing to paste, and why.
    case nothing(String)

    /// - Parameters:
    ///   - clip: remote files on the pasteboard; `localFiles`: files from this Mac on it.
    public static func decide(clip: RemoteClip?, localFiles: [URL], into destination: ConnectionTarget) -> FilePaste {
        if let clip, !clip.items.isEmpty {
            return clip.targetKey == destination.key ? .onServer(clip.paths) : .fromOtherServer(clip)
        }
        if !localFiles.isEmpty { return .upload(localFiles) }
        return .nothing("The clipboard holds no files. Copy files in Finder or in a file manager (⌘C), or take a screenshot with ⌃⇧⌘4.")
    }

    /// What dropping remote files dragged from a file manager into `directory` does: like a paste,
    /// except that a drop back into the folder they came from does nothing (a drag that ended
    /// where it began, never a copy of each item).
    public static func decideDrop(_ clip: RemoteClip, into destination: ConnectionTarget, directory: String) -> FilePaste {
        guard !clip.items.isEmpty else { return .nothing("Nothing was dropped.") }
        if clip.targetKey == destination.key {
            // Compared as the server writes them (never resolved on this Mac: `~` or /private mean
            // nothing here); only a trailing slash is ignored.
            func plain(_ p: String) -> String { p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p }
            let parents = Set(clip.paths.map { plain(($0 as NSString).deletingLastPathComponent) })
            if parents == [plain(directory)] { return .nothing("Already in this folder.") }
            return .onServer(clip.paths)
        }
        return .fromOtherServer(clip)
    }
}
