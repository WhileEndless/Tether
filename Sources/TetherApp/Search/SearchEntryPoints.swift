import SwiftUI
import SessionKit

struct SearchInSessionButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let session: TerminalSession

    var body: some View {
        Button("Search in Session…") {
            model.searchPreset = SearchPreset(host: nil, session: session.id)
            openWindow(id: "search")
        }
    }
}
