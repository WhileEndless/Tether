import AppKit
import RecordingKit
import SearchKit
import SessionKit
import TetherCore
import TerminalUI

/// ⌘S: saves the session to a file the user picks — the whole of it (older output from its
/// recording, then what the terminal holds), only what the terminal holds now, or the last command
/// run in it with all it printed. What is chosen first and the folder it opens in come from
/// Settings ▸ Terminal (the Downloads folder unless set). Writing happens off the main thread.
@MainActor
enum SessionSave {
    private static let formatKey = "saveSession.format"

    /// The folder the panel opens in: the one set in Settings, or Downloads.
    static var folder: URL {
        let set = AppModel.shared.settings.saveSessionFolder
        var isDir: ObjCBool = false
        if !set.isEmpty, FileManager.default.fileExists(atPath: set, isDirectory: &isDir), isDir.boolValue {
            return URL(fileURLWithPath: set, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    static func run(_ session: TerminalSession) {
        let recording = session.recordingURL
        let view = TerminalRegistry.shared.existingView(for: session.id)
        let host = session.descriptor.target.displayName
        // The last command's place in the recording (where its line starts), when there is one.
        let lastMark: Int? = {
            guard let recording, let index = session.recordingIndex, index.isExact, let mark = index.marks.last else { return nil }
            let base = index.partLengths.isEmpty ? 0 : index.removedLength(firstPart: RecordingParts.parts(of: recording).first?.number)
            return mark.offset - base >= 0 ? mark.offset - base : nil
        }()
        var available: [SaveSessionContents] = [.whole]
        if view != nil { available.append(.terminal) }
        if lastMark != nil || view?.hasCommandInMemory == true { available.append(.lastCommand) }

        let panel = NSSavePanel()
        panel.title = "Save Session"
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = folder

        let options = Options(panel: panel, available: available, hasRecording: recording != nil,
                              lastMarkInRecording: lastMark != nil, host: host, title: session.displayTitle)
        let wanted = AppModel.shared.settings.saveSessionContents
        options.select(contents: available.contains(wanted) ? wanted : .whole,
                       format: SessionExport.Format(rawValue: AppPaths.defaults.string(forKey: formatKey) ?? "") ?? .text)
        panel.accessoryView = options.view

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { _ = options; return }
            let contents = options.contents
            let format = options.format
            AppPaths.defaults.set(format.rawValue, forKey: formatKey)
            // The screen and the recording's length are taken at the same moment (on the main
            // thread, where output arrives), so nothing is saved twice or mixed in from later.
            var snapshot: (url: URL, length: Int)?
            var start = 0
            var lines: [String] = []
            switch contents {
            case .whole:
                // With a recording, the text comes from it alone, as the terminal showed it: each
                // line once (the screen keeps every redraw of programs such as Claude Code). Without
                // one (a private tab, recording off), from the screen.
                snapshot = session.recordingSnapshot()
                if snapshot == nil, let view { lines = view.logicalText().lines }
            case .terminal:
                lines = view?.logicalText().lines ?? []
            case .lastCommand:
                if let lastMark, let snap = session.recordingSnapshot() {
                    snapshot = snap
                    start = lastMark
                } else {
                    lines = view?.lastCommandText() ?? []
                }
            }
            let source = snapshot
            let from = start
            Task.detached(priority: .utility) {
                do {
                    if format == .raw, let source {
                        try SessionExport.writeRaw(recording: source.url, from: from, length: source.length, to: url)
                    } else {
                        try SessionExport.writeText(recording: source?.url, from: from, length: source?.length, dropLast: 0, lines: lines, to: url)
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

    /// The panel's own choices — what to save and in which form — laid out as a small form, and
    /// the file name kept in step with them.
    @MainActor
    private final class Options: NSObject {
        let panel: NSSavePanel
        let available: [SaveSessionContents]
        let hasRecording: Bool
        let lastMarkInRecording: Bool
        let host: String
        let title: String
        let contentsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let note = NSTextField(wrappingLabelWithString: "")
        let view: NSView

        init(panel: NSSavePanel, available: [SaveSessionContents], hasRecording: Bool, lastMarkInRecording: Bool,
             host: String, title: String) {
            self.panel = panel
            self.available = available
            self.hasRecording = hasRecording
            self.lastMarkInRecording = lastMarkInRecording
            self.host = host
            self.title = title
            contentsPopup.addItems(withTitles: available.map(\.title))
            formatPopup.addItems(withTitles: SessionExport.Format.allCases.map(\.title))
            formatPopup.autoenablesItems = false
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = 380
            let contentsLabel = NSTextField(labelWithString: "Contents:")
            let formatLabel = NSTextField(labelWithString: "Format:")
            let grid = NSGridView(views: [[contentsLabel, contentsPopup], [formatLabel, formatPopup], [NSGridCell.emptyContentView, note]])
            grid.rowSpacing = 8
            grid.columnSpacing = 8
            grid.column(at: 0).xPlacement = .trailing
            grid.rowAlignment = .firstBaseline
            grid.translatesAutoresizingMaskIntoConstraints = false
            let container = NSView()
            container.addSubview(grid)
            NSLayoutConstraint.activate([
                grid.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
                grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
                grid.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
                grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
                contentsPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
                formatPopup.widthAnchor.constraint(equalTo: contentsPopup.widthAnchor),
            ])
            container.frame.size = container.fittingSize
            view = container
            super.init()
            contentsPopup.target = self
            contentsPopup.action = #selector(changed)
            formatPopup.target = self
            formatPopup.action = #selector(changed)
        }

        var contents: SaveSessionContents { available[max(0, contentsPopup.indexOfSelectedItem)] }
        var format: SessionExport.Format {
            let f = SessionExport.Format.allCases[max(0, formatPopup.indexOfSelectedItem)]
            return rawPossible ? f : .text
        }

        /// Raw output is the recording's own bytes: for the whole session, and for the last command
        /// when the recording knows where it starts.
        private var rawPossible: Bool {
            switch contents {
            case .whole: hasRecording
            case .terminal: false
            case .lastCommand: lastMarkInRecording
            }
        }

        func select(contents: SaveSessionContents, format: SessionExport.Format) {
            contentsPopup.selectItem(at: available.firstIndex(of: contents) ?? 0)
            formatPopup.selectItem(at: SessionExport.Format.allCases.firstIndex(of: format) ?? 0)
            update()
        }

        @objc private func changed(_ sender: NSPopUpButton) { update() }

        private func update() {
            formatPopup.item(at: SessionExport.Format.allCases.firstIndex(of: .raw) ?? 1)?.isEnabled = rawPossible
            if !rawPossible { formatPopup.selectItem(at: SessionExport.Format.allCases.firstIndex(of: .text) ?? 0) }
            note.stringValue = switch contents {
            case .whole: hasRecording ? "Everything this session has shown since it started, from its recording, however long."
                : "Nothing is recorded for this tab: what the terminal holds is all there is."
            case .terminal: "The lines the terminal holds now (its scrollback and screen)."
            case .lastCommand: "The last command run in this tab: its line and everything it printed."
            }
            var name = (SessionExport.suggestedName(host: host, title: title, format: format) as NSString).deletingPathExtension
            if contents == .lastCommand { name += " - last command" }
            panel.nameFieldStringValue = name + "." + format.fileExtension
            view.frame.size = view.fittingSize
        }
    }
}
