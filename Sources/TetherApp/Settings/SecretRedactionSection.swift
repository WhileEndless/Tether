import SwiftUI
import RecordingKit
import TetherCore

/// Settings ▸ Security ▸ Secrets in the Archive: which secrets are masked in recordings once their
/// session is archived — the built-in formats (each can be switched off) and the user's own rules.
struct SecretRedactionSection: View {
    @Environment(AppModel.self) private var model
    @State private var sample = ""
    @State private var editing: SecretRule?
    @State private var reapplied = false

    var body: some View {
        @Bindable var store = model.settingsStore
        let config = store.settings.secretRedaction
        Section {
            Toggle("Mask secrets in archived sessions",
                   isOn: model.guardedSetting(\.secretRedaction.enabled, reason: "stop masking secrets in the archive") { _, new in !new })
            if config.enabled {
                DisclosureGroup("Built-in patterns (\(SecretRule.builtIn.count - config.disabledBuiltIns.count) of \(SecretRule.builtIn.count) on)") {
                    ForEach(SecretRule.builtIn) { rule in
                        Toggle(isOn: Binding(
                            get: { !store.settings.secretRedaction.disabledBuiltIns.contains(rule.id) },
                            set: { on in
                                if on { store.settings.secretRedaction.disabledBuiltIns.remove(rule.id) }
                                else { store.settings.secretRedaction.disabledBuiltIns.insert(rule.id) }
                            })) {
                            RuleLabel(rule: rule)
                        }
                    }
                }
                ForEach($store.settings.secretRedaction.custom) { $rule in
                    HStack {
                        Toggle(isOn: $rule.enabled) { RuleLabel(rule: rule) }
                        Button("Edit") { editing = rule }
                        Button(role: .destructive) {
                            store.settings.secretRedaction.custom.removeAll { $0.id == rule.id }
                        } label: { Image(systemName: "trash") }
                        .help("Remove this rule")
                    }
                    .buttonStyle(.borderless)
                }
                HStack {
                    Button("Add Rule…") { editing = SecretRule(name: "", pattern: "") }
                    Spacer()
                    Button(reapplied ? "Masking the Archive…" : "Apply to the Whole Archive Again") {
                        model.sessions.redactArchive(again: true)
                        reapplied = true
                        Task { try? await Task.sleep(for: .seconds(2)); reapplied = false }
                    }
                    .disabled(reapplied)
                    .help("Runs the current rules over every archived recording (new rules do not change recordings already archived until then)")
                }
                TextField("Try it: paste a line of output", text: $sample, axis: .vertical)
                    .font(.callout.monospaced())
                    .lineLimit(1...4)
                if !sample.isEmpty {
                    let out = SecretRedactor(rules: config.activeRules).redact(sample)
                    Text(out == sample ? "Nothing would be masked." : out)
                        .font(.callout.monospaced())
                        .foregroundStyle(out == sample ? .secondary : .primary)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Secrets in the Archive")
        } footer: {
            Text("When a session ends and goes to the archive, API keys, tokens, private keys and passwords that look like the patterns above are masked in its recording (`[REDACTED****]`, as long as the secret was), so they do not stay in the history, search and exports. Open sessions are not changed. This is a safety net: a secret in an unusual format, split by colors or a line break, or shown elsewhere (the server's own history, other apps) is not caught. Rules are regular expressions matched on each line; with a group named `secret`, as in `password=(?<secret>\\S+)`, only that part is masked.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule) { saved in
                var list = store.settings.secretRedaction.custom
                if let i = list.firstIndex(where: { $0.id == saved.id }) { list[i] = saved } else { list.append(saved) }
                store.settings.secretRedaction.custom = list
            }
        }
    }

    private struct RuleLabel: View {
        let rule: SecretRule
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name.isEmpty ? "Untitled rule" : rule.name)
                Text(rule.pattern + (rule.endPattern.map { "  …  " + $0 } ?? ""))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let problem = rule.problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    /// Adding or changing a rule of the user's, tried on a sample before it is saved.
    private struct RuleEditor: View {
        @Environment(\.dismiss) private var dismiss
        @State var rule: SecretRule
        let save: (SecretRule) -> Void
        @State private var sample = ""
        @State private var isBlock = false

        init(rule: SecretRule, save: @escaping (SecretRule) -> Void) {
            _rule = State(initialValue: rule)
            _isBlock = State(initialValue: rule.endPattern != nil)
            self.save = save
        }

        var body: some View {
            Form {
                TextField("Name", text: $rule.name, prompt: Text("Internal API token"))
                TextField("Pattern", text: $rule.pattern, prompt: Text(#"tok_[A-Za-z0-9]{32}"#))
                    .font(.body.monospaced())
                Toggle("Masks a block of lines (from this pattern to an end pattern)", isOn: $isBlock)
                if isBlock {
                    TextField("End pattern", text: Binding(get: { rule.endPattern ?? "" }, set: { rule.endPattern = $0 }),
                              prompt: Text("-----END SECRET-----"))
                        .font(.body.monospaced())
                }
                if let problem = checked.problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                TextField("Try it", text: $sample, prompt: Text("A line with the secret in it"), axis: .vertical)
                    .font(.callout.monospaced())
                    .lineLimit(1...4)
                if !sample.isEmpty, checked.problem == nil {
                    let out = SecretRedactor(rules: [checked]).redact(sample)
                    Text(out == sample ? "Nothing would be masked." : out)
                        .font(.callout.monospaced())
                        .foregroundStyle(out == sample ? .secondary : .primary)
                }
            }
            .formStyle(.grouped)
            .frame(width: 520)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(checked); dismiss() }
                        .disabled(checked.problem != nil || rule.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }

        private var checked: SecretRule {
            var r = rule
            if !isBlock || r.endPattern?.isEmpty == true { r.endPattern = isBlock ? "" : nil }
            return r
        }
    }
}
