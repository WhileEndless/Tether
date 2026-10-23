import AppKit
import SwiftTerm

/// Reads colour/font profiles from Terminal.app's preferences so Tether looks exactly like
/// the user's Terminal (e.g. "Basic", "Clear Dark", or a custom profile).
public struct TerminalAppProfile {
    public var name: String
    public var font: NSFont?
    public var foreground: NSColor?
    public var background: NSColor?
    public var bold: NSColor?
    public var cursor: NSColor?
    public var selection: NSColor?
    /// 16 ANSI colours; nil entries fall back to Terminal's defaults.
    public var ansi: [NSColor?]
    public var backgroundBlur: Double
    public var optionAsMeta: Bool?

    private static let domain = "com.apple.Terminal" as CFString
    private static let ansiKeys = [
        "ANSIBlackColor", "ANSIRedColor", "ANSIGreenColor", "ANSIYellowColor",
        "ANSIBlueColor", "ANSIMagentaColor", "ANSICyanColor", "ANSIWhiteColor",
        "ANSIBrightBlackColor", "ANSIBrightRedColor", "ANSIBrightGreenColor", "ANSIBrightYellowColor",
        "ANSIBrightBlueColor", "ANSIBrightMagentaColor", "ANSIBrightCyanColor", "ANSIBrightWhiteColor",
    ]

    /// Names of all profiles defined in Terminal.app.
    public static func availableNames() -> [String] {
        guard let ws = CFPreferencesCopyAppValue("Window Settings" as CFString, domain) as? [String: Any] else { return [] }
        return ws.keys.sorted()
    }

    /// The profile Terminal.app uses for new windows.
    public static var defaultName: String? {
        CFPreferencesCopyAppValue("Default Window Settings" as CFString, domain) as? String
    }

    private static var cache: [String: TerminalAppProfile] = [:]

    /// Loads a profile by name (nil = Terminal's default profile).
    public static func load(_ name: String?) -> TerminalAppProfile? {
        guard let name = name ?? defaultName else { return nil }
        if let cached = cache[name] { return cached }
        guard let ws = CFPreferencesCopyAppValue("Window Settings" as CFString, domain) as? [String: Any],
              let dict = ws[name] as? [String: Any] else { return nil }
        func color(_ key: String) -> NSColor? {
            guard let data = dict[key] as? Data else { return nil }
            return (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data))?.usingColorSpace(.sRGB)
        }
        let font = (dict["Font"] as? Data).flatMap(decodeFont)
        let profile = TerminalAppProfile(
            name: name, font: font, foreground: color("TextColor"), background: color("BackgroundColor"),
            bold: color("TextBoldColor"), cursor: color("CursorColor"), selection: color("SelectionColor"),
            ansi: ansiKeys.map(color), backgroundBlur: dict["BackgroundBlur"] as? Double ?? 0,
            optionAsMeta: dict["useOptionAsMetaKey"] as? Bool)
        cache[name] = profile
        return profile
    }

    /// Reads the font name and size from the archive. Terminal.app often uses private fonts
    /// (e.g. "SFMonoTerminal-Regular") that other apps cannot load, and unarchiving them yields the
    /// proportional system font. In that case use the system monospaced font (SF Mono) at the same size.
    static func decodeFont(_ data: Data) -> NSFont? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else { return nil }
        let name = objects.compactMap { $0 as? String }.first { $0 != "$null" }
        let size = objects.compactMap { ($0 as? [String: Any])?["NSSize"] as? Double }.first ?? 12
        if let name, let font = NSFont(name: name, size: size), font.isFixedPitch { return font }
        let weight: NSFont.Weight = (name?.lowercased().contains("bold") ?? false) ? .bold : .regular
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Forget cached profiles (e.g. after the user edits Terminal's settings).
    public static func invalidateCache() { cache.removeAll() }
}
