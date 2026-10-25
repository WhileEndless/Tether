import AppKit
import MonitorKit

/// Saves exported monitoring data (command history, connections, traffic, problems) to a file the
/// user picks, with a format menu when there is a choice. The folder and format are remembered;
/// the file is rendered and written off the main thread. The save panel asks before replacing a file.
@MainActor
enum ExportPanel {
    private static let directoryKey = "export.directory"
    private static let formatKey = "export.format"

    static func save(title: String, baseName: String, formats: [MonitorExport.Format] = [.csv],
                     render: @escaping @Sendable (MonitorExport.Format) -> Data) {
        let panel = NSSavePanel()
        panel.title = title
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let path = UserDefaults.standard.string(forKey: directoryKey) {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        var format = MonitorExport.Format(rawValue: UserDefaults.standard.string(forKey: formatKey) ?? "") ?? formats[0]
        if !formats.contains(format) { format = formats[0] }
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        let target = FormatTarget(panel: panel, formats: formats, baseName: baseName)
        if formats.count > 1 {
            popup.addItems(withTitles: formats.map(\.title))
            popup.selectItem(at: formats.firstIndex(of: format) ?? 0)
            popup.target = target
            popup.action = #selector(FormatTarget.changed(_:))
            let stack = NSStackView(views: [NSTextField(labelWithString: "Format:"), popup])
            stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            panel.accessoryView = stack
        }
        panel.nameFieldStringValue = MonitorExport.suggestedName(baseName, format: format)

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            _ = target   // kept alive while the panel is open
            guard response == .OK, let url = panel.url else { return }
            let chosen = formats.count > 1 ? formats[max(0, popup.indexOfSelectedItem)] : format
            UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: directoryKey)
            UserDefaults.standard.set(chosen.rawValue, forKey: formatKey)
            Task.detached(priority: .utility) {
                do {
                    try render(chosen).write(to: url, options: [.atomic])
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

    /// Plain text (the problems list).
    static func saveText(title: String, baseName: String, text: String) {
        let panel = NSSavePanel()
        panel.title = title
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        if let path = UserDefaults.standard.string(forKey: directoryKey) {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        panel.nameFieldStringValue = (MonitorExport.suggestedName(baseName, format: .csv) as NSString).deletingPathExtension + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: directoryKey)
        do { try Data(text.utf8).write(to: url, options: [.atomic]) } catch { NSAlert(error: error).runModal() }
    }

    /// Keeps the file name's extension in step with the chosen format.
    private final class FormatTarget: NSObject {
        let panel: NSSavePanel
        let formats: [MonitorExport.Format]
        let baseName: String
        private var current: MonitorExport.Format?

        init(panel: NSSavePanel, formats: [MonitorExport.Format], baseName: String) {
            self.panel = panel
            self.formats = formats
            self.baseName = baseName
        }

        /// The suggested name follows the format; a name the user typed keeps its text and only
        /// changes its extension.
        @MainActor @objc func changed(_ sender: NSPopUpButton) {
            let format = formats[max(0, sender.indexOfSelectedItem)]
            let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
            let suggested = formats.map { (MonitorExport.suggestedName(baseName, format: $0) as NSString).deletingPathExtension }
            panel.nameFieldStringValue = suggested.contains(name)
                ? MonitorExport.suggestedName(baseName, format: format)
                : name + "." + format.fileExtension
            current = format
        }
    }
}
