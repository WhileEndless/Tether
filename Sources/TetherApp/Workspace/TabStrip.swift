import AppKit
import SwiftUI
import TetherCore
import SessionKit
import TerminalUI

/// Shared tab-bar state: the ⌘-held number overlay and tab dragging between windows.
@MainActor
@Observable
final class TabBarCenter {
    static let shared = TabBarCenter()
    /// True while ⌘ is held: tabs show the number to press.
    private(set) var showNumbers = false
    /// The tab being dragged (dimmed in its bar while the others make room).
    private(set) var dragging: UUID?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var numberTimer: DispatchWorkItem?

    func start() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            MainActor.assumeIsolated { TabBarCenter.shared.modifiersChanged(event.modifierFlags) }
            return event
        }) { monitors.append(m) }
        // ⌘ released while Tether was not getting the event (⌘Tab, ⌘H, Spotlight, a menu being
        // tracked): the numbers must not stay. Leaving the app or a window hides them; coming back
        // looks at the keys as they are now.
        let nc = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            monitors.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { TabBarCenter.shared.hideNumbers() }
            })
        }
        monitors.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TabBarCenter.shared.modifiersChanged(NSEvent.modifierFlags) }
        })
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

    /// Closes the tab, or the sidebar row's terminal or file tab, at a point in window coordinates
    /// (top-left origin). True if there was one.
    func closeTab(at point: CGPoint, in window: NSWindow) -> Bool {
        guard let state = AppModel.shared.workspaces.state(of: window) else { return false }
        if let item = state.items.first(where: { tabFrames[$0.id]?.contains(point) == true }) {
            state.close(item)
            return true
        }
        // A sidebar row under the pointer: the table row there holds a marker saying which one it is.
        guard let content = window.contentView,
              // hitTest takes a point in the content view's superview, whose coordinates are the window's.
              let hit = content.hitTest(CGPoint(x: point.x, y: content.frame.height - point.y)),
              let rowView = sequence(first: hit, next: \.superview).first(where: { $0 is NSTableRowView }),
              let marker = Self.marker(in: rowView), marker.workspace == state.workspaceID, let item = marker.item else { return false }
        switch item {
        case .session(let id):
            guard let s = AppModel.shared.sessions.session(id) else { return false }
            state.closeTab(s)
        case .files(let id):
            guard let t = AppModel.shared.fileTabs.tab(id) else { return false }
            state.close(.files(t))
        default:
            return false
        }
        return true
    }

    private static func marker(in view: NSView) -> SidebarRowMarker.MarkerView? {
        if let m = view as? SidebarRowMarker.MarkerView { return m }
        for sub in view.subviews { if let m = marker(in: sub) { return m } }
        return nil
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

    private static func showsNumbers(flags: NSEvent.ModifierFlags, appActive: Bool) -> Bool {
        TabNumberHold.shows(flags: flags, appActive: appActive)
    }

    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        numberTimer?.cancel()
        if Self.showsNumbers(flags: flags, appActive: NSApp.isActive) {
            // Show after a short hold so normal ⌘ shortcuts do not flash the numbers. By then the
            // app may have gone to the background (⌘Tab): the keys are looked at again.
            let work = DispatchWorkItem {
                MainActor.assumeIsolated {
                    let center = TabBarCenter.shared
                    guard Self.showsNumbers(flags: NSEvent.modifierFlags, appActive: NSApp.isActive) else { return }
                    center.showNumbers = true
                    center.watchRelease()
                }
            }
            numberTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        } else {
            hideNumbers()
        }
    }

    private func hideNumbers() {
        numberTimer?.cancel()
        numberTimer = nil
        releaseCheck?.cancel()
        releaseCheck = nil
        if showNumbers { showNumbers = false }
    }

    /// While the numbers show, the keys are looked at a few times a second: a release that no
    /// event reported (inside a menu, a window drag) still hides them. Stops once they are hidden.
    @ObservationIgnored private var releaseCheck: Task<Void, Never>?
    private func watchRelease() {
        releaseCheck?.cancel()
        releaseCheck = Task { @MainActor in
            while !Task.isCancelled, showNumbers {
                try? await Task.sleep(for: .milliseconds(250))
                if !Self.showsNumbers(flags: NSEvent.modifierFlags, appActive: NSApp.isActive) { hideNumbers(); return }
            }
        }
    }

    // MARK: Dragging
    //
    // Tabs are dragged with the mouse directly (not with the system's drag and drop): every step is
    // handled the moment it happens, so dropping takes effect at once — no "slide back" animation or
    // polling first — and nothing outside Tether ever sees a dragged tab (no files on the desktop).

    /// Tab bar frames per window (window coordinates, top-left origin).
    @ObservationIgnored var barFrames: [UUID: CGRect] = [:]
    /// Another window's tab bar under a dragged tab (highlighted: dropping adds the tab there).
    private(set) var dropTarget: UUID?
    @ObservationIgnored private var preview: NSPanel?
    @ObservationIgnored private var edgeScroll: Timer?

    /// Starts dragging a tab (also used by tests).
    func beginDrag(_ id: UUID) {
        dragging = id
    }

    /// Where the pointer is: the frontmost Tether window under it, the point in that window, and
    /// whether it is over the window's tab bar.
    private func hit(_ screen: CGPoint) -> (workspace: UUID, point: CGPoint, onBar: Bool, window: NSWindow)? {
        let store = AppModel.shared.workspaces
        for w in NSApp.orderedWindows where w.isVisible && w.frame.contains(screen) {
            guard let ws = store.workspace(of: w), let content = w.contentView else { return nil }
            let local = w.convertPoint(fromScreen: screen)
            let p = CGPoint(x: local.x, y: content.bounds.height - local.y)
            let onBar = barFrames[ws].map { $0.insetBy(dx: 0, dy: -10).contains(p) } ?? false
            return (ws, p, onBar, w)
        }
        return nil
    }

    /// The pointer moved while dragging `id` (`title` labels the floating preview).
    func dragChanged(_ id: UUID, title: String, at screen: CGPoint = NSEvent.mouseLocation) {
        if dragging != id { beginDrag(id) }
        let store = AppModel.shared.workspaces
        let source = store.workspace(containing: id)
        let h = hit(screen)
        if let h, h.onBar, h.workspace == source {
            // In its own tab bar: reorder live, scroll at the ends of a long bar.
            hidePreview()
            dropTarget = nil
            if let tab = store.workspace(h.workspace).tabs.first(where: { (tabFrames[$0].map { $0.minX...$0.maxX })?.contains(h.point.x) == true }),
               let frame = tabFrames[tab] {
                dragMoved(over: tab, x: h.point.x - frame.minX, in: h.workspace)
            }
            autoScroll(h)
        } else {
            // Off its bar: a small picture of the tab follows the pointer; another window's bar lights up.
            stopAutoScroll()
            showPreview(title: title, at: screen)
            let target = (h?.onBar == true && h?.workspace != source) ? h?.workspace : nil
            if dropTarget != target { dropTarget = target }
        }
    }

    /// The mouse was released: the tab goes where it is, at once.
    func dragEnded(_ id: UUID, at screen: CGPoint = NSEvent.mouseLocation) {
        let store = AppModel.shared.workspaces
        let source = store.workspace(containing: id)
        hidePreview()
        stopAutoScroll()
        dropTarget = nil
        defer { withAnimation(.snappy(duration: 0.15)) { dragging = nil } }
        guard let h = hit(screen) else {
            detach(id, from: source, at: screen)   // outside every Tether window: its own window
            return
        }
        guard h.workspace != source else { return } // its own window: already reordered live
        // Another window: into its tab bar where it was released, or at the end.
        let tabs = store.workspace(h.workspace).tabs
        let before = h.onBar ? tabs.first { (tabFrames[$0]?.midX ?? .infinity) > h.point.x } : nil
        drop(id, into: h.workspace, before: before)
    }

    /// Opens a tab in a new window whose title bar is under the pointer.
    private func detach(_ id: UUID, from sourceID: UUID?, at point: CGPoint) {
        let store = AppModel.shared.workspaces
        let source = sourceID.flatMap { store.window(of: $0) }
        let ws = UUID()
        store.add(id, to: ws)
        let size = source?.frame.size ?? CGSize(width: 1100, height: 700)
        WindowLayout.place(ws, frame: CGRect(x: point.x - 120, y: point.y - size.height + 20,
                                             width: size.width, height: size.height))
        store.openWindow?(ws)
        // The new window takes the keyboard, and a window left without tabs closes — dragging a
        // window's only tab out simply moves it.
        DispatchQueue.main.async {
            store.activate(ws)
            if let sourceID { store.closeIfEmpty(sourceID) }
        }
    }

    /// Drops onto a tab bar: move the tab into that window, before `before` (or at the end).
    func drop(_ id: UUID, into workspace: UUID, before: UUID?) {
        guard id != before else { return }
        let store = AppModel.shared.workspaces
        // Within its own window the tab was already reordered live while dragging: leave it there.
        let source = store.workspace(containing: id)
        if source == workspace { return }
        store.add(id, to: workspace, select: true, before: before)
        store.activate(workspace)
        // The window it came from closes when nothing is left in it.
        if let source { store.closeIfEmpty(source) }
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

    /// Near either end of an overflowing tab bar, keeps scrolling while the tab is held there.
    private func autoScroll(_ h: (workspace: UUID, point: CGPoint, onBar: Bool, window: NSWindow)) {
        guard let bar = barFrames[h.workspace] else { return stopAutoScroll() }
        let edge: CGFloat = 36
        let delta: CGFloat = h.point.x < bar.minX + edge ? 14 : h.point.x > bar.maxX - edge ? -14 : 0
        guard delta != 0 else { return stopAutoScroll() }
        guard edgeScroll == nil else { return }
        let window = h.window
        edgeScroll = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons & 1 != 0 else { self?.stopAutoScroll(); return }
                let local = window.convertPoint(fromScreen: NSEvent.mouseLocation)
                _ = self.scrollTabs(by: delta, at: local, in: window)
            }
        }
    }

    private func stopAutoScroll() {
        edgeScroll?.invalidate()
        edgeScroll = nil
    }

    private func showPreview(title: String, at screen: CGPoint) {
        if preview == nil {
            let renderer = ImageRenderer(content: TabDragPreview(title: title))
            renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
            guard let image = renderer.nsImage else { return }
            let panel = NSPanel(contentRect: CGRect(origin: .zero, size: image.size),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            let view = NSImageView(image: image)
            view.frame = CGRect(origin: .zero, size: image.size)
            panel.contentView = view
            panel.orderFront(nil)
            preview = panel
        }
        preview?.setFrameOrigin(CGPoint(x: screen.x - 20, y: screen.y - (preview?.frame.height ?? 0) + 6))
    }

    private func hidePreview() {
        preview?.orderOut(nil)
        preview = nil
    }
}

