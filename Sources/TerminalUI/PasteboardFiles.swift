import AppKit
import UniformTypeIdentifiers

/// Finds files on a pasteboard: copied Finder files, and images that exist only as data
/// (a screenshot copied with ⌃⇧⌘4, an image copied from Preview or a browser). Image data is
/// saved to a temporary file first so it can be uploaded like any other file.
public enum PasteboardFiles {
    /// Where pasted images and dropped file promises are written. Files older than a week are removed.
    public static var stagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Tether Pasted Files", isDirectory: true)
    }

    /// Copied files, if the pasteboard holds any.
    public static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// True when the pasteboard carries image data but no text (pasting text always wins).
    public static func hasImageOnly(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.string(forType: .string) == nil && pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// What pasting should upload: copied files first, otherwise an image saved as PNG.
    /// Returns nil when the pasteboard should be pasted as text.
    public static func filesToPaste(from pasteboard: NSPasteboard, now: Date = Date()) -> [URL]? {
        let urls = fileURLs(on: pasteboard)
        // Finder also puts the file name on the pasteboard as text; a file URL wins over it.
        if !urls.isEmpty, pasteboard.types?.contains(.fileURL) == true || pasteboard.string(forType: .string) == nil {
            return urls
        }
        if hasImageOnly(pasteboard), let url = saveImage(from: pasteboard, now: now) {
            return [url]
        }
        return nil
    }

    /// Writes the pasteboard's image as PNG (keeping PNG data as is) and returns the new file.
    static func saveImage(from pasteboard: NSPasteboard, now: Date) -> URL? {
        let data: Data?
        if let png = pasteboard.data(forType: .png) {
            data = png
        } else if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) {
            data = rep.representation(using: .png, properties: [:])
        } else {
            data = nil
        }
        guard let data, let dir = prepareStaging() else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        var url = dir.appendingPathComponent("pasted-image-\(f.string(from: now)).png")
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = dir.appendingPathComponent("pasted-image-\(f.string(from: now))-\(n).png")
        }
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Receives dragged file promises (e.g. the screenshot thumbnail, Photos, Mail attachments).
    public static func receivePromises(from pasteboard: NSPasteboard, completion: @escaping @MainActor ([URL]) -> Void) -> Bool {
        guard let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
              !receivers.isEmpty, let dir = prepareStaging() else { return false }
        let dest = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let group = DispatchGroup()
        let lock = NSLock()
        var received: [URL] = []
        for receiver in receivers {
            for _ in receiver.fileNames { group.enter() }
            receiver.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: .main) { url, error in
                if error == nil {
                    lock.lock()
                    received.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = received
            MainActor.assumeIsolated { completion(urls.sorted { $0.lastPathComponent < $1.lastPathComponent }) }
        }
        return true
    }

    /// Creates the staging directory and removes week-old leftovers.
    private static func prepareStaging() -> URL? {
        let dir = stagingDirectory
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date < cutoff { try? fm.removeItem(at: item) }
        }
        return dir
    }
}
