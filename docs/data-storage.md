# What Tether keeps, and how

Everything Tether keeps stays on this Mac. Nothing is uploaded anywhere, and nothing is written on
servers apart from what you ask for (files you transfer, a key you install). Scripts that run on
hosts to look at them are listed in [remote-commands.md](remote-commands.md).

## Rules every store follows

1. **Nothing you made is overwritten.** Files are written next to the old one and swapped in when
   complete. A file Tether cannot read (damaged, or written by a newer version) is moved aside as
   `name.unreadable-<date>.json` and left there, never replaced.
2. **Nothing grows without a limit.** Each store has a size or count limit, and a rule for what goes
   first when it is reached. What is being written (the current file of a running session's
   recording, a running command's history record) is never removed.
3. **A failure never stops the app, and never loses data quietly.** A write that fails is tried again.
   Problems are collected in the panel's warning sign, never printed into a terminal.
4. **Encrypted stays encrypted, also while locked.** With encryption on (Settings ▸ Security),
   recordings and the command history are encrypted with the recording key. While Tether is locked
   that key is not in memory: new output and history are then sealed to its public half, so they
   are kept, and only unlocking opens them. (The public half is saved the first time Tether is
   unlocked with encryption on; before that, nothing is recorded while locked.) Nothing is ever
   written in plain text.
5. **Nothing is left behind.** Temporary files are removed when done, or at the next launch.
6. **Private tabs** keep nothing: no recording, no archive entry, no command history.
7. **One Tether at a time.** A second copy started with the same data folder brings the first one to
   the front and quits, before it touches anything.

## The stores

| What | Where (`~/Library/Application Support/Tether`) | Limit, and what goes first |
| --- | --- | --- |
| Session recordings (terminal output) | `Recordings/<host>/` | Storage limit (1 GB by default). In this order: old recordings are compressed (after 7 days by default); recordings past the optional number of days to keep are removed; the largest session loses its oldest parts while it holds more than half of the space (only a session kept in parts, see below); then the oldest recordings go. |
| Command history | `Command History/` | 90 days and 50 MB by default, at most 500 commands per host. The oldest finished commands go first. |
| Hosts, groups, tags | `hosts.json` | — |
| Archive of ended sessions | `archive.json` | 500 entries |
| Open sessions, windows, file tabs | `open-sessions.json`, `workspaces.json`, `window-layout.json`, `file-tabs.json` | Only what is open |
| Settings | the app's preferences | — |
| Passwords and the recording key | the macOS keychain | Removed with the host or password |

Temporary files outside this folder:
- Connection sockets and askpass: `/tmp/tether-<uid>/`, private to you. ssh removes its own sockets.
- ssh logs of a connection attempt: also there. Removed when the attempt ends, or after a day.
- Previews of remote files (Quick Look, dragging out): the system's temporary folder, removed after a day.

## Recordings in detail

- **What is recorded:** the bytes a terminal received, exactly as received (escape sequences
  included). Replaying them through a terminal shows what the screen showed.
- **Writing:** in batches (512 KB, or 15 s after the first unwritten byte), so a busy terminal does
  not wear the disk. A crash loses at most those 15 s. The terminal still showed them.
- **Long sessions:** every 16 MB of output by default (Settings ▸ Recordings), the file is moved aside
  as a numbered part and compressed in the background. Recording goes on in a fresh file.
  - The latest output is never compressed, so scrolling back stays fast.
  - Scrolling back reads at most 16 MB at a time, and keeps at most 250,000 lines in memory.
  - Search, export and playback read the parts and the file as one recording.
- **When the disk is full:** recording pauses and goes on once there is space again. The recording
  then says how much output is missing.
- **The terminal's size** is noted in the recording when it changes (and every megabyte), with an
  escape sequence terminals ignore, so playback and the text of the recording lay output out as
  it was shown.
- **While Tether is locked:** new recordings (and new parts) are sealed to the public half of the
  recording key (HPKE: X25519, HKDF-SHA256, ChaCha20-Poly1305). The private half is derived from
  the recording key and never stored. The public half is kept in the keychain, next to the key,
  and read only the first time something is sealed while locked.
- **After the Tether password is reset:** recordings still being written with the old key stop
  and remove themselves; the others encrypted with it are removed, as nothing could read them.
  Only files built like encrypted ones are removed: plain output that merely starts the same way
  is the user's text and stays.
- **Encrypted recordings:** AES-256-GCM, frame by frame. A frame cut short by a crash is dropped when
  the recording is opened again, so everything written after it stays readable.

## Command history in detail

- **What is kept:** each command line (secrets masked), when it ran, and its lowest, average and
  peak use. Also the processes it ran and the connections it had, up to 50 of each. Never the
  command's output.
- **Writing:** a second after a change, and every 30 s while a command runs. Files are compressed,
  and sealed when encryption is on.
- **While Tether is locked** (encryption on): history is sealed to the public half of the key, like
  recordings. A host's file that cannot be opened is never overwritten: commands recorded meanwhile
  go to `<file>.pending-<run>.json` next to it, and are merged into it (and the pending file removed)
  once it opens.
- **After the Tether password is reset:** encrypted history files can never be opened again, so
  they are removed, like encrypted recordings.
- **Export** (Command tab ▸ History, or Settings ▸ Monitoring): CSV with one row per command, per
  process or per connection, or JSON with everything.

## The text of a session (search, plain-text export)

The recording keeps the bytes as received. Search and plain-text export read them through a
terminal emulator, so the text is what the terminal showed:

- a line counts as it finally looked (progress bars, spinners and in-place edits give one line);
- full-screen programs (vim, less, htop) add nothing; the output before and after them is kept;
- a program that clears everything and prints its whole screen again (Claude Code redrawing) adds
  each line once: after a clear, a run of at least four lines that repeats, in order, what was
  there right up to the clear is skipped. The same command run again later (after other output)
  is kept;
- a terminal multiplexer you start yourself inside a tab (tmux or screen on the alternate screen)
  counts as a full-screen program: what runs in it is in the transcript and the raw recording, not
  in the text. Tether's own tmux and screen sessions are not affected;
- Save Session (plain text) takes the text from the recording when there is one, so it holds each
  line once even where the screen kept every redraw;
- output never erases the history on screen (`clear`, `ESC[3J`) unless Settings ▸ Terminal ▸
  Programs may clear the scrollback is on. The recording keeps everything either way; remove a
  session from the archive to delete it.

## On servers

- **tmux and screen sessions:** Tether starts one per tab, and they keep 100,000 lines of scrollback by
  default (Settings ▸ Sessions). They end when you terminate the session. A tab closed without
  terminating keeps its session running, to attach again later.
  - A session that never came online is ended when its tab closes.
  - A session that was restored, or opened to attach to an existing one, is never ended.
- **Transfers:** they write only the files you transfer, under free names. A cancelled or failed
  copy removes the partial file it made, and nothing else: on a server only when that name was
  still free right before the copy started (checked then).
- **Nothing else is written.** See [remote-commands.md](remote-commands.md).
