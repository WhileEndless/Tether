# Tether

**SSH sessions that survive the network.** A native macOS SSH client built with SwiftUI.

Version 0.1.1 · [github.com/WhileEndless/tether](https://github.com/WhileEndless/tether) · [Changelog](CHANGELOG.md)

Tether keeps your remote work alive when Wi‑Fi drops or your Mac sleeps, without installing anything on the server. It also manages your `~/.ssh/config`, transfers files with drag and drop, and shows live system information for every host.

> Requires macOS 26 or later. Tether is an early release (0.1.1): expect rough edges, and please [report issues](https://github.com/WhileEndless/tether/issues).

## Features

**Sessions that survive**
- **Nothing to install on the server.** On connect, Tether checks what the server already has:
  - **tmux ≥ 3.0** → runs it in *control mode* (`tmux -CC`). You never see tmux's UI. Scrolling, selecting and copying are native, and the session keeps running on the server.
  - **GNU screen** → a screen session with local scrollback kept intact.
  - **Neither** → a plain login shell, with automatic reconnects and a local transcript.
- **Clear states.** *Online*, *Waiting* (connection lost: history stays visible, input is paused) and *Dead* (the remote session is confirmed gone: read-only and archived). A lost network is detected immediately, and a stalled server within seconds. Tabs reattach when the network returns, and also after the app is quit or crashes.
- **Background sessions.** Close a tab and keep its session running in the background. Your own tmux sessions on a server are listed too, and you can attach to them. Leftover sessions can be cleaned up.

**Terminal**
- xterm-256color and true color, mouse reporting, alternate screen, Option as Meta, and key mappings. vim, htop, fzf and emacs work as expected.
- Uses this Mac's Terminal.app profile (colors, font, translucency) by default.
- Terminal.app navigation: ⌘↑/⌘↓ jump between commands, ⇧⌘↑/⇧⌘↓ select whole commands, and PageUp/PageDown/Home/End scroll.
- Tab names follow the running command (or the current directory), and you can rename any tab.
- Local terminals on this Mac. These are persistent too when tmux is installed locally.

**Tabs and windows**
- Each window has its own tabs. Switching only swaps the terminal (instant); the sidebar and panels stay in place.
  - double-click to rename
  - live status dots
  - hold ⌘ to see tab numbers (⌘1…⌘9; ⌃Tab and ⇧⌘[ ] to cycle)
  - drag a tab out into its own window, or onto another window's tab bar
- ⌘P quick switcher and Merge All Windows. Only the visible tab is drawn, so many tabs stay cheap.
- Close a tab to keep its session in the background, or terminate it. You can also terminate every session on a host at once.
- *Disconnect & Move to Background* drops the connection but leaves tmux/screen running on the server. The session shows as *Suspended* and reattaches when you open it again.
- File managers open as tabs too, next to terminals. Each keeps its directory and selection, even in the background.

**Hosts and connections**
- Comment-preserving editor for `~/.ssh/config` (and `Include`d files), with backups before each save.
- Jump host chains (ProxyJump), each hop with its own saved password.
- *Identify by name* (HostKeyAlias), so an address reused on another network is not confused with your host.
- Direct connections (user, host, port, jump host, password or key) without saving anything.
- One authenticated connection per host (ControlMaster), shared by terminals, transfers, monitoring and port forwards.
- Passwords stay in the keychain and reach `ssh` via a private askpass bridge. A wizard can generate and install an Ed25519 key; it is offered only when key login doesn't already work.
- **Port forwarding:**
  - local, remote and SOCKS forwards saved per host, with auto-start
  - conflict checks with free-port suggestions
  - one-click forwarding of ports the server listens on
  - forwards are restored automatically after a reconnect

**Host panel**
- A live status bar above every terminal: CPU, memory, disk, load, GPU, latency and active forwards.
- Connection details: server address and port, the address you appear as, sshd ports, and latency with jitter and a quality rating.
- Metrics with sparklines, disks, and **GPUs** (NVIDIA via `nvidia-smi`, including unified-memory systems such as DGX Spark; AMD via `rocm-smi` or sysfs).
- Processes with signals, **systemd services** (start, stop, restart, logs), and **Docker/Podman containers** with their published ports and whether each is public or local only.
- **Listening ports:**
  - every TCP/UDP port the server listens on, with the process and container behind it
  - grouped by reach: all interfaces, one interface, or local only
  - one-click forwarding to this Mac
- **Network:**
  - per-interface download/upload rates, addresses, MAC and link speed
  - real interfaces first, virtual ones folded away
- System, auth and kernel logs, logged-in users, and connections (SSH detected by sshd's real ports).
- Monitoring streams over one channel and only runs while something is visible.

**Files**
- Remote file browser as a tab, a panel or a full window, with drag and drop in both directions, Quick Look and details.
- Directories you have visited open instantly from a cache and refresh in the background, keeping scroll position and selection.
- *Browse Files Here* (the terminal's current directory) and *Open Terminal Here*.
- Transfers show speed, amount transferred and ETA.
- **Drop or paste files into a terminal** to upload them — Finder files, the screenshot thumbnail, or an image on the clipboard (⌃⇧⌘4 screenshots are saved as PNG first): Tether asks for a destination (Return accepts `/tmp`), uploads, then types the remote path(s) at the prompt. Existing files are never overwritten — a free name such as `report-1.pdf` is chosen instead.
- Copy files in the file manager and paste them in Finder (and the other way round). Bulk move, copy, permissions, compress, rename and delete.

**Search**
- Search every open terminal, the archive and old recordings, with plain text or regex, case sensitivity and whole words.
- Filter by host, session, status and time (presets such as *Last 15 minutes* or an exact from/to range).
- Results show highlighted context. Double-click a result to open the terminal (or transcript) at that line; the terminal keeps the search, so ⌘G / ⇧⌘G step through the other matches there.
- Copy lines, matches or ranges. Export results as text, CSV or JSON, or export full transcripts.
- Long sessions are covered too: output that was dropped from memory is searched in the recording, without duplicates.
- A progress bar shows which source is being searched, and you can stop at any time. Compressed recordings are skipped unless you include them.

**Local backups.**
- Every session's output is recorded locally and can be replayed read-only.
- Recordings older than 7 days are compressed (LZFSE, typically 5–10× smaller).
- The 1 GB limit (default) removes the oldest recordings first.
- Only a configurable number of lines stays in memory. Older output is opened from disk with "Open Full History", which loads large recordings in slices.

## Keyboard shortcuts

Anything with ⌘ belongs to the app. Everything else — Ctrl keys, Option as Meta, Esc, function keys — goes straight to the terminal, so vim, emacs, tmux bindings and fzf behave as usual. The full, searchable list is in **Help ▸ Keyboard Shortcuts** (⌘/) and in **Settings ▸ Keyboard**.

| | |
| --- | --- |
| New connection / tab to same host / local terminal | ⌘N / ⌘T / ⌥⌘T |
| Close tab / close window | ⌘W / ⇧⌘W |
| Next / previous tab | ⇧⌘] ⇧⌘[ (also ⌃Tab, ⌥⌘→ ⌥⌘←) |
| Tab 1…8 / last tab · go to any session | ⌘1…⌘8 / ⌘9 · ⌘P |
| Move tab to background / disconnect to background | ⇧⌘B / ⌥⇧⌘B |
| Terminate session | ⌥⇧⌘W |
| Jump between commands / select a command's output | ⌘↑ ⌘↓ / ⇧⌘↑ ⇧⌘↓ |
| Find in terminal / search all sessions | ⌘F (⌘G, ⇧⌘G, ⌘E) / ⇧⌘F |
| Browse files here / file manager window / transfers | ⇧⌘O / ⌥⌘O / ⌥⌘L |
| Sidebar / host panel | ⌃⌘S / ⌥⌘I |
| Clear scrollback · font size | ⌘K · ⌘+ ⌘- ⌘0 |

Menu shortcuts can be changed in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ App Shortcuts. Terminal key mappings (for example ⌘← → Ctrl-A) are set in Settings ▸ Keyboard.

## Install

There are no signed builds yet. Build from source:

```sh
git clone https://github.com/WhileEndless/tether.git
cd tether
scripts/build-app.sh
open dist/Tether.app
```

Requires Xcode 26 (Swift 6.2) on macOS 26.

## Building

```sh
swift build                      # build everything
swift test                       # unit + local integration tests
scripts/build-app.sh             # release build → dist/Tether.app
open dist/Tether.app
```

The app is ad-hoc signed. To distribute it, sign and notarize with your own Developer ID.

## Architecture

Tether is a Swift package split into small modules:

| Module | Responsibility |
| --- | --- |
| `TetherCore` | Models, settings, paths, keychain |
| `SSHConfigKit` | Round-trip-safe `ssh_config` parser and editor |
| `SSHTransport` | ssh/scp arguments, ControlMaster, askpass bridge, remote command runner |
| `TmuxControl` | tmux control mode protocol parser and command encoder |
| `SessionKit` | Terminal sessions, remote bootstrap, persistence and reconnect state machine |
| `TerminalUI` | SwiftTerm-based terminal view, themes, key mappings |
| `RecordingKit` | Session transcripts and storage quota |
| `FileTransferKit` | Remote file listing and scp transfers |
| `MonitorKit` | System, process, log and connection probes |
| `KeySetupKit` | Key generation and installation |
| `SearchKit` | Search over live terminals and recordings, export |
| `TetherApp` | The SwiftUI application |
| `TetherAskPass` | Tiny `SSH_ASKPASS` helper that forwards prompts to the app |

Tether runs the system `/usr/bin/ssh`, so everything in your ssh config works: agents, FIDO keys, `ProxyCommand`, certificates, `Include`.

### How persistence works

When a terminal connects, Tether runs a short POSIX `sh` script on the server. It chooses tmux, screen or a plain shell, reports the choice with a private escape sequence, and `exec`s into it. On reconnect, Tether asks only to *re-attach*. If the session no longer exists, the tab is marked dead and archived instead of quietly starting a new shell.

## Privacy

Tether talks only to the hosts you connect to. Settings, host groups and recordings stay in `~/Library/Application Support/Tether`. Passwords stay in your login keychain.

Nothing is sent anywhere else: no analytics, no telemetry, no update checks.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Tether is released under the [MIT License](LICENSE). It uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Tether is an independent project and is not affiliated with Apple, tmux or GNU screen.
