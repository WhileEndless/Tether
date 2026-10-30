import SwiftUI
import TetherCore

/// A full window file browser (can be made full screen), with Transfers in its toolbar (also ⌥⌘L
/// while it is in front: what its notices point to must be reachable here too).
struct FilesWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let request: FilesRequest
    @State private var showTransfers = false
    @State private var window: NSWindow?

    var body: some View {
        FileBrowserView(target: request.target, standalone: true, initialPath: request.path) { dir in
            let session = model.sessions.open(request.target, directory: dir)
            openWindow(id: "workspace", value: session.id)
        }
        .background(WindowAccessor { window = $0 })
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showTransfers.toggle()
                } label: {
                    Label("Transfers", systemImage: model.transfers.activeCount > 0 ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                }
                .badge(model.transfers.activeCount)
                .help("File transfers (⌥⌘L)")
                .popover(isPresented: $showTransfers, arrowEdge: .bottom) { TransfersView() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleTransfers)) { _ in
            if let window, window.isKeyWindow { showTransfers.toggle() }
        }
    }
}

extension Notification.Name {
    /// Transfers (⌥⌘L) asked for while no workspace window is in front (a Files window is).
    static let toggleTransfers = Notification.Name("tether.toggleTransfers")
}
