import AppKit
import SwiftTerm
import TetherCore
import TerminalText

/// Terminal view that only displays bytes; keyboard input is ignored.
public final class ReadOnlyTerminalView: TerminalView, TerminalViewDelegate {
    var pending: Data?
    /// After replaying, scroll to the line containing this text, preferring the occurrence closest
    /// to `fraction` of the transcript (used to open search results).
    var revealText: String?
    var revealFraction: Double = 0

    public override init(frame: CGRect) {
        let settings = SettingsStore.shared.settings
        var options = TerminalOptions.default
        options.scrollback = 100_000
        super.init(frame: frame, font: settings.terminalFont, options: options)
        terminalDelegate = self
        // A transcript is for reading: a visible scroller, and the wheel always scrolls (a replayed
        // program may have turned on mouse reporting, which would otherwise swallow the wheel).
        scrollerStyle = .legacy
        allowMouseReporting = false
        applyTheme()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func applyTheme() {
        let theme = TerminalTheme.resolve(SettingsStore.shared.settings, appearance: effectiveAppearance)
        installColors(theme.ansi)
        nativeForegroundColor = theme.foreground
        nativeBackgroundColor = theme.background
        selectedTextBackgroundColor = theme.selection
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let data = pending else { return }
        pending = nil
        // Wait one runloop so the view has its final size before replaying.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.replay([UInt8](data)[...])
            // Leave a full-screen program's screen (where there is no scrollback), stop any mouse
            // reporting it turned on, and hide the replay's cursor.
            self.feed(byteArray: Array("\u{1b}[?1049l\u{1b}[?1047l\u{1b}[?47l\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l\u{1b}[r\u{1b}[?25l".utf8)[...])
            self.fitToView()
            self.scrollTo(row: Int.max / 2)
            self.revealPending()
        }
    }

    /// The size the view had before a replay changed it to the recorded one.
    private var viewSize: (cols: Int, rows: Int)?

    /// Replays at the size the terminal had (`SizeMarker`s in the recording), so programs that
    /// place the cursor, and long lines, come out as they were shown. A slice that starts before
    /// its first marker uses that marker's size (Tether notes the size at least every megabyte).
    func replay(_ bytes: ArraySlice<UInt8>) {
        let mayClear = SettingsStore.shared.settings.programsMayClearScrollback
        var rest = bytes
        if let (_, first) = SizeMarker.find(in: rest) { resizeForReplay(first) }
        while let (range, size) = SizeMarker.find(in: rest) {
            feedKeepingScrollback(rest[rest.startIndex..<range.lowerBound], programsMayClear: mayClear)
            resizeForReplay(size)
            rest = rest[range.upperBound...]
        }
        feedKeepingScrollback(rest, programsMayClear: mayClear)
    }

    private func resizeForReplay(_ size: (cols: Int, rows: Int)) {
        let t = getTerminal()
        guard size.cols > 1, size.rows > 1, size.cols != t.cols || size.rows != t.rows else { return }
        if viewSize == nil { viewSize = (t.cols, t.rows) }
        t.resize(cols: size.cols, rows: size.rows)
    }

    /// Back to the window's size once replayed (long lines reflow to it).
    private func fitToView() {
        guard let size = viewSize else { return }
        viewSize = nil
        getTerminal().resize(cols: size.cols, rows: size.rows)
    }

    private func revealPending() {
        guard let text = revealText, !text.isEmpty else { return }
        let t = getTerminal()
        let base = t.buffer.totalLinesTrimmed
        var rows: [Int] = []
        var row = base
        while let line = t.getScrollInvariantLine(row: row) {
            if line.translateToString(trimRight: true).contains(text) { rows.append(row - base) }
            row += 1
        }
        let total = max(row - base, 1)
        guard let best = rows.min(by: { abs(Double($0) / Double(total) - revealFraction) < abs(Double($1) / Double(total) - revealFraction) })
        else { return }
        scrollTo(row: max(best - t.rows / 3, 0))
        selection.setSelection(start: Position(col: 0, row: best), end: Position(col: t.cols - 1, row: best))
        needsDisplay = true
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    public func setTerminalTitle(source: TerminalView, title: String) {}
    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    public func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    public func scrolled(source: TerminalView, position: Double) {}
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    public func bell(source: TerminalView) {}
    public func clipboardCopy(source: TerminalView, content: Data) {}
    public func clipboardRead(source: TerminalView) -> Data? { nil }
    public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
