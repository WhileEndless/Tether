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
    public static let paneInfo =
        "display-message -p '#{pane_id} #{alternate_on} #{cursor_x} #{cursor_y} #{pane_width} #{pane_height} #{history_size}'\n"

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
    }
}
