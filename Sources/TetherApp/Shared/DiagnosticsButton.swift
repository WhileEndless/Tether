import SwiftUI
import MonitorKit

/// A small warning sign when something could not be found out (a failed look, a missing tool);
/// a click shows what happened, to read or copy. Nothing appears while all is well, and nothing
/// is ever printed into a terminal.
struct DiagnosticsButton: View {
    let log: DiagnosticLog
    let clear: () -> Void
    @State private var showing = false

    var body: some View {
        if !log.isEmpty {
            Button { showing.toggle() } label: {
                Label("\(log.count)", systemImage: "exclamationmark.triangle")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .help("Problems while looking at the host — click for details")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Problems").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(log.entries.reversed()) { e in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.message).font(.callout).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text("\(e.source) · \(e.last.formatted(date: .omitted, time: .standard))"
                                         + (e.count > 1 ? " · \(e.count) times since \(e.first.formatted(date: .omitted, time: .shortened))" : ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                    HStack {
                        Button("Copy All") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(log.text, forType: .string)
                        }
                        Button("Save…") {
                            let text = log.text
                            showing = false
                            ExportPanel.saveText(title: "Save Problems", baseName: "tether-problems", text: text)
                        }
                        Spacer()
                        Button("Clear") { clear(); showing = false }
                    }
                }
                .padding(12)
                .frame(width: 360)
            }
        }
    }
}
