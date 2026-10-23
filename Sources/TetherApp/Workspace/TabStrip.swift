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
    /// The tab being dragged (dimmed in its bar while the others make room).
    private(set) var dragging: UUID?
    @ObservationIgnored private var dropHandled = false
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var numberTimer: DispatchWorkItem?

    func start() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            MainActor.assumeIsolated { TabBarCenter.shared.modifiersChanged(event.modifierFlags) }
            return event
        }) { monitors.append(m) }
        // A mouse wheel scrolls the tab bar sideways; the middle button closes the tab under it.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .otherMouseUp], handler: { event in
            nonisolated(unsafe) let e = event   // local monitors run on the main thread
            let consumed = MainActor.assumeIsolated { TabBarCenter.shared.handle(e) }
            return consumed ? nil : event
        }) { monitors.append(m) }
    }

    // MARK: Wheel and middle click

    /// Tab frames in their window (top-left origin), for the middle click.
    @ObservationIgnored var tabFrames: [UUID: CGRect] = [:]
    /// The tab bars' scroll views (found through a marker view inside each one).
    @ObservationIgnored private var scrollViews: [ObjectIdentifier: WeakScroll] = [:]
    private struct WeakScroll { weak var view: NSScrollView? }

    func register(_ scrollView: NSScrollView) {
        scrollViews[ObjectIdentifier(scrollView)] = WeakScroll(view: scrollView)
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        if event.type == .otherMouseUp {
            guard event.buttonNumber == 2, let content = window.contentView else { return false }
            let p = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            return closeTab(at: p, in: window)
        }
        // Vertical wheel over a tab bar → horizontal scrolling (trackpads already scroll sideways).
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return false }
        let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        return scrollTabs(by: step, at: event.locationInWindow, in: window)
    }

    /// Closes the tab at a point in window coordinates (top-left origin). True if there was one.
    func closeTab(at point: CGPoint, in window: NSWindow) -> Bool {
        guard let state = AppModel.shared.workspaces.state(of: window),
              let item = state.items.first(where: { tabFrames[$0.id]?.contains(point) == true }) else { return false }
        state.close(item)
        return true
    }

    /// Scrolls the tab bar under a point (window coordinates, bottom-left origin) sideways.
    func scrollTabs(by delta: CGFloat, at location: CGPoint, in window: NSWindow) -> Bool {
        for case let scroll? in scrollViews.values.map(\.view) where scroll.window === window {
            let local = scroll.convert(location, from: nil)
            guard scroll.bounds.contains(local) else { continue }
            let clip = scroll.contentView
            let docWidth = scroll.documentView?.frame.width ?? 0
            let maxX = max(docWidth - clip.bounds.width, 0)
            let x = min(max(clip.bounds.origin.x - delta, 0), maxX)
            clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
            scroll.reflectScrolledClipView(clip)
            return true
        }
        return false
    }

    /// The tab bar's current horizontal offset in a window (for tests).
    func tabScrollOffset(in window: NSWindow) -> CGFloat? {
        scrollViews.values.compactMap(\.view).first { $0.window === window }?.contentView.bounds.origin.x
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
        let store = AppModel.shared.workspaces
        // Within its own window the tab was already reordered live while dragging: leave it there.
        if store.workspace(containing: id) == workspace { return }
        store.add(id, to: workspace, select: true, before: before)
    }

    /// The dragged tab passes the middle of `target` in the same window: it takes that place, and
    /// the tabs in between slide over (animated), as in Safari. `x` is the pointer within `target`.
    /// Waiting for the middle keeps tabs of different widths from swapping back and forth.
    func dragMoved(over target: UUID, x: CGFloat, in workspace: UUID) {
        let store = AppModel.shared.workspaces
        guard let id = dragging, id != target, store.workspace(containing: id) == workspace else { return }
        let tabs = store.workspace(workspace).tabs
        guard let from = tabs.firstIndex(of: id), let to = tabs.firstIndex(of: target) else { return }
        let middle = (tabFrames[target]?.width ?? 0) / 2
        guard from < to ? x >= middle : x <= middle else { return }
        withAnimation(.snappy(duration: 0.22)) {
            _ = AppModel.shared.workspaces.move(id, to: target, in: workspace)
        }
    }

    /// Scrolls an overflowing tab bar while a dragged tab is held over one of its arrows.
    @ObservationIgnored private var edgeScroll: Timer?
    func dragHover(_ scroller: TabScroller?, by delta: CGFloat) {
        edgeScroll?.invalidate()
        edgeScroll = nil
        guard let scroller else { return }
        edgeScroll = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { timer in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 0 { timer.invalidate(); return }
                scroller.scroll(by: delta, animated: false)
            }
        }
    }

    /// SwiftUI has no "drag ended without a drop" callback; poll the mouse button instead.
    /// A tab released outside every tab bar opens in a new window.
    private func watchForDropOutside() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, let id = self.dragging else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 { self.watchForDropOutside(); return }
            self.dragHover(nil, by: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                defer { withAnimation(.snappy(duration: 0.15)) { self.dragging = nil } }
                guard !self.dropHandled else { return }
                let point = NSEvent.mouseLocation
                // Released inside a Tether window: not a "drag out".
                if NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(point) }) { return }
                let store = AppModel.shared.workspaces
                let source = store.workspace(containing: id).flatMap { store.window(of: $0) }
                let ws = UUID()
                store.add(id, to: ws)
                // The new window opens where the tab was dropped: its title bar under the pointer.
                let size = source?.frame.size ?? CGSize(width: 1100, height: 700)
                WindowLayout.place(ws, frame: CGRect(x: point.x - 120, y: point.y - size.height + 20,
                                                     width: size.width, height: size.height))
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

    @State private var contentWidth: CGFloat = 0
    @State private var visibleWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var scroller = TabScroller()

    private var overflowing: Bool { contentWidth > visibleWidth + 1 }

    var body: some View {
        let tabs = state.items
        let selected = state.workspace.selected
        HStack(spacing: 0) {
            if overflowing {
                TabArrow(symbol: "chevron.left", enabled: offset > 1) { scroller.scroll(by: -max(visibleWidth * 0.8, 200)) }
                    .onDrop(of: [.plainText], delegate: EdgeScrollDelegate(scroller: scroller, delta: -24))
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
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
                    .background(TabScrollMarker(scroller: scroller))
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { visibleWidth = $0 }
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in offset = x }
                // Fades at the edges show that more tabs are hidden there.
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [overflowing && offset > 1 ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 18)
                        Color.black
                        LinearGradient(colors: [.black, overflowing && offset < contentWidth - visibleWidth - 1 ? .clear : .black],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 18)
                    }
                }
                .onChange(of: selected) { _, id in
                    if let id { withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(id) } }
                }
            }
            if overflowing {
                TabArrow(symbol: "chevron.right", enabled: offset < contentWidth - visibleWidth - 1) {
                    scroller.scroll(by: max(visibleWidth * 0.8, 200))
                }
                .onDrop(of: [.plainText], delegate: EdgeScrollDelegate(scroller: scroller, delta: 24))
            }
            if tabs.count > 1 {
                // Every tab in a list: handy with dozens of tabs.
                Menu {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, item in
                        Button {
                            state.select(item.id)
                        } label: {
                            switch item {
                            case .terminal(let session):
                                Text("\(index < 9 ? "\(index + 1). " : "")\(session.displayTitle) — \(session.phase.label)")
                            case .files(let tab):
                                Text("\(index < 9 ? "\(index + 1). " : "")\(model.fileTabs.title(of: tab)) — \(tab.target.displayName)")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("All \(tabs.count) tabs")
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
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { TabBarCenter.shared.tabFrames[session.id] = $0 }
        .help("Middle-click to close")
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
        .onDrop(of: [.plainText], delegate: TabDropDelegate(target: session.id, workspace: state.workspaceID, targeted: $dropTargeted))
        .opacity(TabBarCenter.shared.dragging == session.id ? 0.35 : 1)
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
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { TabBarCenter.shared.tabFrames[tab.id] = $0 }
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
        .onDrop(of: [.plainText], delegate: TabDropDelegate(target: tab.id, workspace: state.workspaceID, targeted: $dropTargeted))
        .opacity(TabBarCenter.shared.dragging == tab.id ? 0.35 : 1)
        .help("Files on \(tab.target.displayName)")
    }
}

/// Finds the tab bar's scroll view: for the mouse wheel and the arrow buttons.
private struct TabScrollMarker: NSViewRepresentable {
    let scroller: TabScroller
    func makeNSView(context: Context) -> NSView {
        let m = Marker()
        m.scroller = scroller
        return m
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Marker: NSView {
        weak var scroller: TabScroller?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let scroll = enclosingScrollView {
                MainActor.assumeIsolated {
                    TabBarCenter.shared.register(scroll)
                    scroller?.scrollView = scroll
                }
            }
        }
    }
}

/// Scrolls one window's tab bar (arrow buttons).
@MainActor
final class TabScroller {
    weak var scrollView: NSScrollView?

    func scroll(by delta: CGFloat, animated: Bool = true) {
        guard let scroll = scrollView else { return }
        let clip = scroll.contentView
        let maxX = max((scroll.documentView?.frame.width ?? 0) - clip.bounds.width, 0)
        let x = min(max(clip.bounds.origin.x + delta, 0), maxX)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                clip.animator().setBoundsOrigin(NSPoint(x: x, y: clip.bounds.origin.y))
            }
        } else {
            clip.setBoundsOrigin(NSPoint(x: x, y: clip.bounds.origin.y))
        }
        scroll.reflectScrolledClipView(clip)
    }
}

