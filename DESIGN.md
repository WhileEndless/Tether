# Tether design context

Tether is a native macOS SSH client for working across terminals, files and host monitoring.
Preserve the established SwiftUI/AppKit appearance and native keyboard conventions. Terminal
content, rather than application decoration, is the primary surface.

## Runtime ownership

- `Sources/TetherApp/Shared/Styling.swift` and `AppearanceStyle.swift` own interface styling.
- `Sources/TerminalUI/TerminalTheme.swift` owns terminal colours; user settings own terminal fonts.
- AppKit owns native controls, focus, window chrome and scrollbars. `HistoryScroller` owns the
  combined live/history terminal scroll position.
- `WindowLayout` owns window restoration and fitting to available displays. `TerminalHost` owns
  attachment and focus; terminal views own their grid and reading position.

No theme tokens or visual identity change as part of the display-stability work. Keep layout
changes quiet: preserve focus and text selection, coalesce transient sizes, and keep the title
bar reachable. Follow `UX-CONTRACT.md` for output and lifecycle behaviour.