/// The picture of a tab that follows the pointer outside its tab bar.
private struct TabDragPreview: View {
    let title: String

    var body: some View {
        Label(title, systemImage: "terminal")
            .font(.callout)
            .lineLimit(1)
            .frame(maxWidth: 220)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .padding(4)
    }
}

/// The tabs of this window.
struct TabStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowState.self) private var state
    @State private var center = TabBarCenter.shared

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
                .onHorizontalScroll { offset = $0 }
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
            // "+" opens another tab like the one in front, as in browsers; its menu has the others.
            Menu {
                Button("New Local Terminal") { state.connect(.local) }
                Button("New Private Tab") {
                    if let s = state.session { state.newSession(like: s, isPrivate: true) }
                    else { state.connect(state.inspectedTarget ?? .local, isPrivate: true) }
                }
                Divider()
                Button("New Connection…") { state.showQuickConnect = true }
            } label: {
                Image(systemName: "plus").frame(width: 26, height: 24)
            } primaryAction: {
                state.newTabLikeCurrent()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help(state.newTabHelp + " · hold for more")
            .padding(.trailing, 6)
        }
        .frame(height: 36)
        .background(center.dropTarget == state.workspaceID ? Color.accentColor.opacity(0.12) : .clear)
        .background(.bar)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { center.barFrames[state.workspaceID] = $0 }
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
                    // An agent waiting for you, attention, an agent, a working command, or the state.
                    TabStatusIcon(session: session)
                }
            }
            .frame(width: 16, height: 16)

            if let c = session.descriptor.color.color {
                RoundedRectangle(cornerRadius: 1.5).fill(c).frame(width: 3, height: 14)
            }
            if session.descriptor.isPrivate {
                Image(systemName: "eye.slash").font(.caption).foregroundStyle(.secondary)
                    .help("Private tab: no recording, archive or command history")
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
                state.browse(session.descriptor.target, path: session.currentDirectory)
            }
            Button("Search in Session…") {
                model.searchPreset = SearchPreset(host: nil, session: session.id)
                model.openSearch?()
            }
            Divider()
            Button("Close Tab") { state.closeTab(session) }
            Button("Terminate Session…", role: .destructive) { state.terminate(session) }
        }
        .gesture(DragGesture(minimumDistance: 5)
            .onChanged { _ in TabBarCenter.shared.dragChanged(session.id, title: session.displayTitle) }
            .onEnded { _ in TabBarCenter.shared.dragEnded(session.id) })
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
        .gesture(DragGesture(minimumDistance: 5)
            .onChanged { _ in TabBarCenter.shared.dragChanged(tab.id, title: model.fileTabs.title(of: tab)) }
            .onEnded { _ in TabBarCenter.shared.dragEnded(tab.id) })
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

