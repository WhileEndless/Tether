import AppKit
import SwiftTerm
import TetherCore

/// Builds clipboard representations from the terminal's selected cells.
@MainActor
enum StyledTerminalCopy {
    static func hasSelection(in view: TerminalView) -> Bool {
        view.selection.active && view.selection.start != view.selection.end
    }

    static func menuItems(target: NSResponder, preferredFormat: TerminalCopyFormat,
                          plain: Selector, styled: Selector, ansi: Selector) -> [NSMenuItem] {
        [("Copy Plain Text", plain, preferredFormat == .plain ? "c" : ""),
         ("Copy with Styles", styled, preferredFormat == .styled ? "c" : ""),
         ("Copy as ANSI", ansi, "")].map { title, action, key in
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            return item
        }
    }

    static func writeSelection(from view: TerminalView, theme: TerminalTheme, settings: AppSettings,
                               format: TerminalCopyFormat? = nil,
                               to pasteboard: NSPasteboard) -> Bool {
        if (format ?? settings.terminalCopyFormat) == .styled {
            return write(from: view, theme: theme, includeBackground: settings.copyTerminalBackground, to: pasteboard)
        }
        guard let text = view.getSelection(), !text.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    static func write(from view: TerminalView, theme: TerminalTheme, includeBackground: Bool = false,
                      to pasteboard: NSPasteboard) -> Bool {
        let style = Style(view: view, theme: theme, includeBackground: includeBackground)
        let text = NSMutableAttributedString()
        guard readSelection(in: view, append: { run, attribute in
            text.append(NSAttributedString(string: run, attributes: style.attributes(for: attribute)))
        }), text.length > 0,
              let rtf = try? text.data(from: NSRange(location: 0, length: text.length),
                                       documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else { return false }
        let item = NSPasteboardItem()
        guard item.setData(rtf, forType: .rtf), item.setData(html(from: text), forType: .html),
              item.setString(text.string, forType: .string) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    static func writeANSI(from view: TerminalView, theme: TerminalTheme, encoding: TerminalANSICopyEncoding,
                          to pasteboard: NSPasteboard) -> Bool {
        let palette = Palette(view: view, theme: theme)
        let escape = encoding == .visible ? "\\x1b" : "\u{1b}"
        let reset = "\(escape)[0m"
        var string = ""
        var previous: String?
        var hasColors = false
        guard readSelection(in: view, append: { run, attribute in
            let color = rgbChannels(palette.foreground(for: attribute)).map { "\(escape)[38;2;\($0.0);\($0.1);\($0.2)m" }
            if color != previous {
                if let color {
                    string += color
                    hasColors = true
                } else {
                    string += reset
                }
                previous = color
            }
            string += run
        }), !string.isEmpty else { return false }
        if previous != nil { string += reset }
        // Start with the destination's defaults before applying the copied foreground colors.
        if hasColors { string = reset + string }
        let item = NSPasteboardItem()
        guard item.setString(string, forType: .string) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    private static func html(from text: NSAttributedString) -> Data {
        let contents = text.string as NSString
        var html = "<meta charset=\"utf-8\"><div style=\"white-space:pre-wrap\">"
        // Browser editors often insert only the fragment. Keep each run's styles inline so
        // they don't depend on a stylesheet or class declarations in the document head.
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            var styles: [String] = []
            if let font = attributes[.font] as? NSFont {
                if let family = font.familyName {
                    let escaped = family.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "'", with: "\\27 ")
                        .replacingOccurrences(of: "\r", with: "\\d ")
                        .replacingOccurrences(of: "\n", with: "\\a ")
                    styles.append("font-family:'\(escaped)',monospace")
                }
                styles.append("font-size:\(font.pointSize)pt")
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) { styles.append("font-weight:bold") }
                if traits.contains(.italicFontMask) { styles.append("font-style:italic") }
            }
            if let color = cssColor(attributes[.foregroundColor]) { styles.append("color:\(color)") }
            if let color = cssColor(attributes[.backgroundColor]) { styles.append("background-color:\(color)") }
            var decorations: [String] = []
            if attributes[.underlineStyle] != nil { decorations.append("underline") }
            if attributes[.strikethroughStyle] != nil { decorations.append("line-through") }
            if !decorations.isEmpty { styles.append("text-decoration:\(decorations.joined(separator: " "))") }
            if let color = cssColor(attributes[.underlineColor]) { styles.append("text-decoration-color:\(color)") }

            let fragment = escapeHTML(contents.substring(with: range)).replacingOccurrences(of: "\n", with: "<br>")
            html += "<span style=\"\(escapeHTML(styles.joined(separator: ";")))\">\(fragment)</span>"
        }
        html += "</div>"
        return Data(html.utf8)
    }

    private static func cssColor(_ value: Any?) -> String? {
        guard let (red, green, blue) = rgbChannels(value as? NSColor) else { return nil }
        return String(format: "#%02x%02x%02x", red, green, blue)
    }

    private static func rgbChannels(_ value: NSColor?) -> (Int, Int, Int)? {
        guard let color = value?.usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return (channel(color.redComponent), channel(color.greenComponent), channel(color.blueComponent))
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func readSelection(in view: TerminalView, append: @escaping (String, Attribute) -> Void) -> Bool {
        guard hasSelection(in: view) else { return false }
        let (first, last) = (view.selection.start, view.selection.end)
        let (start, end) = Position.compare(first, last) == .before ? (first, last) : (last, first)
        let terminal = view.getTerminal()
        guard start.col >= 0, end.col >= 0, terminal.bufferLine(atRow: start.row) != nil else { return false }

        var source = ""
        var pendingBreaks = 0
        var row = start.row
        // Match SwiftTerm's selection rules, including pending empty lines and a Select All end
        // position beyond the last populated row. Translate cells with SwiftTerm's Unicode logic.
        while let line = terminal.bufferLine(atRow: row) {
            let isLast = row == end.row || terminal.bufferLine(atRow: row + 1) == nil
            let lower = row == start.row ? start.col : 0
            let upper = isLast ? min(end.col, line.count) : line.count
            if row != start.row, !line.isWrapped { pendingBreaks += 1 }
            if line.hasAnyContent() {
                if pendingBreaks > 0 {
                    let breaks = String(repeating: "\n", count: pendingBreaks)
                    source += breaks
                    append(breaks, .empty)
                    pendingBreaks = 0
                }
                if lower < upper {
                    var run = ""
                    var previous = Attribute.empty
                    let text = line.translateToString(trimRight: true, startCol: lower, endCol: upper,
                                                      skipNullCellsFollowingWide: true) { cell in
                        let character = terminal.getCharacter(for: cell)
                        if cell.attribute != previous, !run.isEmpty {
                            append(run, previous)
                            run.removeAll(keepingCapacity: true)
                        }
                        previous = cell.attribute
                        run.append(character == "\0" || previous.style.contains(.invisible) ? " " : character)
                        return character == "\0" ? " " : character
                    }
                    source += text
                    if !run.isEmpty {
                        append(run, previous)
                    }
                }
            }
            if isLast { break }
            row += 1
        }
        // Fail closed if the selected cells and SwiftTerm's copy text ever disagree.
        return source == view.getSelection()
    }

    private struct Style {
        let fonts: [NSFont]
        let palette: Palette
        let includeBackground: Bool

        @MainActor
        init(view: TerminalView, theme: TerminalTheme, includeBackground: Bool) {
            let manager = NSFontManager.shared
            let font = view.font
            fonts = [font, manager.convert(font, toHaveTrait: .boldFontMask),
                     manager.convert(font, toHaveTrait: .italicFontMask),
                     manager.convert(font, toHaveTrait: [.boldFontMask, .italicFontMask])]
            palette = Palette(view: view, theme: theme)
            self.includeBackground = includeBackground
        }

        func attributes(for attribute: Attribute) -> [NSAttributedString.Key: Any] {
            let flags = attribute.style
            let bold = flags.contains(.bold)
            let index = (bold ? 1 : 0) + (flags.contains(.italic) ? 2 : 0)
            var attributes: [NSAttributedString.Key: Any] = [.font: fonts[index]]

            attributes[.foregroundColor] = palette.foreground(for: attribute) ?? (includeBackground ? palette.foreground : nil)
            attributes[.backgroundColor] = palette.background(for: attribute) ?? (includeBackground ? palette.background : nil)
            if flags.contains(.underline) {
                let underline: NSUnderlineStyle = switch attribute.underlineStyle {
                case .double: .double
                case .dotted: [.single, .patternDot]
                case .dashed: [.single, .patternDash]
                default: .single
                }
                attributes[.underlineStyle] = underline.rawValue
                if let color = attribute.underlineColor {
                    attributes[.underlineColor] = palette.color(color, brighten: bold && palette.brightColors)
                }
            }
            if flags.contains(.crossedOut) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            return attributes
        }
    }

    private struct Palette {
        let theme: TerminalTheme
        let foreground: NSColor
        let background: NSColor
        let brightColors: Bool

        @MainActor
        init(view: TerminalView, theme: TerminalTheme) {
            self.theme = theme
            foreground = view.nativeForegroundColor.withAlphaComponent(1)
            background = view.nativeBackgroundColor.withAlphaComponent(1)
            brightColors = view.useBrightColors
        }

        func foreground(for attribute: Attribute) -> NSColor? {
            if attribute.style.contains(.inverse) { return color(attribute.bg) ?? background }
            return color(attribute.fg, brighten: brightColors && attribute.style.contains(.bold))
        }

        func background(for attribute: Attribute) -> NSColor? {
            if attribute.style.contains(.inverse) {
                return color(attribute.fg, brighten: brightColors && attribute.style.contains(.bold)) ?? foreground
            }
            return color(attribute.bg)
        }

        func color(_ value: Attribute.Color, brighten: Bool = false) -> NSColor? {
            switch value {
            case .defaultColor, .defaultInvertedColor:
                return nil
            case .trueColor(let red, let green, let blue):
                return rgb(Int(red), Int(green), Int(blue))
            case .ansi256(let code):
                let index = Int(code)
                if index < 16 {
                    let resolved = brighten && index < 7 ? index + 8 : index
                    return theme.ansiNSColor(resolved)
                }
                // SwiftTerm's active extended palette is internal. Use the standard xterm values.
                if index < 232 {
                    let levels = [0, 95, 135, 175, 215, 255]
                    let cube = index - 16
                    return rgb(levels[cube / 36], levels[cube / 6 % 6], levels[cube % 6])
                }
                let gray = 8 + (index - 232) * 10
                return rgb(gray, gray, gray)
            }
        }

        private func rgb(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
        }
    }
}
