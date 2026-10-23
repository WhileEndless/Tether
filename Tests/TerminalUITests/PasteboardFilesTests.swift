import AppKit
import Testing
@testable import TerminalUI

/// Uses private named pasteboards, so the user's clipboard is never touched.
@Suite struct PasteboardFilesTests {
    private func pasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("tether-test-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    @Test func plainTextPastesAsText() {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        pb.setString("echo hello", forType: .string)
        #expect(PasteboardFiles.filesToPaste(from: pb) == nil)
    }

    @Test func copiedFinderFileWinsOverItsName() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tether-test-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        // Finder writes the file URL and the file name as text.
        let item = NSPasteboardItem()
        item.setString(file.absoluteString, forType: .fileURL)
        item.setString(file.lastPathComponent, forType: .string)
        pb.writeObjects([item])
        #expect(PasteboardFiles.filesToPaste(from: pb)?.map(\.standardizedFileURL) == [file.standardizedFileURL])
    }

    @Test func copiedScreenshotBecomesPNGFile() throws {
        let image = NSImage(size: NSSize(width: 4, height: 3), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        pb.writeObjects([image])
        let urls = try #require(PasteboardFiles.filesToPaste(from: pb))
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(urls.count == 1)
        #expect(urls[0].pathExtension == "png")
        #expect(urls[0].lastPathComponent.hasPrefix("pasted-image-"))
        let data = try Data(contentsOf: urls[0])
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(NSImage(data: data)?.size == NSSize(width: 4, height: 3))
    }

    @Test func secondImageInSameSecondGetsNewName() throws {
        let now = Date()
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        pb.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        let a = try #require(PasteboardFiles.filesToPaste(from: pb, now: now))
        let b = try #require(PasteboardFiles.filesToPaste(from: pb, now: now))
        defer { (a + b).forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(a != b)
    }
}
