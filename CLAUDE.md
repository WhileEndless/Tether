# Tether — notes for AI assistants and contributors

Tether is a native macOS (14.4+, Liquid Glass on 26) SSH client written in Swift (SwiftPM, SwiftUI + AppKit, SwiftTerm).
This file is public: it is committed to GitHub like everything else.

## Hard rules

1. **No personal data, ever.** The repository is public. Never commit real host names, IP
   addresses, user names, e-mail addresses, home-directory paths (`/Users/<name>`), machine
   names, keys, tokens, passwords, screenshots or logs from a real machine. Use `example.com`,
   `jump.example.com`, `user`, `192.0.2.x` (documentation range) in code, tests and docs.
   Resolve paths at runtime (`NSHomeDirectory()`, `FileManager`), never hard-code them.
   Run `make privacy` before every commit; review `git diff --cached` by eye as well.
2. **English only**: UI text, code, comments, docs, commit messages, release notes.
3. **Nothing is installed on servers.** Remote features use POSIX `sh` scripts sent over the
   existing SSH connection and tools that are already there (tmux, screen, tar, ps, …).
4. **Never overwrite user data** — locally or remotely. Transfers, moves and copies pick
   conflict-free names (`name-1.ext` on servers, `name 2.ext` on the Mac).
5. **Every remote script has a Windows answer.** Remote work goes through `RemoteScript(posix, windows:)`:
   give a PowerShell variant (arguments arrive as `$A`, output uses the same `@@section` formats),
   or leave `windows` nil on purpose so Windows hosts get a clear "not available" message.
6. **Secrets are never shown or typed without the user.** Saved passwords are read only to answer
   ssh (after the Touch ID check when enabled) or when the user clicks "Fill"; never prefill forms.
7. **Tests never touch the user's real data.** Unit tests, self-tests and the demo must not read or
   write the real keychain (it is in-memory under tests and `TETHER_DEFAULTS_SUITE`), the real
   preferences, the real tmux server (set `TMUX_TMPDIR` to a private folder **and unset `TMUX`** —
   with `$TMUX` set, as when tests run inside tmux, tmux ignores `TMUX_TMPDIR` and talks to that
   server), or the shared `/tmp/tether-<uid>` sockets; and they remove the temporary files they
   create, also when a test fails. Child processes in tests run through `TestSupport.BoundedProcess`
   (never wait without a timeout), and a process a test stops (SIGSTOP) is always resumed.
8. **Keys without ⌘ belong to the terminal.** App shortcuts always use ⌘ and are declared in
   `Sources/TetherApp/App/Shortcuts.swift` (menus and the Keyboard Shortcuts window read it).

## Versions and release notes

- The version lives in `VERSION` and `Sources/TetherCore/AppInfo.swift` (`AppInfo.version`);
  keep both and the README's version line in sync. Patch releases bump the last number.
- **Every version has its own notes file: `release-notes/vX.Y.Z.md`** (start from
  `release-notes/TEMPLATE.md`, list it in `release-notes/README.md`). When a change lands,
  add a line to the current version's file in the same commit — user-facing wording,
  grouped under New / Improved / Fixed / Notes. Earlier versions are not backfilled.
- Releasing: `make check` (privacy, notes, tests) → `make zip` → commit → tag `vX.Y.Z` →
  push → GitHub release with the notes file as its description and the zip attached.
  Then set the notes file's date line.

## Building and testing

```sh
make help      # all targets
make build     # swift build
make test      # swift test (no server needed; ssh is faked where required)
make app       # dist/Tether.app (release, ad-hoc signed)
make check     # privacy + release notes + tests
```

- Build with zero warnings.
- The oldest macOS is 14.4 (`platforms` in Package.swift and `MIN_MACOS` in scripts/build-app.sh,
  kept in step). Newer APIs need `#available` with a fallback, through the helpers in
  `Sources/TetherApp/Shared/Styling.swift` (Liquid Glass buttons and backgrounds, symbol effects,
  scroll geometry); symbols only in the macOS 26 SDK also go inside `#if compiler(>=6.2)`.
- Parsers, protocol code and remote scripts get tests. Remote scripts are tested by running
  them with the local shell (`ConnectionTarget.local`) or through a fake `ssh` that executes
  its last argument.
- UI changes: verify the app actually runs (`make debug`, then open `dist/Tether.app`).

## Screenshots

`make demo SHOTS=1` opens a separate "Tether Demo" app with synthetic hosts and data and saves
screenshots to `dist/screenshots/` (it needs Screen Recording permission for the demo app once per
build). Copy the ones the README uses to `docs/screenshots/`. Never take screenshots of real hosts.

## Layout

| Module | What it does |
| --- | --- |
| `TetherCore` | Models, settings (tolerant decoding; bump `AppSettings.currentVersion` + `migrate()` when defaults change), paths, keychain |
| `SSHConfigKit` | Round-trip-safe `ssh_config` parser/editor |
| `SSHTransport` | ssh/scp arguments, ControlMaster, askpass bridge, remote command runner |
| `TmuxControl` | tmux control-mode parser and encoder |
| `SessionKit` | Terminal sessions, bootstrap, persistence, reconnect, port forwards |
| `TerminalText` | Headless terminal text: the scrollback rule shared with the view, recordings as the screen showed them |
| `TerminalUI` | SwiftTerm view, themes, key mappings, pasteboard handling |
| `RecordingKit` | Transcripts (in compressed parts), encryption (also while locked), quota |
| `FileTransferKit` | Remote file system, scp and packed (tar stream) transfers |
| `MonitorKit` | Host probes (CPU, memory, GPU, services, containers, ports, logs) |
| `KeySetupKit` | Key generation and installation |
| `SearchKit` | Search over terminals and recordings |
| `TetherApp` | The SwiftUI app |
| `TetherAskPass` | `SSH_ASKPASS` helper |

## UI pitfalls seen before

- SwiftUI layout loops on macOS ("more Update Constraints in Window passes"): avoid `minWidth`
  on labels inside split views, hover-dependent row layouts, and `HSplitView`/`VSplitView`
  around wrapping text (use `ResizablePane`).
- Never mutate observable state from `updateNSView`.
- Clear `readabilityHandler` at EOF; avoid per-frame animations (`repeatForever`) in lists.
