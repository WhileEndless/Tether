import AppKit
import SwiftTerm
import TetherCore

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
            self?.feed(byteArray: [UInt8](data)[...])
            // Hide the cursor of the replay.
            self?.feed(byteArray: Array("\u{1b}[?25l".utf8)[...])
            self?.revealPending()
        }
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
