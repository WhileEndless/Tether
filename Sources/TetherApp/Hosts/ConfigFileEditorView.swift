import SwiftUI
import TetherCore
import SSHConfigKit

/// Raw editor for the ssh config file, with a backup on every save.
struct ConfigFileEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var original = ""
    @State private var error: String?
    /// The file is there but could not be read: an empty editor saved would replace it.
    @State private var readFailed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("SSH Config").font(.headline)
                    Text(model.settings.resolvedSSHConfigURL.path(percentEncoded: false)
                        .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false), with: "~/"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
            .padding()
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
            HStack {
                Text("\(SSHConfigDocument(text: text).hosts.count) host blocks")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Backups Folder") { NSWorkspace.shared.open(model.configBackupDirectory) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut("s")
                    .prominentGlassButtonStyle()
                    .disabled(text == original || readFailed)
            }
            .padding()
        }
        .frame(width: 720, height: 560)
        .onAppear {
            let url = model.settings.resolvedSSHConfigURL
            if let read = try? String(contentsOf: url, encoding: .utf8) {
                original = read
            } else if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                readFailed = true
                error = "The file could not be read, so it cannot be edited here."
            }
            text = original
        }
    }

    private func save() {
        do {
            let doc = SSHConfigDocument(text: text, sourceURL: model.settings.resolvedSSHConfigURL)
            try SSHConfigLibrary.write(doc, backupDirectory: model.configBackupDirectory)
            model.reloadConfig()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
