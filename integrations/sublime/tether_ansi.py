"""Open a color preview when ANSI terminal text is pasted into a new Sublime tab."""

from html import escape
import re

import sublime
import sublime_plugin


SGR = re.compile(r"\x1b\[([0-9;]*)m")
RESET = "\x1b[0m"
ANSI_COLORS = (
    "#000000", "#cd0000", "#00cd00", "#cdcd00", "#0000ee", "#cd00cd", "#00cdcd", "#e5e5e5",
    "#7f7f7f", "#ff0000", "#00ff00", "#ffff00", "#5c5cff", "#ff00ff", "#00ffff", "#ffffff",
)


def indexed_color(index):
    if 0 <= index < 16:
        return ANSI_COLORS[index]
    if 16 <= index < 232:
        levels = (0, 95, 135, 175, 215, 255)
        base = index - 16
        return "#{:02x}{:02x}{:02x}".format(levels[base // 36], levels[base // 6 % 6], levels[base % 6])
    if 232 <= index < 256:
        return "#{0:02x}{0:02x}{0:02x}".format(8 + (index - 232) * 10)


def ansi_html(text):
    """Render the SGR sequences emitted by Tether's Copy as ANSI action."""
    fragments = ['<body id="tether-ansi"><div style="white-space:pre-wrap;font-family:monospace">']
    foreground, background = None, None
    flags = set()

    def append(part):
        if not part:
            return
        fg, bg = foreground, background
        if 7 in flags:
            fg, bg = bg or "var(--background)", fg or "var(--foreground)"
        styles = []
        if fg:
            styles.append("color:" + fg)
        if bg:
            styles.append("background-color:" + bg)
        if 1 in flags:
            styles.append("font-weight:bold")
        if 3 in flags:
            styles.append("font-style:italic")
        if 4 in flags:
            styles.append("text-decoration:underline")
        fragments.append('<span style="{}">{}</span>'.format(";".join(styles), escape(part)))

    end = 0
    for match in SGR.finditer(text):
        append(text[end:match.start()])
        end = match.end()
        codes = match.group(1).split(";")
        # Tether emits one SGR per style or color, with a reset between runs.
        if len(codes[0]) > 3:
            continue
        code = int(codes[0] or "0")
        if code == 0:
            foreground, background = None, None
            flags.clear()
        elif code in (1, 3, 4, 7):
            flags.add(code)
        elif 30 <= code <= 37 or 90 <= code <= 97:
            foreground = indexed_color(code - (30 if code < 90 else 82))
        elif 40 <= code <= 47 or 100 <= code <= 107:
            background = indexed_color(code - (40 if code < 100 else 92))
        elif code in (38, 48) and all(channel.isdigit() and len(channel) <= 3 for channel in codes[2:]):
            color = None
            if len(codes) == 3 and codes[1] == "5":
                color = indexed_color(int(codes[2]))
            elif len(codes) == 5 and codes[1] == "2" and all(int(channel) <= 255 for channel in codes[2:]):
                color = "#{:02x}{:02x}{:02x}".format(*(int(channel) for channel in codes[2:]))
            if code == 38:
                foreground = color
            else:
                background = color
    append(text[end:])
    return "".join(fragments) + "</div></body>"


class TetherAnsiPaste(sublime_plugin.EventListener):
    pending = set()

    def on_text_command(self, view, command_name, args):
        if command_name != "paste":
            return
        self.pending.discard(view.id())
        if view.file_name() is None and view.size() == 0:
            self.pending.add(view.id())

    def on_post_text_command(self, view, command_name, args):
        if command_name != "paste" or view.id() not in self.pending:
            return
        self.pending.discard(view.id())
        window = view.window()
        if window:
            pasted = view.substr(sublime.Region(0, view.size()))
            if pasted.startswith(RESET) and SGR.search(pasted, len(RESET)):
                window.new_html_sheet("ANSI Preview", ansi_html(pasted))
