# Copying terminal output

Select text in a live terminal, scrollback, or an archived transcript and choose a copy action from the context menu.

| Action | Clipboard contents |
| --- | --- |
| **Copy Plain Text** | The selected text. |
| **Copy with Styles** | HTML and RTF with colors and text styles, plus a plain-text representation for apps that accept text only. |
| **Copy as ANSI** | Text with foreground color codes. Visible `\x1b[…]` escape codes are the default. |

Under **Settings ▸ Terminal ▸ Copying**, set **Default copy format** for ⌘C and for **Copy text on selection** in live terminals and scrollback. The default is **Plain Text**. **Include terminal background** is off by default. Turn it on to include the terminal's theme background in styled copies. ANSI copies carry foreground colors and use the destination's background.

Tether joins rows wrapped by the terminal and preserves line breaks supplied by the program. Some full-screen programs draw their own wrapped rows, so use the program's copy command when you need the source text. Whole-command selections backed by a recording copy as plain text.

## Sublime Text preview

The optional package opens a color preview when you paste raw ANSI into an empty, untitled Sublime Text 4 tab. The original tab holds the editable text with its ANSI control codes.

1. In Sublime Text, use **Preferences ▸ Browse Packages…**. Create a `Tether ANSI` folder and copy [`tether_ansi.py`](../integrations/sublime/tether_ansi.py) into it.
2. In Tether, open **Settings ▸ Terminal ▸ Copying** and set **ANSI copy encoding** to **Raw ANSI**.
3. Select terminal output, choose **Copy as ANSI**, and paste into an empty, untitled Sublime Text tab. Sublime opens an **ANSI Preview** tab for the colors.
