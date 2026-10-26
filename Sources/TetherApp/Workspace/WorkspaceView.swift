import SwiftUI
import TetherCore
import SessionKit
import TerminalUI
import SSHTransport

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
        case .dead: return (!session.wasOnline && p.failure != nil) || p.hostKeyChange != nil
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isEnabled(.statusStrip, for: session.descriptor.target) {
                HostStatusStrip(session: session)
            }
            ZStack(alignment: .top) {
                // No keyboard for terminals behind the lock screen; it comes back on unlock.
                TerminalHost(session: session, focused: !AppLock.shared.isLocked, isCurrent: { [workspaceID = state.workspaceID] in
                    AppModel.shared.workspaces.workspace(containing: session.id) == workspaceID
                })
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
                            .glassButtonStyle()
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
            // Keys typed at a password prompt are hidden from other apps (Secure Keyboard Entry).
            .onChange(of: session.passwordPrompt != nil && model.settings.secureKeyboardAtPasswordPrompts, initial: true) { _, asking in
                SecureInput.set(asking, for: session.id)
            }
            .onDisappear { SecureInput.set(false, for: session.id) }
            .animation(.snappy, value: model.uploadBatches[session.id]?.id)
            .animation(.snappy, value: olderHistoryOnDisk)
            .animation(.smooth(duration: 0.25), value: session.progress == nil)
            SessionFooter(session: session)
        }
        .onDisappear { session.isOnScreen = false }
        .onAppear {
            session.isOnScreen = true
            if session.attention != nil { Notifier.shared.seen(session) }
            let view = TerminalRegistry.shared.view(for: session)
            view.onReachedHistoryLimit = { at in olderHistoryOnDisk = at }
            // Scrolling past what is in memory reads earlier output back from the recording.
            view.historySource = session.recordingURL == nil ? nil : { [weak session] in session?.flushedRecordingURL() }
            view.onFiles = { [weak state] urls in
                guard let state else { return }
                AppModel.shared.handleFiles(urls, for: session, in: state)
            }
            view.onClick = { [weak state] in state?.follow(session) }
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
                            Text(session.retryPausedReason != nil || session.waitsForUser ? "Not connected" : "Waiting for connection").fontWeight(.semibold)
                            Group {
                                if let next {
                                    Text("Attempt \(attempt) · retrying \(next, style: .relative)")
                                } else if session.retryPausedReason != nil || session.waitsForUser {
                                    Text("Attempt \(attempt) · waiting for you")
                                } else {
                                    Text("Attempt \(attempt) · automatic retry is off")
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            if let err = session.lastError {
                                Text(err).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(session.retryPausedReason != nil ? 2 : 1)
                                    .help(err)
                            }
                        }
                        Button("Reconnect Now") { session.reconnectNow() }
                            .glassButtonStyle()
                        Button("Close") { state.closeTab(session) }
                            .glassButtonStyle()
                            .help("Close this tab (a tmux or screen session keeps running on the server)")
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
                            .prominentGlassButtonStyle()
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
                        Button("New Session") { state.connect(session.descriptor.target, isPrivate: session.descriptor.isPrivate) }
                            .prominentGlassButtonStyle()
                        Button("Close") { state.closeTab(session) }
                            .glassButtonStyle()
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
    @Environment(WindowState.self) private var state
    let session: TerminalSession

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                StatusDot(phase: session.phase, size: 6)
                Text(session.phase.label)
            }
            .fixedSize()
            .help("Connection state of this terminal")
            // The host status bar already shows latency; only repeat it here when that bar is hidden.
            if !model.settings.showStatusStrip, session.phase.isOnline, let median = session.latency.median {
                Label("Latency \(LatencyStats.format(median)) · \(session.latency.quality.rawValue)", systemImage: "antenna.radiowaves.left.and.right")
                    .help("Round-trip time to the server" + (session.latency.jitter.map { ", jitter \(LatencyStats.format($0))" } ?? ""))
                    .contentTransition(.numericText())
            }
            // Narrow windows keep just the icon (the text is in its tooltip).
            ViewThatFits(in: .horizontal) {
                Label(persistenceText, systemImage: persistenceIcon).fixedSize()
                Image(systemName: persistenceIcon)
            }
            .help(persistenceHelp)
            // Only an icon: whether output is kept on this Mac (the tooltip says where to change it).
            if session.descriptor.isPrivate {
                Image(systemName: "eye.slash").foregroundStyle(.secondary)
                    .help("Private tab: no recording, archive or command history is kept")
            } else if session.recordingURL != nil {
                Image(systemName: "record.circle").foregroundStyle(.red.opacity(0.8))
                    .help("This terminal's output is recorded on this Mac (Settings ▸ Recordings; ⌥⇧⌘T opens a private tab)")
            }
            CommandStatsPill(session: session)
            Spacer()
            // The terminal's folder, one click from a file manager there (⌘E). A real button, so it
            // reads as one and is never squeezed away by the labels beside it.
            Button {
                state.browse(session.descriptor.target, path: session.currentDirectory)
            } label: {
                Label(session.currentDirectory.map(folderName).map { "Browse \($0)" } ?? "Browse Files",
                      systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .disabled(session.phase.isDead)
            .help(state.browsesInFinder(session.descriptor.target)
                  ? "Open \(session.currentDirectory ?? "the home folder") in Finder (⌘E)"
                  : "Open a file manager tab in \(session.currentDirectory ?? "the home folder") (⌘E)")
            Text(session.descriptor.target.displayName).foregroundStyle(.secondary)
                .truncationMode(.middle)
                .help("Host of this terminal")
        }
        .lineLimit(1)
        .font(.caption)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    /// "~" for home-like paths, else the last folder name ("/" stays "/").
    private func folderName(_ path: String) -> String {
        if path == "/" { return "/" }
        if path == "~" || path.hasSuffix("/~") { return "~" }
        let name = (path as NSString).lastPathComponent
        let short = name.isEmpty ? path : name
        return short.count > 24 ? short.prefix(23) + "…" : short
    }

    private var persistenceText: String {
        switch session.persistence {
        case .tmux: "Persistent (tmux)"
        case .screen: "Persistent (screen)"
        case .plain: "Not persistent"
        case .unknown: "Negotiating…"
        }
    }

    /// What persistence means for this tab, in words a user can act on.
    private var persistenceHelp: String {
        switch session.persistence {
        case .tmux, .screen:
            "\(persistenceText): the shell keeps running on the server when the connection drops, the Mac sleeps or the tab is closed in the background; Tether reattaches and adds what was printed meanwhile."
        case .plain:
            session.platform.isWindows
                ? "Not persistent: Windows has no tmux or screen, so the shell ends when the connection drops or the tab is closed. What it printed stays in the recording."
                : PlatformCache.shared.isDevice(session.descriptor.target.key)
                ? "Not persistent: this is a network device or limited shell, so the session ends when the connection drops. Monitoring and background features are off here."
                : "Not persistent: the server has no tmux or screen (or the host is set to a plain shell), so the shell ends when the connection drops, the Mac sleeps long or the tab is closed. What it printed stays in the recording; running commands stop. Install tmux on the server, or set the host's persistence, to keep shells running."
        case .unknown:
            "Finding out whether the server can keep the shell running (tmux or screen)…"
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
