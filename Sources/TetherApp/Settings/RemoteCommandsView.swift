import SwiftUI
import MonitorKit

/// Everything Tether's host panel and running-command features run on a host, with the scripts
/// themselves (from the same constants the app runs, so the list is always current).
struct RemoteCommandsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var shown: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What Runs on Hosts").font(.title2.weight(.semibold))
                Text("Small scripts sent over the existing SSH connection (on this Mac, the local shell). Nothing is installed, and no file is written on the host; streams end by themselves when Tether stops reading them.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Divider()
            List(RemoteCommandCatalog.all) { c in
                VStack(alignment: .leading, spacing: 6) {
                    Text(c.title).font(.headline)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                        row("When", c.when)
                        row("Reads", c.reads)
                        row("Changes", c.changes)
                        row("Ends", c.ends)
                    }
                    .font(.callout)
                    DisclosureGroup(isExpanded: Binding(get: { shown == c.id }, set: { shown = $0 ? c.id : nil })) {
                        script("POSIX sh (Linux, macOS, BSD)", c.posix)
                        if let w = c.windows { script("PowerShell (Windows)", w) }
                        else { Text("Not available on Windows hosts.").font(.caption).foregroundStyle(.secondary) }
                    } label: {
                        Text("Script").font(.callout)
                    }
                }
                .padding(.vertical, 6)
            }
            Divider()
            HStack {
                Text("Also documented in docs/remote-commands.md.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 560)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func script(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { CommandFormat.copy(text) }.buttonStyle(.borderless).controlSize(.small)
            }
            ScrollView(.horizontal) {
                Text(text).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).padding(6)
            }
            .frame(maxHeight: 220)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        }
    }
}
