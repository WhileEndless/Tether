import AppKit
import SwiftTerm
import Testing
import TetherCore
@testable import TerminalUI

@MainActor
@Suite struct StyledTerminalCopyTests {
    private func terminal(columns: Int = 40) -> TerminalView {
        _ = NSApplication.shared
        let view = TerminalView(frame: .init(x: 0, y: 0, width: 400, height: 240),
                                font: NSFont(name: "Menlo-Regular", size: 13))
        view.getTerminal().resize(cols: columns, rows: 12)
        view.nativeForegroundColor = .white
        view.nativeBackgroundColor = .black
        return view
    }

    private func styledText(on pasteboard: NSPasteboard) throws -> NSAttributedString {
        let data = try #require(pasteboard.data(forType: .rtf))
        return try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                      documentAttributes: nil)
    }

    private func html(on pasteboard: NSPasteboard) throws -> String {
        String(decoding: try #require(pasteboard.data(forType: .html)), as: UTF8.self)
    }

    @Test func copiesPlainAndRichVersionsOfOrdinaryOutput() throws {
        let view = terminal()
        view.feed(byteArray: Array("left plain \u{1b}[1;3;4;9;31mwarn\u{1b}[0m \u{1b}[38;2;0;128;255;48;5;232mcolor\u{1b}[0m right".utf8)[...])
        view.selection.setSelection(start: .init(col: 21, row: 0), end: .init(col: 5, row: 0))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        #expect(StyledTerminalCopy.write(from: view, theme: .basicDark, to: pasteboard))
        let item = try #require(pasteboard.pasteboardItems?.first)
        #expect(pasteboard.pasteboardItems?.count == 1)
        // AppKit also advertises an automatically converted UTF-16 plain-text flavor.
        #expect(Set(item.types).isSubset(of: [.rtf, .html, .string, .init("public.utf16-external-plain-text")]))
        #expect(item.availableType(from: [.html, .string]) == .html)
        #expect(item.string(forType: .string) == "plain warn color")

        let fragment = try html(on: pasteboard)
        #expect(fragment.contains("font-weight:bold;font-style:italic;color:#e50000;text-decoration:underline line-through\">warn"))
        #expect(fragment.contains("color:#0080ff;background-color:#080808\">color"))

        let text = try styledText(on: pasteboard)
        #expect(text.string == "plain warn color")
        let plain = text.attributes(at: 0, effectiveRange: nil)
        let warning = text.attributes(at: 6, effectiveRange: nil)
        let color = text.attributes(at: 11, effectiveRange: nil)
        let font = try #require(warning[.font] as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains([.boldFontMask, .italicFontMask]))
        #expect(warning[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
        #expect(warning[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
        #expect(plain[.backgroundColor] == nil)
        #expect(plain[.foregroundColor] == nil)
        let ansi = try #require((warning[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB))
        #expect(abs(ansi.redComponent - TerminalTheme.basicDark.ansiNSColor(9).redComponent) < 0.01)
        let rgb = try #require((color[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB))
        #expect(abs(rgb.greenComponent - 128.0 / 255) < 0.01)
        #expect(rgb.blueComponent > 0.99)
        let background = try #require((color[.backgroundColor] as? NSColor)?.usingColorSpace(.sRGB))
        #expect(abs(background.redComponent - 8.0 / 255) < 0.01)
    }

    @Test func preservesWrapsHardLineBreaksAndUnicode() throws {
        let view = terminal(columns: 12)
        view.feed(byteArray: Array("abcdefghijklmno\r\n\r\nTürkçe 界 🙂 e\u{301}\r\n\r\n".utf8)[...])
        view.selectAll()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        #expect(StyledTerminalCopy.write(from: view, theme: .basicLight, to: pasteboard))
        let expected = "abcdefghijklmno\n\nTürkçe 界 🙂 e\u{301}"
        #expect(view.getSelection() == expected)
        #expect(pasteboard.string(forType: .string) == expected)
        #expect(try styledText(on: pasteboard).string == expected)
        let fragment = try html(on: pasteboard)
        #expect(fragment.contains("abcdefghijklmno<br><br>Türkçe 界 🙂 e\u{301}"))
    }

    @Test func omitsConcealedTextAndHyperlinkTargets() throws {
        let view = terminal()
        view.feed(byteArray: Array("\u{1b}]8;;https://example.com/link-target\u{7}<link>&\u{1b}]8;;\u{7} \u{1b}[8mconcealed\u{1b}[0m end".utf8)[...])
        view.selectAll()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        #expect(StyledTerminalCopy.write(from: view, theme: .basicLight, to: pasteboard))
        let plain = "<link>&" + String(repeating: " ", count: 11) + "end"
        #expect(pasteboard.string(forType: .string) == plain)
        let text = try styledText(on: pasteboard)
        #expect(text.string == plain)
        #expect(text.attribute(.link, at: 0, effectiveRange: nil) == nil)
        let rawRTF = String(decoding: try #require(pasteboard.data(forType: .rtf)), as: UTF8.self)
        #expect(!rawRTF.contains("link-target"))
        #expect(!rawRTF.contains("concealed"))
        let fragment = try html(on: pasteboard)
        #expect(fragment.contains("&lt;link&gt;&amp;"))
        #expect(!fragment.contains("link-target"))
        #expect(!fragment.contains("concealed"))
        #expect(StyledTerminalCopy.writeANSI(from: view, theme: .basicLight, encoding: .visible, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == plain)
    }

    @Test func emptySelectionsLeaveTheClipboardAlone() {
        let view = terminal()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("previous contents", forType: .string)

        #expect(!StyledTerminalCopy.write(from: view, theme: .basicLight, to: pasteboard))
        view.selection.setSelection(start: .init(col: 0, row: 0), end: .init(col: 5, row: 0))
        #expect(!StyledTerminalCopy.write(from: view, theme: .basicLight, to: pasteboard))
        #expect(!StyledTerminalCopy.writeANSI(from: view, theme: .basicLight, encoding: .visible, to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "previous contents")
    }

    @Test func ansiCopiesOnlyTextAndForegroundInBothEncodings() throws {
        let view = terminal()
        let escape = "\u{1b}"
        view.feed(byteArray: Array(("plain \(escape)[1;31mred\(escape)[0m " +
                                    "\(escape)[38;2;0;128;255;48;5;232mcolor\(escape)[0m\r\n" +
                                    "\(escape)[48;5;232mbackdrop\(escape)[0m \(escape)[7;44mreverse\(escape)[0m").utf8)[...])
        view.selectAll()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        #expect(StyledTerminalCopy.writeANSI(from: view, theme: .basicDark, encoding: .raw, to: pasteboard))
        let expected = "\(escape)[0mplain \(escape)[38;2;229;0;0mred\(escape)[0m " +
            "\(escape)[38;2;0;128;255mcolor\(escape)[0m\nbackdrop \(escape)[38;2;0;0;178mreverse\(escape)[0m"
        #expect(pasteboard.string(forType: .string) == expected)
        #expect(pasteboard.data(forType: .rtf) == nil)
        let plain = expected.replacingOccurrences(of: "\(escape)\\[[0-9;]+m", with: "", options: .regularExpression)
        #expect(plain == view.getSelection())

        #expect(StyledTerminalCopy.writeANSI(from: view, theme: .basicDark, encoding: .visible, to: pasteboard))
        let visible = try #require(pasteboard.string(forType: .string))
        #expect(visible == expected.replacingOccurrences(of: escape, with: "\\x1b"))
        #expect(!visible.contains(escape))
    }

    @Test func transcriptMenuListsPlainCopyFirst() throws {
        _ = NSApplication.shared
        let view = ReadOnlyTerminalView(frame: .init(x: 0, y: 0, width: 400, height: 240))
        let menu = try #require(view.menu(for: NSEvent()))
        #expect(menu.items.map(\.title) == ["Copy Plain Text", "Copy with Styles", "Copy as ANSI", "Select All"])
        #expect(menu.items[0].keyEquivalent == "c")
        #expect(!view.validateUserInterfaceItem(menu.items[0]))
        #expect(!view.validateUserInterfaceItem(menu.items[1]))
        #expect(!view.validateUserInterfaceItem(menu.items[2]))

        view.feed(byteArray: Array("example output".utf8)[...])
        view.selection.setSelection(start: .init(col: 0, row: 0), end: .init(col: 7, row: 0))
        #expect(view.validateUserInterfaceItem(menu.items[0]))
        #expect(view.validateUserInterfaceItem(menu.items[1]))
        #expect(view.validateUserInterfaceItem(menu.items[2]))
    }

    @Test func liveTerminalMenuCopiesOnlyTheSelectedOutput() throws {
        let fixture = try HistoryBrowsingTests.Fixture(lines: [], scrollback: 500)
        let view = fixture.view
        let menu = try #require(view.menu(for: NSEvent()))
        #expect(menu.items.map(\.title) == ["Copy Plain Text", "Copy with Styles", "Copy as ANSI", "Paste", "Select All"])
        let copy = menu.items[0]
        #expect(menu.items[0].keyEquivalent == "c")
        #expect(!view.validateUserInterfaceItem(copy))

        view.feed(Array("prefix output suffix".utf8)[...])
        view.selection.setSelection(start: .init(col: 7, row: 0), end: .init(col: 13, row: 0))
        #expect(view.validateUserInterfaceItem(copy))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(view.copySelectedText(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "output")
        #expect(pasteboard.data(forType: .rtf) == nil)
        #expect(view.copySelectedText(to: pasteboard, format: .styled))
        #expect(try styledText(on: pasteboard).string == "output")

        var settings = AppSettings()
        settings.terminalCopyFormat = .styled
        view.apply(settings: settings)
        let styledDefaultMenu = try #require(view.menu(for: NSEvent()))
        #expect(styledDefaultMenu.items.map(\.title) == menu.items.map(\.title))
        #expect(styledDefaultMenu.items[0].keyEquivalent.isEmpty)
        #expect(styledDefaultMenu.items[1].keyEquivalent == "c")
        #expect(view.copySelectedText(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == "output")
        #expect(try styledText(on: pasteboard).string == "output")
        #expect(view.copySelectedText(to: pasteboard, format: .plain))
        #expect(pasteboard.string(forType: .string) == "output")
        #expect(pasteboard.data(forType: .rtf) == nil)
    }

    @Test func ansiMenuUsesVisibleCodesByDefaultEvenWithBackgroundEnabled() throws {
        let fixture = try HistoryBrowsingTests.Fixture(lines: [], scrollback: 500)
        let view = fixture.view
        var settings = AppSettings()
        settings.terminalCopyFormat = .styled
        settings.copyTerminalBackground = true
        view.apply(settings: settings)
        view.feed(Array("\u{1b}[38;2;20;40;60;48;2;70;80;90mcolor\u{1b}[0m".utf8)[...])
        view.selectAll()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        #expect(view.copySelectedANSI(to: pasteboard))
        let expected = #"\x1b[0m\x1b[38;2;20;40;60mcolor\x1b[0m"#
        #expect(pasteboard.string(forType: .string) == expected)
        #expect(pasteboard.data(forType: .rtf) == nil)

        settings.ansiCopyEncoding = .raw
        view.apply(settings: settings)
        #expect(view.copySelectedANSI(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == expected.replacingOccurrences(of: #"\x1b"#, with: "\u{1b}"))
    }

    @Test func terminalBackgroundIsOptInAndPreservesExplicitBackgrounds() throws {
        let view = terminal()
        view.feed(byteArray: Array("base \u{1b}[48;2;20;40;60mhighlight\u{1b}[0m".utf8)[...])
        view.selectAll()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var settings = AppSettings()
        settings.terminalCopyFormat = .styled

        #expect(StyledTerminalCopy.writeSelection(from: view, theme: .basicDark, settings: settings, to: pasteboard))
        #expect(!(try html(on: pasteboard)).contains("background-color:#000000"))
        #expect((try html(on: pasteboard)).contains("background-color:#14283c"))

        settings.copyTerminalBackground = true
        settings.terminalCopyFormat = .plain
        #expect(StyledTerminalCopy.writeSelection(from: view, theme: .basicDark, settings: settings,
                                                  format: .styled, to: pasteboard))
        let fragment = try html(on: pasteboard)
        #expect(fragment.contains("color:#ffffff;background-color:#000000"))
        #expect(fragment.contains("background-color:#14283c"))
        let rich = try styledText(on: pasteboard)
        let background = try #require((rich.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB))
        #expect(background.redComponent < 0.01)
        #expect(background.greenComponent < 0.01)
        #expect(background.blueComponent < 0.01)
    }
}
