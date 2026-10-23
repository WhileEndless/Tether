import AppKit
import SwiftUI
import TetherCore
import SessionKit

/// Shared tab-bar state: the ⌘-held number overlay and tab dragging between windows.
@MainActor
@Observable
final class TabBarCenter {
    static let shared = TabBarCenter()
    /// True while ⌘ is held: tabs show the number to press.
    private(set) var showNumbers = false
    @ObservationIgnored private var dragging: UUID?
    @ObservationIgnored private var dropHandled = false
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var numberTimer: DispatchWorkItem?

    func start() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            MainActor.assumeIsolated { TabBarCenter.shared.modifiersChanged(event.modifierFlags) }
            return event
        }) { monitors.append(m) }
    }

    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let commandOnly = flags.intersection([.command, .option, .control, .shift]) == .command
        numberTimer?.cancel()
        if commandOnly {
            // Show after a short hold so normal ⌘ shortcuts do not flash the numbers.
            let work = DispatchWorkItem { MainActor.assumeIsolated { TabBarCenter.shared.showNumbers = true } }
            numberTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        } else if showNumbers {
            showNumbers = false
        }
    }

    // MARK: Dragging

    func beginDrag(_ id: UUID) {
        dragging = id
        dropHandled = false
        watchForDropOutside()
    }

    /// Drops onto a tab bar: move the tab into that window, before `before` (or at the end).
    func drop(_ id: UUID, into workspace: UUID, before: UUID?) {
        dropHandled = true
        guard id != before else { return }
        AppModel.shared.workspaces.add(id, to: workspace, select: true, before: before)
    }

    /// SwiftUI has no "drag ended without a drop" callback; poll the mouse button instead.
    /// A tab released outside every tab bar opens in a new window.
    private func watchForDropOutside() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, let id = self.dragging else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 { self.watchForDropOutside(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                defer { self.dragging = nil }
                guard !self.dropHandled else { return }
                let point = NSEvent.mouseLocation
                // Released inside a Tether window: not a "drag out".
                if NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(point) }) { return }
                let store = AppModel.shared.workspaces
                let ws = UUID()
                store.add(id, to: ws)
                store.openWindow?(ws)
            }
        }
    }
}

/// The tabs of this window.
struct TabStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    @State private var center = TabBarCenter.shared
    @State private var dropTargeted = false

    var body: some View {
        let tabs = state.items
        let selected = state.workspace.selected
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(tabs.enumerated()), id: \.element.id) { index, item in
                            switch item {
                            case .terminal(let session):
                                TabChip(session: session, number: index + 1, isSelected: session.id == selected,
                                        showNumber: center.showNumbers && index < 9)
                                    .id(session.id)
                            case .files(let tab):
                                FileTabChip(tab: tab, number: index + 1, isSelected: tab.id == selected,
                                            showNumber: center.showNumbers && index < 9)
                                    .id(tab.id)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                }
                .onChange(of: selected) { _, id in
                    if let id { withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id) } }
                }
            }
            Button {
                state.showQuickConnect = true
            } label: {
                Image(systemName: "plus").frame(width: 26, height: 24)
            }
            .buttonStyle(.borderless)
            .help("New connection (⌘N)")
            .padding(.trailing, 6)
        }
        .frame(height: 36)
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : .clear)
        .background(.bar)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            center.drop(id, into: state.workspaceID, before: nil)
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}

