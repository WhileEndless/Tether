import SwiftUI
import TetherCore

extension AppModel {
    /// A binding to a security setting: a change that weakens protection (e.g. no Touch ID for saved
    /// passwords, another ssh program) is applied only after the Mac confirms it is its owner, so
    /// someone at an unlocked Mac cannot quietly switch protections off.
    func guardedSetting<Value: Equatable>(_ keyPath: WritableKeyPath<AppSettings, Value>, reason: String,
                                          weakens: @escaping (_ old: Value, _ new: Value) -> Bool) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { new in
                let old = self.settings[keyPath: keyPath]
                guard new != old else { return }
                guard weakens(old, new) else { self.settings[keyPath: keyPath] = new; return }
                Task { @MainActor in
                    if await AppLock.shared.confirmWithSystem(reason) { self.settings[keyPath: keyPath] = new }
                }
            })
    }
}

/// A program or file path setting (ssh, scp, ssh config): shown as text and changed in a small sheet,
/// after the Mac's confirmation — Tether hands passwords to the ssh program it runs.
struct GuardedPathRow: View {
    @Environment(AppModel.self) private var model
    let title: String
    let keyPath: WritableKeyPath<AppSettings, String>
    let placeholder: String
    let defaultValue: String
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(model.settings[keyPath: keyPath].isEmpty ? placeholder : model.settings[keyPath: keyPath])
                    .font(.callout.monospaced())
                    .foregroundStyle(model.settings[keyPath: keyPath] == defaultValue || model.settings[keyPath: keyPath].isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Button("Change…") {
                    draft = model.settings[keyPath: keyPath]
                    editing = true
                }
            }
        }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                Text("Tether gives this program your saved passwords when it asks for them, so only use one you trust. macOS asks for Touch ID or your Mac password to confirm.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField(placeholder, text: $draft).textFieldStyle(.roundedBorder).font(.body.monospaced())
                HStack {
                    Button("Use Default") { draft = defaultValue }
                    Spacer()
                    Button("Cancel", role: .cancel) { editing = false }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        editing = false
                        model.guardedSetting(keyPath, reason: "change the \(title.lowercased())") { _, _ in true }.wrappedValue = value
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                }
            }
            .padding(22)
            .frame(width: 460)
            .appLockCover()
        }
    }
}
