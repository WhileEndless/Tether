# Contributing

- Keep modules focused; UI code lives in `TetherApp`, logic in the kits.
- Add tests for parsers and protocol code (`swift test`).
- Never commit real host names, user names or paths — use `example.com` and `user` in tests and docs.
- Run `swift build` with no warnings before opening a pull request.
- New menu commands get their shortcut from `Sources/TetherApp/App/Shortcuts.swift`, so the Keyboard Shortcuts window stays complete. Keep ⌘ for the app; never take a key without ⌘ away from the terminal.
- Write everything (UI text, code, comments, commits) in English.
- Add a line for every user-facing change to `release-notes/v<current version>.md` in the same commit (see `release-notes/README.md`).
- Run `make check` before opening a pull request. Project rules are in `CLAUDE.md`.
