import Foundation

/// Text that comes from a server (session and window names, terminal titles, command lines, agent
/// session names) made safe to show: anyone who can run a program there can set it. Control
/// characters become spaces, characters that reorder or hide text (bidirectional overrides,
/// zero-width spaces, fillers that look empty) are dropped — they could make one name pass for
/// another — and it is cut to `limit` characters, so a huge title cannot swamp a row or an alert.
public enum DisplayText {
    public static let defaultLimit = 200

    public static func clean(_ text: String, limit: Int = defaultLimit) -> String {
        var scalars = String.UnicodeScalarView()
        var kept = 0
        var lastWasSpace = true          // no space at the start
        for scalar in text.unicodeScalars {
            let v = scalar.value
            var keep: Unicode.Scalar? = scalar
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                keep = " "
            case .format:
                // Joiners stay (emoji sequences, and the non-joiner Persian and Indic scripts need),
                // as do emoji tag characters (subdivision flags); every other format character —
                // bidirectional controls, zero-width spaces, invisible operators, BOM — goes.
                keep = v == 0x200C || v == 0x200D || (0xE0020...0xE007F).contains(v) ? scalar : nil
            default:
                // Letters that draw nothing (Hangul fillers): a name of them looks empty, or like another.
                if [0x115F, 0x1160, 0x3164, 0xFFA0].contains(v) { keep = nil }
            }
            guard let k = keep else { continue }
            // Far more than can be shown (a character is a few scalars at most): the rest is not read.
            if kept > limit * 16 { break }
            let isSpace = k == " "
            if isSpace && lastWasSpace { continue }
            lastWasSpace = isSpace
            scalars.append(k)
            kept += 1
        }
        var out = String(scalars)
        // Cut on a character boundary (never inside an emoji or a letter with its marks).
        if out.count > limit { out = String(out.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…" }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
