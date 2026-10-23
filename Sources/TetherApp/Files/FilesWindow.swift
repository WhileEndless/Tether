import SwiftUI
import TetherCore

/// A full window file browser (can be made full screen).
struct FilesWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let request: FilesRequest

    var body: some View {
        FileBrowserView(target: request.target, standalone: true, initialPath: request.path) { dir in
            let session = model.sessions.open(request.target, directory: dir)
            openWindow(id: "workspace", value: session.id)
        }
    }
}
