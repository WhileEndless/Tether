import Foundation

/// A notification a program in the terminal asked for — Claude Code when it finishes or needs an
/// answer, long builds, `printf '\e]9;done\a'`. Text from the server is shown as is, nothing more.
public struct TerminalNotification: Equatable, Sendable {
    public var title: String?
    public var body: String

    public init(title: String? = nil, body: String) {
        self.title = title
        self.body = body
    }
}

/// Reads the de facto standard notification sequences (the payload after `ESC ] code ;`):
///
///     OSC 9 ; body                       iTerm2, also Windows Terminal, WezTerm, kitty, …
///     OSC 777 ; notify ; title ; body    rxvt-unicode, Ghostty, foot, WezTerm
///     OSC 99 ; metadata ; payload        kitty's protocol (title/body, chunks, base64)
///
/// `OSC 9 ; 4 ; …` and other `OSC 9 ; <number> ; …` forms are ConEmu commands (progress bars and
/// the like), not notifications.
public struct TerminalNotificationParser: Sendable {
    /// kitty notifications sent in parts, by id, until the last part (`d=1`).
    private var kittyParts: [String: (title: String, body: String)] = [:]

    public init() {}

    public mutating func parse(code: Int, payload: [UInt8]) -> TerminalNotification? {
        let text = String(decoding: payload, as: UTF8.self)
        switch code {
        case 9:
            if text.range(of: #"^\d+;"#, options: .regularExpression) != nil || text.allSatisfy(\.isNumber) { return nil }
            let body = Self.clean(text)
            return body.isEmpty ? nil : TerminalNotification(body: body)
        case 777:
            let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.first == "notify", parts.count >= 2 else { return nil }
            let title = Self.clean(parts[1])
            let body = Self.clean(parts.count > 2 ? parts[2] : "")
            if title.isEmpty && body.isEmpty { return nil }
            return body.isEmpty ? TerminalNotification(body: title) : TerminalNotification(title: title.isEmpty ? nil : title, body: body)
        case 99:
            return kitty(text)
        default:
            return nil
        }
    }

    private mutating func kitty(_ text: String) -> TerminalNotification? {
        let split = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        var meta: [String: String] = [:]
        for item in (split.first ?? "").split(separator: ":") {
            let kv = item.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { meta[kv[0]] = kv[1] }
        }
        var payload = split.count > 1 ? split[1] : ""
        if meta["e"] == "1" {
            payload = Data(base64Encoded: payload).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
        let id = meta["i"] ?? ""
        var current = kittyParts[id] ?? ("", "")
        switch meta["p"] ?? "title" {
        case "title": current.title += payload
        case "body": current.body += payload
        default: return nil       // queries, icons, buttons: not shown
        }
        if meta["d"] == "0" {
            kittyParts[id] = current
            return nil
        }
        kittyParts[id] = nil
        let title = Self.clean(current.title), body = Self.clean(current.body)
        if title.isEmpty && body.isEmpty { return nil }
        return body.isEmpty ? TerminalNotification(body: title) : TerminalNotification(title: title.isEmpty ? nil : title, body: body)
    }

    /// Plain, short text: control characters (escape sequences included) removed, length capped.
    static func clean(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { !($0.value < 0x20 || (0x7f...0x9f).contains($0.value)) }
        let s = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return s.count > 240 ? String(s.prefix(239)) + "…" : s
    }
}