private struct TabChip: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let session: TerminalSession
    let number: Int
    let isSelected: Bool
    let showNumber: Bool
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @State private var dropTargeted = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if showNumber {
                    Text("\(number)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.accentColor))
                } else {
                    StatusDot(phase: session.phase, size: 6)
                }
            }
            .frame(width: 16, height: 16)

            if let c = session.descriptor.color.color {
                RoundedRectangle(cornerRadius: 1.5).fill(c).frame(width: 3, height: 14)
            }

            if editing {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .frame(width: 150)
                    .focused($fieldFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { editing = false }
                    .onChange(of: fieldFocused) { _, focused in if !focused { commitRename() } }
            } else {
                Text(session.displayTitle)
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
                    .foregroundStyle(session.phase.isDead ? .secondary : .primary)
            }

            Button {
                state.closeTab(session)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .opacity(hovering || isSelected ? 0.8 : 0)
            .help("Close tab (⌘W)")
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.primary.opacity(0.12) : hovering ? Color.primary.opacity(0.06) : .clear)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Select on mouse-down for an instant switch; a double-click renames.
        .simultaneousGesture(TapGesture(count: 2).onEnded { startRename() })
        .simultaneousGesture(TapGesture(count: 1).onEnded { if !isSelected { state.select(session) } })
        .contextMenu {
            Button("Rename…") { startRename() }
            Menu("Color") {
                ForEach(TagColor.allCases) { c in
                    Button(c.title) { model.sessions.setColor(session.id, c) }
                }
            }
            Divider()
            Button("Move to New Window") { state.present(session.id, mode: .window) }
            Button("Move to Background") { state.moveToBackground(.terminal(session)) }
            if session.canSuspend {
                Button("Disconnect & Move to Background") { state.disconnectToBackground(session) }
            }
            Button("Browse Files Here") {
                state.openFiles(session.descriptor.target, path: session.currentDirectory)
            }
            Button("Search in Session…") {
                model.searchPreset = SearchPreset(host: nil, session: session.id)
                model.openSearch?()
            }
            Divider()
            Button("Close Tab") { state.closeTab(session) }
            Button("Terminate Session…", role: .destructive) { state.terminate(session) }
        }
        .onDrag {
            TabBarCenter.shared.beginDrag(session.id)
            return NSItemProvider(object: session.id.uuidString as NSString)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)), id != session.id else { return false }
            TabBarCenter.shared.drop(id, into: state.workspaceID, before: session.id)
            return true
        } isTargeted: { dropTargeted = $0 }
        .help("\(session.descriptor.target.displayName) — \(session.phase.label)  ·  double-click to rename")
    }

    private func startRename() {
        draft = session.descriptor.customTitle ? session.descriptor.title : ""
        editing = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commitRename() {
        guard editing else { return }
        editing = false
        model.sessions.rename(session.id, to: draft)
    }
}

/// A file manager tab.
private struct FileTabChip: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    let tab: FileTab
    let number: Int
    let isSelected: Bool
    let showNumber: Bool
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if showNumber {
                    Text("\(number)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.accentColor))
                } else {
                    Image(systemName: "folder.fill").font(.caption).foregroundStyle(.tint)
                }
            }
            .frame(width: 16, height: 16)
            Text("\(model.fileTabs.title(of: tab)) — \(tab.target.displayName)")
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .leading)
            Button {
                state.close(.files(tab))
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .opacity(hovering || isSelected ? 0.8 : 0)
            .help("Close tab (⌘W)")
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.primary.opacity(0.12) : hovering ? Color.primary.opacity(0.06) : .clear)
        }
        .overlay {
            if dropTargeted { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 1.5) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !isSelected { state.select(tab.id) } }
        .contextMenu {
            Button("Open Terminal Here") {
                state.connect(tab.target, directory: model.fileTabs.browser(for: tab).directory)
            }
            Button("Move to New Window") { state.present(tab.id, mode: .window) }
            Button("Move to Background") { state.moveToBackground(.files(tab)) }
            Divider()
            Button("Close Tab") { state.close(.files(tab)) }
        }
        .onDrag {
            TabBarCenter.shared.beginDrag(tab.id)
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)), id != tab.id else { return false }
            TabBarCenter.shared.drop(id, into: state.workspaceID, before: tab.id)
            return true
        } isTargeted: { dropTargeted = $0 }
        .help("Files on \(tab.target.displayName)")
    }
}
