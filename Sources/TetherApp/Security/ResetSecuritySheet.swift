import SwiftUI

/// Starting over when the Tether password is not known: written confirmation, then the Mac's own
/// check (Touch ID or the Mac password). What goes and what stays is said plainly first.
struct ResetSecuritySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var failed = false
    @State private var busy = false

    static let word = "RESET"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Reset the Tether Password", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("Use this only if you do not know the Tether password. Without it, encrypted recordings cannot be opened by anyone — so they are deleted.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Label("Deleted: the Tether password and every encrypted recording", systemImage: "trash")
                Label("Turned off: App Lock and recording encryption", systemImage: "lock.open")
                Label("Kept: sessions (local and on servers), hosts, saved SSH passwords, settings and plain recordings", systemImage: "checkmark.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            TextField("Type \(Self.word) to confirm", text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
            Text("macOS then asks for Touch ID or your Mac password.").font(.caption).foregroundStyle(.secondary)
            if failed { Text("Not reset: the Mac did not confirm it is you.").font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Reset", role: .destructive) {
                    busy = true
                    Task {
                        let ok = await AppLock.shared.resetForgottenPassword()
                        busy = false
                        if ok { dismiss() } else { failed = true }
                    }
                }
                .disabled(typed != Self.word || busy)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
