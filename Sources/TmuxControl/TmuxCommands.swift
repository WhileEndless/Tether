import Foundation

/// Builds tmux commands to be written to a control mode client (one per line).
public enum TmuxCommands {
    /// Sends raw bytes to a pane using hex notation, which avoids all quoting issues.
    /// Large inputs (pastes) are split into several commands.
    public static func sendKeys(pane: String, bytes: some Collection<UInt8>, chunkSize: Int = 512) -> String {
        guard !bytes.isEmpty else { return "" }
        var out = ""
        var chunk: [String] = []
        chunk.reserveCapacity(chunkSize)
        func flush() {
            guard !chunk.isEmpty else { return }
            out += "send-keys -t \(pane) -H \(chunk.joined(separator: " "))\n"
            chunk.removeAll(keepingCapacity: true)
        }
        for b in bytes {
            chunk.append(String(format: "%02x", b))
            if chunk.count == chunkSize { flush() }
        }
        flush()
        return out
    }

    /// Tells tmux the size of this control client.
    /// tmux 3.0/3.1 expect `W,H`; newer versions use `WxH`.
    public static func resize(cols: Int, rows: Int, legacySyntax: Bool = false) -> String {
        "refresh-client -C \(max(cols, 1))\(legacySyntax ? "," : "x")\(max(rows, 1))\n"
    }

    /// Asks for the active pane id plus state needed to restore the screen.
    /// The pane's terminal modes are asked too (`key=value;…`, so a field an older tmux leaves empty
    /// does not shift the others): a terminal rebuilt on re-attach gets them back.
    public static let paneInfo =
        "display-message -p '#{pane_id} #{alternate_on} #{cursor_x} #{cursor_y} #{pane_width} #{pane_height} #{history_size} "
        + "cursor=#{cursor_flag};keypad=#{keypad_flag};keys=#{keypad_cursor_flag};insert=#{insert_flag};origin=#{origin_flag};"
        + "wrap=#{wrap_flag};top=#{scroll_region_upper};bottom=#{scroll_region_lower};m1000=#{mouse_standard_flag};"
        + "m1002=#{mouse_button_flag};m1003=#{mouse_all_flag};m1006=#{mouse_sgr_flag};m1005=#{mouse_utf8_flag};"
        + "paste=#{bracket_paste_flag};shape=#{cursor_shape};blink=#{cursor_blinking}'\n"

    /// Captures pane content with escape sequences.
    /// - Parameters:
    ///   - historyLines: > 0 includes that many lines of scrollback.
    ///   - join: joins wrapped lines (good for history, bad for exact screen restore).
    public static func capturePane(pane: String, historyLines: Int, join: Bool) -> String {
        let start = historyLines > 0 ? " -S -\(historyLines)" : ""
        return "capture-pane -p -e\(join ? " -J" : "")\(start) -t \(pane)\n"
    }

    /// Hides pane border titles, which some configs enable (`pane-border-status top`) and which take
    /// a row from the pane. Only used for Tether's own sessions so other sessions are not modified.
    public static let hidePaneBorderStatus = "set-option -w pane-border-status off\n"

    /// Detach this client without killing the session.
    public static let detach = "detach-client\n"

    /// Kills the whole session (used when the user explicitly ends a persistent session).
    public static func killSession(_ name: String) -> String {
        "kill-session -t \(quote(name))\n"
    }

    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Parsed reply of `TmuxCommands.paneInfo`.
public struct TmuxPaneInfo: Equatable, Sendable {
    public var paneID: String
    public var alternateScreen: Bool
    public var cursorX: Int
    public var cursorY: Int
    public var width: Int
    public var height: Int
    /// Lines in the pane's scrollback on the server.
    public var historySize: Int
    /// The terminal modes the program in the pane has set (empty from an older Tether's question).
    public var modes: TmuxPaneModes

    public init?(line: String) {
        let p = line.split(separator: " ").map(String.init)
        guard p.count >= 6, p[0].hasPrefix("%") else { return nil }
        paneID = p[0]
        alternateScreen = p[1] == "1"
        cursorX = Int(p[2]) ?? 0
        cursorY = Int(p[3]) ?? 0
        width = Int(p[4]) ?? 80
        height = Int(p[5]) ?? 24
        historySize = p.count > 6 ? Int(p[6]) ?? 0 : 0
        modes = TmuxPaneModes(p.count > 7 ? p[7] : "")
    }
}

/// Terminal modes of a tmux pane — what a program like Claude Code, vim or htop switched on (mouse
/// reporting, bracketed paste, hidden cursor, application keys, a scroll region, …). A terminal that
/// is rebuilt from a capture (Tether reopened) knows none of them; without them the program gets no
/// mouse events, pasted lines arrive as separate commands, and keys or scrolling behave differently.
public struct TmuxPaneModes: Equatable, Sendable {
    var values: [String: String] = [:]

    public init(_ text: String) {
        for part in text.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { values[kv[0]] = kv[1] }
        }
    }

    private func on(_ key: String) -> Bool { values[key] == "1" }
    private func off(_ key: String) -> Bool { values[key] == "0" }

    /// Escape sequences that set the modes again and put the cursor at (`x`, `y`) (screen
    /// coordinates, from 0) for a screen `height` rows high. Only what differs from a fresh
    /// terminal is sent.
    public func sequence(cursorX x: Int, cursorY y: Int, height: Int) -> String {
        var s = ""
        let top = Int(values["top"] ?? "") ?? 0
        let bottom = Int(values["bottom"] ?? "") ?? max(height - 1, 0)
        let region = top > 0 || bottom < height - 1
        if region { s += "\u{1b}[\(top + 1);\(bottom + 1)r" }
        if off("wrap") { s += "\u{1b}[?7l" }
        if on("insert") { s += "\u{1b}[4h" }
        if on("keypad") { s += "\u{1b}=" }
        if on("keys") { s += "\u{1b}[?1h" }
        if on("m1000") { s += "\u{1b}[?1000h" }
        if on("m1002") { s += "\u{1b}[?1002h" }
        if on("m1003") { s += "\u{1b}[?1003h" }
        if on("m1005") { s += "\u{1b}[?1005h" }
        if on("m1006") { s += "\u{1b}[?1006h" }
        if on("paste") { s += "\u{1b}[?2004h" }
        if let style = cursorStyle { s += "\u{1b}[\(style) q" }
        // Origin mode makes the cursor position relative to the scroll region.
        if on("origin") {
            s += "\u{1b}[?6h\u{1b}[\(max(y - top, 0) + 1);\(x + 1)H"
        } else {
            s += "\u{1b}[\(y + 1);\(x + 1)H"
        }
        if off("cursor") { s += "\u{1b}[?25l" }
        return s
    }

    /// DECSCUSR for a shape the program chose (nil for the default).
    var cursorStyle: Int? {
        let blink = on("blink")
        switch values["shape"] {
        case "block": return blink ? 1 : 2
        case "underline": return blink ? 3 : 4
        case "bar": return blink ? 5 : 6
        default: return nil
        }
    }
}
