import SwiftUI
import TetherCore

/// Edits a ProxyJump chain ("a,user@b:2222,c") as an ordered list of hops.
struct JumpChainEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var chain: String
    var excluding: String = ""
    @State private var custom = ""

    private var hops: [String] {
        chain.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if hops.isEmpty {
                Text("Direct connection (no jump host)").foregroundStyle(.secondary)
            }
            ForEach(Array(hops.enumerated()), id: \.offset) { i, hop in
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 14)
                    Image(systemName: model.aliases.contains(hop) ? "server.rack" : "network")
                        .foregroundStyle(.secondary)
                    Text(hop).lineLimit(1)
                    if !model.aliases.contains(hop) {
                        Text("not saved").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { move(i, by: -1) } label: { Image(systemName: "chevron.up") }
                        .disabled(i == 0)
                    Button { move(i, by: 1) } label: { Image(systemName: "chevron.down") }
                        .disabled(i == hops.count - 1)
                    Button { remove(i) } label: { Image(systemName: "minus.circle") }
                }
                .buttonStyle(.borderless)
            }
            HStack {
                Menu("Add Saved Host") {
                    ForEach(model.ordered(model.hosts).compactMap(\.alias).filter { $0 != excluding && !hops.contains($0) },
                            id: \.self) { a in
                        Button(a) { set(hops + [a]) }
                    }
                }
                .fixedSize()
                TextField("or user@host:port", text: $custom)
                    .onSubmit(addCustom)
                Button("Add", action: addCustom).disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func set(_ list: [String]) { chain = list.joined(separator: ",") }

    private func move(_ i: Int, by d: Int) {
        var l = hops
        let j = i + d
        guard l.indices.contains(j) else { return }
        l.swapAt(i, j)
        set(l)
    }

    private func remove(_ i: Int) {
        var l = hops
        l.remove(at: i)
        set(l)
    }

    private func addCustom() {
        let v = custom.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !v.contains(" ") else { return }
        set(hops + [v])
        custom = ""
    }
}
