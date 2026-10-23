import SwiftUI
import TetherCore
import SessionKit
import TerminalUI

/// The window's content: its terminal, or the welcome screen when the window has no session.
struct WorkspaceView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state

    var body: some View {
        switch state.selectedItem {
        case .terminal(let session)?:
            SessionPane(session: session)
                .id(session.id)
        case .files(let tab)?:
            FilesPane(tab: tab)
                .id(tab.id)
        case nil:
            WelcomeView()
        }
    }
}

/// A terminal with its status banner and footer.
struct SessionPane: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    @Environment(\.openWindow) private var openWindow
    let session: TerminalSession
    @State private var olderHistoryOnDisk = false
    @State private var dismissedPrompt: PasswordPrompt?

    /// The full progress card for first connections, re-attaching after relaunch and failures;
    /// quick reconnects of an established session use the small banner instead.
    private var showsProgressCard: Bool {
        guard let p = session.progress else { return false }
        switch session.phase {
        case .connecting: return true
        case .waiting: return p.failure != nil || !session.wasOnline || p.includesRestore
        case .dead: return !session.wasOnline && p.failure != nil
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.settings.showStatusStrip {
                HostStatusStrip(session: session)
            }
            ZStack(alignment: .top) {
                TerminalHost(session: session)
                    .padding(.leading, 6)
                    .background(TerminalBackground(settings: model.settings))
                if let progress = session.progress, showsProgressCard {
                    ConnectionProgressCard(session: session, progress: progress)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.08))
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    SessionBanner(session: session)
                        .padding(.top, 10)
                }
                if olderHistoryOnDisk, let url = session.flushedRecordingURL() {
                    GlassPill {
                        HStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                            Text("Earlier output is saved on disk")
                            Button("Open Full History") {
                                openWindow(id: "transcript", value: TranscriptRequest(path: url.path, revealFraction: 1))
                            }
                            .buttonStyle(.glass)
                        }
                    }
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                if let find = model.terminalFind[session.id] {
                    TerminalFindBar(session: session, find: find)
                        .padding(.top, 10)
                        .padding(.trailing, 24)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: model.terminalFind[session.id])
            .overlay(alignment: .bottom) {
                if let batch = model.uploadBatches[session.id] {
                    UploadBatchPill(batch: batch).padding(.bottom, 14)
                } else if let prompt = session.passwordPrompt, prompt != dismissedPrompt {
                    PasswordPromptBar(session: session, prompt: prompt, dismissed: $dismissedPrompt).padding(.bottom, 14)
                }
            }
            .animation(.snappy, value: session.passwordPrompt)
            .animation(.snappy, value: model.uploadBatches[session.id]?.id)
            .animation(.snappy, value: olderHistoryOnDisk)
            .animation(.smooth(duration: 0.25), value: session.progress == nil)
            SessionFooter(session: session)
        }
        .onDisappear { session.isOnScreen = false }
        .onAppear {
            session.isOnScreen = true
            let view = TerminalRegistry.shared.view(for: session)
            view.onReachedHistoryLimit = { at in olderHistoryOnDisk = at }
            // Scrolling past what is in memory reads earlier output back from the recording.
            view.historySource = session.recordingURL == nil ? nil : { [weak session] in session?.flushedRecordingURL() }
            view.onFiles = { [weak state] urls in
                guard let state else { return }
                AppModel.shared.handleFiles(urls, for: session, in: state)
            }
        }
    }
}

/// Floating status pill shown while connecting, waiting or after the session died.
struct SessionBanner: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let session: TerminalSession

    var body: some View {
        Group {
            switch session.phase {
            case .online:
                EmptyView()
            case .connecting:
                GlassPill {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Connecting to \(session.descriptor.target.displayName)…")
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            case .waiting(let attempt, let next):
                GlassPill {
                    HStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Waiting for connection").fontWeight(.semibold)
                            Group {
                                if let next {
                                    Text("Attempt \(attempt) · retrying \(next, style: .relative)")
                                } else {
                                    Text("Attempt \(attempt) · automatic retry is off")
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            if let err = session.lastError {
                                Text(err).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Button("Reconnect Now") { session.reconnectNow() }
                            .buttonStyle(.glass)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            case .suspended:
                GlassPill {
                    HStack(spacing: 10) {
                        Image(systemName: "pause.circle.fill").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Disconnected").fontWeight(.semibold)
                            Text("The session keeps running on the server.").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Reconnect") { session.resume() }
                            .buttonStyle(.glassProminent)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            case .dead(let reason):
                GlassPill {
                    HStack(spacing: 10) {
                        Image(systemName: "bolt.horizontal.circle").foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Session ended").fontWeight(.semibold)
                            Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Button("New Session") { state.connect(session.descriptor.target) }
                            .buttonStyle(.glassProminent)
                        Button("Close") { state.closeTab(session) }
                            .buttonStyle(.glass)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: session.phase)
    }
}

struct SessionFooter: View {
    @Environment(AppModel.self) private var model
    let session: TerminalSession

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                StatusDot(phase: session.phase, size: 6)
                Text(session.phase.label)
            }
            // The host status bar already shows latency; only repeat it here when that bar is hidden.
            if !model.settings.showStatusStrip, session.phase.isOnline, let median = session.latency.median {
                Label("Latency \(LatencyStats.format(median)) · \(session.latency.quality.rawValue)", systemImage: "antenna.radiowaves.left.and.right")
                    .help("Round-trip time to the server" + (session.latency.jitter.map { ", jitter \(LatencyStats.format($0))" } ?? ""))
                    .contentTransition(.numericText())
            }
            Label(persistenceText, systemImage: persistenceIcon)
            if session.recordingURL != nil {
                Label("Recording", systemImage: "record.circle").foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.descriptor.target.displayName).foregroundStyle(.secondary)
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var persistenceText: String {
        switch session.persistence {
        case .tmux: "Persistent (tmux)"
        case .screen: "Persistent (screen)"
        case .plain: "Not persistent"
        case .unknown: "Negotiating…"
        }
    }

    private var persistenceIcon: String {
        switch session.persistence {
        case .tmux, .screen: "lock.shield"
        case .plain: "exclamationmark.shield"
        case .unknown: "ellipsis.circle"
        }
    }
}

/// A file manager tab: a full file browser for one host, keeping its state across tab switches.
struct FilesPane: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let tab: FileTab

    var body: some View {
        FileBrowserView(target: tab.target, standalone: true, initialPath: tab.path,
                        openTerminal: { dir in state.connect(tab.target, directory: dir) },
                        external: model.fileTabs.browser(for: tab))
    }
}
