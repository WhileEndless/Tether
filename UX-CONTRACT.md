# Tether interaction contract

Repository behaviour and privacy rules are maintained in `CLAUDE.md`. This document records
the shared interaction rules for display changes and terminal output.

| Capability | Canonical owner | Behaviour | Verification |
| --- | --- | --- | --- |
| Terminal output | `ProcessBridge`, `TerminalOutputBuffer`, `OutputScheduler` | Preserve byte order; share a main-thread budget; encrypt overflow with an ephemeral key; keep resource management invisible during normal use. | Buffer, scheduler and local-session tests |
| Terminal attachment | `TerminalHost`, `TerminalRegistry` | A session belongs to one host; keep focus in a field the user is editing. | Terminal window and tab-switch tests |
| Reading history | `HistoryTerminalView`, `ReflowPlaces` | Resizing preserves the text being read and selection; a display-scale change does not return to live output. | History browsing and display tests |
| Window layout | `WindowLayout`, `WindowPlacement` | Keep usable frames unchanged; fit inaccessible frames after display changes; defer fitting during full-screen transitions. | Placement tests and synthetic app checks |
| Monitoring | `CommandHub` | Hidden windows reduce polling; every idle/throttled loop suspends; cancelled generations cannot change a replacement loop. | Scheduling tests |

Terminal output buffering is transient, including for private tabs. It is not a recording and
does not enter search, export or the archive. Keys stay in memory; consumed temporary files
are removed. Capacity exhaustion waits for space instead of dropping bytes. Unreadable or
unauthenticated data enters the existing connection-failure flow and is recorded in the
connection log without terminal contents.

Menus and shortcuts remain owned by `Shortcuts.swift`. This work adds no setting, dialog,
notification, loading overlay or new keyboard command.
