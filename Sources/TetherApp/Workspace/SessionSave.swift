import AppKit
import SearchKit
import SessionKit
import TerminalUI

/// ⌘S: saves the whole session — older output from its recording, then what the terminal holds —
/// to a file the user picks. The folder is remembered; writing happens off the main thread.
@MainActor
enum SessionSave {
    private static let directoryKey = "saveSession.directory"
    private static let formatKey = "saveSession.format"

    static func run(_ session: TerminalSession) {
        let hasRecording = session.recordingURL != nil
        let view = TerminalRegistry.shared.existingView(for: session.id)
        let host = session.descriptor.target.displayName

        let panel = NSSavePanel()
        panel.title = "Save Session"
        panel.message = "Everything this session has shown, including output no longer on screen."
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let path = UserDefaults.standard.string(forKey: directoryKey) {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        // Raw output needs the recording; without one only plain text is offered.
        let formats = hasRecording ? SessionExport.Format.allCases : [SessionExport.Format.text]
        var format = SessionExport.Format(rawValue: UserDefaults.standard.string(forKey: formatKey) ?? "") ?? .text
        if !formats.contains(format) { format = .text }
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: formats.map(\.title))
        popup.selectItem(at: formats.firstIndex(of: format) ?? 0)
        let target = FormatTarget(panel: panel, formats: formats, host: host, title: session.displayTitle)
        popup.target = target
        popup.action = #selector(FormatTarget.changed(_:))
        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, popup])
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = stack
        panel.nameFieldStringValue = SessionExport.suggestedName(host: host, title: session.displayTitle, format: format)

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            _ = target   // kept alive while the panel is open
            guard response == .OK, let url = panel.url else { return }
            let chosen = formats[max(0, popup.indexOfSelectedItem)]
            UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: directoryKey)
            UserDefaults.standard.set(chosen.rawValue, forKey: formatKey)
            // The screen and the recording's length are taken at the same moment (on the main
            // thread, where output arrives), so nothing is saved twice or mixed in from later.
            let snapshot = session.recordingSnapshot()
            var lines: [String] = []
            var dropLast = 0
            var source = snapshot
            if chosen == .text, let view {
                if view.showsAlternateScreen && snapshot != nil {
                    // A full-screen program is up: the session's text is all in the recording.
                } else {
                    let (trimmed, text, logical) = view.logicalText()
                    lines = text
                    // Nothing was trimmed from memory: the scrollback alone is the whole session.
                    if trimmed { dropLast = logical } else { source = nil }
                }
            }
            Task.detached(priority: .utility) {
                do {
                    switch chosen {
                    case .text: try SessionExport.writeText(recording: source?.url, length: source?.length, dropLast: dropLast, lines: lines, to: url)
                    case .raw: if let source { try SessionExport.writeRaw(recording: source.url, length: source.length, to: url) }
                    }
                } catch {
                    _ = await MainActor.run { NSAlert(error: error).runModal() }
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Keeps the file name's extension in step with the chosen format.
    @MainActor
    private final class FormatTarget: NSObject {
        let panel: NSSavePanel
        let formats: [SessionExport.Format]
        let host: String
        let title: String

        init(panel: NSSavePanel, formats: [SessionExport.Format], host: String, title: String) {
            self.panel = panel
            self.formats = formats
            self.host = host
            self.title = title
        }

        @objc func changed(_ sender: NSPopUpButton) {
            let format = formats[max(0, sender.indexOfSelectedItem)]
            let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = name + "." + format.fileExtension
        }
    }
}
