import SwiftUI
import TetherCore
import SessionKit
import SSHTransport

/// Step-by-step view of a connection being made (or re-made), with what is happening right now,
/// and — if it fails — why, and what to do about it.
struct ConnectionProgressCard: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let session: TerminalSession
    let progress: ConnectionProgress
    @State private var showDetails = false
    @State private var confirmRemoveKey = false
    @State private var removingKey = false
    @State private var removeKeyError: String?

    private var failed: Bool { progress.failure != nil && !isRetrying }
    private var isRetrying: Bool { if case .waiting(_, let next) = session.phase { next != nil } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !hops.isEmpty { route }
            steps
            if !failed {
                ProgressView(value: progress.fraction)
                    .animation(.smooth, value: progress.fraction)
            }
            if failed, let change = progress.hostKeyChange {
                hostKeyBox(change)
            } else if let failure = progress.failure {
                failureBox(failure)
            }
            if showDetails { details }
            buttons
        }
        .padding(20)
        .frame(maxWidth: 460)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .shadow(color: .black.opacity(0.15), radius: 20, y: 6)
        .padding(16)   // stays inside narrow terminal panes
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                if failed {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    ProgressView().controlSize(.regular)
                }
            }
            .font(.title2)
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                TimelineView(.periodic(from: progress.startedAt, by: 1)) { context in
                    Text(subtitle(now: context.date)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var title: String {
        let name = session.descriptor.target.displayName
        if failed { return "Could not connect to \(name)" }
        if case .waiting(let attempt, _) = session.phase { return "Reconnecting to \(name) — attempt \(attempt)" }
        if progress.includesRestore { return "Re-attaching to \(name)" }
        return "Connecting to \(name)"
    }

    private func subtitle(now: Date) -> String {
        if case .waiting(_, let next?) = session.phase, failed == false, progress.failure != nil {
            let s = max(Int(next.timeIntervalSince(now).rounded()), 0)
            return "Next try in \(s) s"
        }
        let elapsed = Int(now.timeIntervalSince(progress.startedAt))
        var text = "\(elapsed) s"
        if elapsed >= 12 && !failed {
            text += progress.step == .authenticate
                ? " · waiting for sign-in — check for a password prompt"
                : " · this is taking longer than usual"
        }
        return text
    }

    private var hops: [String] {
        var h = progress.hops
        let final = session.descriptor.target.displayName
        if h.last != final, !session.descriptor.target.isLocal { h.append(final) }
        return h.count > 1 ? h : []
    }

    /// This Mac → jump host(s) → server.
    private var route: some View {
        HStack(spacing: 6) {
            Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
            ForEach(Array(hops.enumerated()), id: \.offset) { i, hop in
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                Text(hop)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(i == hops.count - 1 ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12)))
                    .lineLimit(1)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(progress.steps, id: \.self) { step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    icon(for: step).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.title)
                            .fontWeight(step == progress.step ? .semibold : .regular)
                            .foregroundStyle(step > progress.step ? .secondary : .primary)
                        if step == progress.step {
                            Text(progress.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .contentTransition(.opacity)
                        }
                    }
                }
            }
        }
        .animation(.snappy, value: progress.step)
        .animation(.easeInOut(duration: 0.15), value: progress.detail)
    }

    @ViewBuilder
    private func icon(for step: ConnectionProgress.Step) -> some View {
        if step < progress.step {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if step == progress.step {
            if failed {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.mini)
            }
        } else {
            Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }

    private func failureBox(_ failure: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(failure).fontWeight(.medium)
            if let hint = progress.hint {
                Text(hint).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }

    /// The server's identity changed: same look as other failures, plus the new key and where the old one is.
    private func hostKeyBox(_ change: HostKeyChange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("The server's identity has changed", systemImage: "exclamationmark.shield")
                .fontWeight(.medium)
            Text("Expected if the server was reinstalled or its keys were replaced. Otherwise someone may be intercepting the connection: do not continue, and ask the server's administrator.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let fp = change.fingerprint {
                Text("New key: \(change.keyType.map { "\($0) " } ?? "")\(fp)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            if let removeKeyError {
                Text(removeKeyError).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        .confirmationDialog("Remove the old key for \(change.host)?", isPresented: $confirmRemoveKey) {
            Button("Remove Old Key and Reconnect", role: .destructive) { removeOldKey(change) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only do this if you know why the key changed. The old entry is removed from \(change.knownHostsFile.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "known_hosts") (a copy is kept as known_hosts.old), and Tether then asks you to verify the new key.")
        }
    }

    private func removeOldKey(_ change: HostKeyChange) {
        removingKey = true
        removeKeyError = nil
        Task {
            let error = await change.removeOldKey()
            removingKey = false
            if let error { removeKeyError = error; return }
            retry()
        }
    }

    private func retry() {
        if session.endedByConnectionFailure { session.retryAfterFailure() }
        else if session.phase.isDead { state.connect(session.descriptor.target); model.sessions.close(session.id, killRemote: false) }
        else { session.reconnectNow() }
    }

    private var details: some View {
        ScrollView {
            Text(progress.log.suffix(40).joined(separator: "\n"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 140)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    private var buttons: some View {
        HStack {
            Button(showDetails ? "Hide Details" : "Details") { withAnimation(.snappy) { showDetails.toggle() } }
                .buttonStyle(.borderless)
                .disabled(progress.log.isEmpty)
            Spacer()
            if failed || isRetrying {
                if case .alias(let alias) = session.descriptor.target {
                    Button("Edit Host…") { state.hostEditor = HostEditorRequest(alias: alias) }
                }
                Button("Close") { model.sessions.close(session.id, killRemote: false) }
                if failed, progress.hostKeyChange?.knownHostsFile != nil {
                    // Never the default button: accepting a changed key must be a deliberate choice.
                    Button("Remove Old Key…") { confirmRemoveKey = true }
                        .disabled(removingKey)
                } else {
                    Button("Retry") { retry() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Button("Cancel") { session.cancelConnecting() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}