/// A tab as a drop target. In its own window a dragged tab takes this tab's place as soon as it
/// passes over it; a tab from another window is inserted here when dropped.
private struct TabDropDelegate: DropDelegate {
    let target: UUID
    let workspace: UUID
    @Binding var targeted: Bool

    private var fromOtherWindow: Bool {
        guard let id = TabBarCenter.shared.dragging else { return false }
        return AppModel.shared.workspaces.workspace(containing: id) != workspace
    }

    func validateDrop(info: DropInfo) -> Bool { TabBarCenter.shared.dragging != nil }

    func dropEntered(info: DropInfo) {
        if fromOtherWindow { targeted = true } else { TabBarCenter.shared.dragMoved(over: target, x: info.location.x, in: workspace) }
    }

    func dropExited(info: DropInfo) { targeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if !fromOtherWindow { TabBarCenter.shared.dragMoved(over: target, x: info.location.x, in: workspace) }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        guard let id = TabBarCenter.shared.dragging else { return false }
        TabBarCenter.shared.drop(id, into: workspace, before: target)
        return true
    }
}

/// Holding a dragged tab over a tab bar arrow scrolls the bar that way.
private struct EdgeScrollDelegate: DropDelegate {
    let scroller: TabScroller
    let delta: CGFloat

    func validateDrop(info: DropInfo) -> Bool { TabBarCenter.shared.dragging != nil }
    func dropEntered(info: DropInfo) { TabBarCenter.shared.dragHover(scroller, by: delta) }
    func dropExited(info: DropInfo) { TabBarCenter.shared.dragHover(nil, by: 0) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { TabBarCenter.shared.dragHover(nil, by: 0); return false }
}

/// A small arrow at either end of an overflowing tab bar.
private struct TabArrow: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 24)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(symbol == "chevron.left" ? "Scroll tabs left" : "Scroll tabs right")
    }
}
