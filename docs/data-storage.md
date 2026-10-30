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
| Session recordings (terminal output) | `Recordings/<host>/` | Storage limit (1 GB by default). Old recordings are compressed while the Mac is idle (after 7 days by default; see below). When the limit is reached, in this order: whatever waits to be compressed is compressed; recordings past the optional number of days to keep are removed; the largest session loses its oldest parts while it holds more than half of the space (only a session kept in parts, see below); then the oldest recordings go. |
| Command history | `Command History/` | 90 days and 50 MB by default, at most 500 commands per host. The oldest finished commands go first. |
| Hosts, groups, tags | `hosts.json` | — |
| Archive of ended sessions | `archive.json` | 500 entries |
| Open sessions, windows (frames and side panels), file tabs | `open-sessions.json`, `workspaces.json`, `window-layout.json`, `file-tabs.json` | Only what is open |
| Settings | the app's preferences | — |
| Passwords, key passphrases and the recording key | the macOS keychain (service "Tether SSH Password"; a key's passphrase is the item `passphrase:<key file>`) | Removed with the host, the password or the passphrase |
| Sign-in passwords remembered for this run (Settings ▸ Passwords ▸ Signing In Again) | Tether's memory only, encrypted by a Secure Enclave key that is never saved — nothing on disk (see [connections-and-passwords.md](connections-and-passwords.md)) | Gone when Tether quits or locks (App Lock), when the server refuses one, with *Forget*, when the setting is turned off, after the time chosen, on screen lock if chosen; saved passwords remembered this way also go when the screen locks or the Mac sleeps if Touch ID is required |

Temporary files outside this folder:
- Connection sockets and askpass: `/tmp/tether-<uid>/`, private to you. ssh removes its own sockets.
- ssh logs of a connection attempt: also there. The name is removed when the sign-in ends; a connection's log is emptied every few minutes while it runs.
- Previews of remote files (Quick Look, dragging out): the system's temporary folder, removed after a day.
- Hang records: when Tether stops answering for a few seconds or takes long to quit, macOS's `sample`
  of the process (function names only, nothing a terminal showed) in `~/Library/Logs/Tether/`; the
  last five are kept, at most one in ten minutes.
- An update being prepared (Settings ▸ General ▸ Updates): the release's source, its build and `update.log` in `tether-update-work` in your temporary folder (private to you), removed once the update is installed.

## Recordings in detail

- **What is recorded:** the bytes a terminal received, exactly as received (escape sequences
  included). Replaying them through a terminal shows what the screen showed.
- **Writing:** in batches of 512 KB, so a busy terminal does not wear the disk; a quiet terminal's
  output is written 30 s after its first unwritten byte (5 minutes inside tmux, whose history on
  the server holds it too if Tether stops and gives it back on re-attach; within 5 s for a minute
  after a command in a shell nothing else keeps — a plain or local shell, Windows), and at once
  when the connection drops, the Mac goes to sleep, a tab closes or Tether quits. Scrolling back,
  finding, searching and copying read what is not written yet from memory: they never make the
  recorder write early. The storage limit is checked at most once a minute while output flows.
- **After a relaunch:** a restored tmux or screen tab goes on with its recording (up to 128 MB of
  output; a larger one stays as it is and a new one starts). The tab first shows the end of it, as
  it was when Tether quit (modes a program had set then, such as mouse reporting, are not kept), then adds only what the server printed meanwhile; the recording holds
  nothing twice, and scrolling back reaches past the relaunch. The recording is read through once,
  in the background, to know where its lines and commands are. A continued recording is kept in
  the archive even if the tab is closed before it connects.
- **Catching up after a reconnect (tmux):** the last rows the screen showed are looked up in what
  the server kept, 1,000 rows first, then 10,000, then everything it keeps. A line that was still
  being written when the connection dropped (a prompt, a progress bar) is completed in place rather
  than shown twice. When those rows are not there at all (the screen was cleared, or more was
  printed than the server keeps), everything it keeps is added under a note that earlier lines may
  repeat — rather than lose any of it.
- **Long sessions:** every 16 MB of output by default (Settings ▸ Recordings), the file is moved aside
  as a numbered part (compressed later, see below). Recording goes on in a fresh file.
  - The latest output is never compressed, so scrolling back stays fast.
  - Scrolling back past memory shows the recording, read in the background, in a view over the
    terminal (which is not touched). That view holds at most about 64 MB of lines; scrolling
    further moves it through the recording a chunk at a time. It is let go of 30 s after leaving it.
  - While a session runs, Tether keeps in memory where every 256th line (at least 64 KB apart) and
    every command (with its time) is in the recording, so the scroller, ⌘↑/⌘↓ and find reach any part without reading it
    all. Commands are also noted in the recording itself with an invisible marker
    (`ESC ] 7771 ; mark=<milliseconds since 1970> BEL`, next to the terminal size marker), and
    so are a Ctrl+L, each further Return of a paste and Tether's own redraw on a re-attach
    (`ESC ] 7771 ; typed BEL`). Shown again, a recording keeps the same screens in the scrollback
    as the terminal did: a clear right after typing keeps the screen above it, one a program makes
    on its own (a progress display, `docker stats`) does not.
  - A tab off screen for a minute keeps only its last 2,000 lines in memory; the rest is read back
    from its recording when it is scrolled to. Tabs without a recording keep their whole scrollback.
  - Search, export and playback read the parts and the file as one recording.
- **Compression** (LZFSE, about 5–10× smaller; encrypted recordings stay encrypted) reads and
  rewrites every byte, so it waits until the Mac is idle: macOS's background scheduler offers a
  moment about every 10 minutes, and Tether takes it only when the keyboard and mouse have been
  left alone for 2 minutes, Low Power Mode is off, the Mac is not hot and Tether is unlocked. It
  compresses one file at a time — the parts of long sessions, then recordings older than the set
  number of days — and stops between files as soon as someone uses the Mac or macOS asks it to.
  Only when the storage limit is reached is it done at once, before anything is removed.
  Settings ▸ Recordings shows how many files wait, why they wait, when it last ran and what it
  saved, with *Compress Now*.
- **When the disk is full:** recording pauses and goes on once there is space again. The recording
  then says how much output is missing.
- **The terminal's size** is noted in the recording when it changes (and every megabyte), with an
  escape sequence terminals ignore, so playback and the text of the recording lay output out as
  it was shown.
- **While Tether is locked:** new recordings (and new parts) are sealed to the public half of the
  recording key (HPKE: X25519, HKDF-SHA256, ChaCha20-Poly1305). The private half is derived from
  the recording key and never stored. The public half is kept in the keychain, next to the key,
  and read only the first time something is sealed while locked. Locking also lets go of earlier
  output each terminal read back from its recording (it is read again when scrolled to after
  unlocking), and a restored tab continues an encrypted recording only once Tether is unlocked;
  with encryption on, a recording in plain text is never added to (a new, encrypted one starts).
- **After the Tether password is reset:** recordings still being written with the old key stop
  and remove themselves; the others encrypted with it are removed, as nothing could read them.
  Only files built like encrypted ones are removed: plain output that merely starts the same way
  is the user's text and stays.
- **Secrets in the archive** (Settings ▸ Security): archived sessions' recordings are masked once
  they end. Recordings no archived session refers to (left by a crash, or by quitting with
  restoring turned off) are masked too; each notes the rules it was looked through with in an
  extended attribute of its file (`io.github.whileendless.tether.masked`, a fingerprint of the
  rules), so it is read again only when the rules change.
- **Encrypted recordings:** AES-256-GCM, frame by frame. A frame cut short by a crash is dropped when
  the recording is opened again, so everything written after it stays readable.

## Command history in detail

- **What is kept:** each command line (secrets masked), when it ran, and its lowest, average and
  peak use. Also the processes it ran and the connections it had, up to 50 of each. Never the
  command's output.
- **Writing:** a second after a command starts or ends, and every 5 minutes while one runs. Changes
  are added to a small journal next to the host's file (`<file>.journal`, each entry compressed
  and sealed on its own); the file is written whole only when commands are removed or the journal
  has grown (256 KB, or larger than the file), and the journal then goes. An entry cut short (Tether
  stopped while adding it) is skipped when read and the host's next write is the whole file, which
  removes the journal; one that could not be added completely (a full disk) is cut off at once. Files are compressed, and sealed when encryption
  is on.
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
