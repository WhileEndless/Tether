import AppKit

/// A terminal's scroller, standing for the whole session: every line of its recording (from the
/// first), with what is in memory at the bottom. Dragging it anywhere shows that part — from memory,
/// or read from the recording as it is reached (`TetherTerminalView.scrollHistory(toLine:)`).
/// Without a recording it stands for what is in memory, like any scroller.
final class HistoryScroller: NSView {
    /// Lines in the session, the first line on screen, and about how many are on screen.
    private(set) var total = 1
    private(set) var top = 0
    private(set) var visible = 1
    /// Called with the line the user moved the scroller to (as the first line on screen).
    var onScroll: ((Int) -> Void)?
    /// Called when a drag ends.
    var onScrollEnded: (() -> Void)?
    private var grab: CGFloat?
    private var hovering = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    // A scroll bar for VoiceOver: where the view is in the session.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .scrollBar }
    override func accessibilityOrientation() -> NSAccessibilityOrientation { .vertical }
    override func accessibilityValue() -> Any? {
        NSNumber(value: total > visible ? Double(top) / Double(total - visible) : 0)
    }
    override func accessibilityLabel() -> String? { "Session history" }

    static var width: CGFloat { NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) }

    func set(total: Int, top: Int, visible: Int) {
        let total = max(total, 1), visible = max(min(visible, total), 1), top = min(max(top, 0), max(total - visible, 0))
        guard total != self.total || top != self.top || visible != self.visible else { return }
        self.total = total
        self.top = top
        self.visible = visible
        needsDisplay = true
    }

    /// Where a mark for session line `line` (fractional) sits, from the scroller's top: where the
    /// knob's middle is when that line is in the middle of the screen — so a match on screen is
    /// marked inside the knob, whatever its size (it is at least 28 points tall).
    static func markOffset(line: Double, total: Int, visible: Int, height: CGFloat) -> CGFloat {
        let total = max(total, 1), visible = max(min(visible, total), 1)
        let knobHeight = min(max(height * CGFloat(visible) / CGFloat(total), 28), height)
        guard total > visible else { return height * CGFloat(min(max(line / Double(total), 0), 1)) }
        let f = min(max((line - Double(visible) / 2) / Double(total - visible), 0), 1)
        return knobHeight / 2 + (height - knobHeight) * CGFloat(f)
    }

    /// Nothing to scroll: drawn empty.
    private var scrolls: Bool { total > visible }

    private var knob: NSRect {
        let h = bounds.height
        let knobHeight = min(max(h * CGFloat(visible) / CGFloat(total), 28), h)
        let room = h - knobHeight
        let y = total > visible ? room * CGFloat(top) / CGFloat(total - visible) : 0
        return NSRect(x: 3, y: y, width: bounds.width - 6, height: knobHeight).insetBy(dx: 0, dy: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard scrolls else { return }
        let path = NSBezierPath(roundedRect: knob, xRadius: (bounds.width - 6) / 2, yRadius: (bounds.width - 6) / 2)
        (hovering || grab != nil ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setFill()
        path.fill()
    }

    /// The first line on screen for a knob whose top is at `y`.
    private func line(forKnobTop y: CGFloat) -> Int {
        let room = bounds.height - knob.height
        guard room > 0 else { return 0 }
        let fraction = min(max(y / room, 0), 1)
        return Int((Double(fraction) * Double(total - visible)).rounded())
    }

    override func mouseDown(with event: NSEvent) {
        guard scrolls else { return }
        let p = convert(event.locationInWindow, from: nil)
        if knob.contains(p) {
            grab = p.y - knob.minY
        } else {
            // A click on the track: the knob centred there, then dragged from its middle.
            grab = knob.height / 2
            onScroll?(line(forKnobTop: p.y - knob.height / 2))
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab else { return }
        let p = convert(event.locationInWindow, from: nil)
        onScroll?(line(forKnobTop: p.y - grab))
    }

    override func mouseUp(with event: NSEvent) {
        guard grab != nil else { return }
        grab = nil
        needsDisplay = true
        onScrollEnded?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    /// The terminal's own scroller (SwiftTerm's) is not drawn: this one is shown in its place. It
    /// stays in the view (only invisible), so the text keeps leaving room for a scroller.
    static func hideNativeScroller(of view: NSView) {
        for case let scroller as NSScroller in view.subviews { scroller.alphaValue = 0 }
    }
}
