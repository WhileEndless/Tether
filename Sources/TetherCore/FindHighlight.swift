import Foundation

/// How matches of a find in the terminal are shown (Settings ▸ Terminal ▸ Find).
public struct FindHighlightStyle: Codable, Equatable, Sendable {
    /// The whole line of the current match is tinted.
    public var highlightLine = true
    public var lineColor: FindHighlightColor = .accent
    /// The current match: a solid box with its text drawn on top.
    public var matchColor: FindHighlightColor = .yellow
    /// The other matches get a light tint of the match color.
    public var showOtherMatches = true
    /// Marks next to the scroller show where matches are in the whole history.
    public var showScrollerMarks = true
    /// What happens when a match is reached, so the eye finds it.
    public var jumpEffect: FindJumpEffect = .bounceAndBlink
    /// Milliseconds after the last key before the terminal is searched, so a long history is not
    /// searched again for every letter typed (0: at once). ↩ searches right away.
    public var searchDelay = 300

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d<T: Decodable>(_ key: CodingKeys, _ into: inout T) {
            if let v = try? c.decode(T.self, forKey: key) { into = v }
        }
        d(.highlightLine, &highlightLine)
        d(.lineColor, &lineColor)
        d(.matchColor, &matchColor)
        d(.showOtherMatches, &showOtherMatches)
        d(.showScrollerMarks, &showScrollerMarks)
        d(.jumpEffect, &jumpEffect)
        d(.searchDelay, &searchDelay)
    }
}

public enum FindHighlightColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case accent, yellow, orange, green, blue, pink, purple
    public var id: String { rawValue }
    public var title: String { self == .accent ? "Accent Color" : rawValue.capitalized }
}

public enum FindJumpEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, bounce, blink, bounceAndBlink
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: "None"
        case .bounce: "Bounce the match"
        case .blink: "Blink the line"
        case .bounceAndBlink: "Bounce and blink"
        }
    }
    public var bounces: Bool { self == .bounce || self == .bounceAndBlink }
    public var blinks: Bool { self == .blink || self == .bounceAndBlink }
}
