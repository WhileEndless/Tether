# Connections and passwords

How Tether keeps connections to servers alive, when it signs in, and what happens to the
passwords you type. Everything here is what the code does; the settings named are in
Settings ▸ Sessions, ▸ SSH and ▸ Passwords.

## One signed-in connection per server

Tether uses OpenSSH's shared connections (ControlMaster). For each server it signs in once and
keeps that connection; terminals, the file manager, transfers, port forwards and monitoring all run
as channels inside it.

- **One sign-in, however many things need it.** When 50 tabs, a file window and three transfers
  want the same server at the same moment, one sign-in runs and all of them wait for it
  (`SharedConnections` in `Sources/SSHTransport`). Closing the tab that started it does not stop it
  while others still wait.
- **Nothing else signs in.** Every ssh and scp Tether starts for a server is a client of the shared
  connection that cannot sign in by itself (`ControlMaster=no`, plus a `ProxyCommand` that fails at
  once). If the connection is not there, it fails and asks for the connection again — which is the
  one sign-in above, never a second password question of its own.
- **Several aliases, one server.** The connection is found the way ssh finds it (`ssh -G`, which
  reads your ssh_config; nothing goes over the network), so two names for the same user, host,
  port and jump host share it.
- **Jump hosts.** A server behind a single jump host is reached through the jump host's own shared
  connection, so the jump host is signed in to once for every server behind it. A chain of jump
  hosts, or a ProxyCommand of your own, uses ssh's own hop.
- **More tabs than a connection carries.** sshd allows 10 sessions per connection by default
  (`MaxSessions`). Tether puts up to 5 terminals on the first connection (it also carries the file
  manager and monitoring) and 8 on each further one; a server that allows fewer says so and the tab
  moves on. Each further connection is a sign-in of its own (see "Signing in again" below).

## Keeping the connection

Plain `ssh` with default settings sends nothing while you are idle, so a short outage, a Wi-Fi
hand-over or a sleeping Mac does not end it. Tether does the same:

- **No keep-alives by default.** Tether sends none (Settings ▸ Sessions ▸ Connection Health ▸ Send keep-alives); your
  own ssh_config still applies. With keep-alives, a connection that misses the set number of
  answers ends — also across a Wi-Fi hand-over or right after waking, when the network is not back
  yet.
- **A silent channel holds it open.** Each shared connection has one channel running
  `exec cat >/dev/null` (PowerShell's equivalent on Windows), which prints nothing. It keeps the
  connection from closing merely because no tab used it for a while — also across sleep, during
  which ssh's own idle clock keeps running on macOS. It is not opened on network devices, which run
  nothing Tether sends.
- **Short outages go unnoticed.** When the network goes away, tabs stop judging whether the server
  answers. Only after it has been away for 20 s (Settings ▸ Sessions ▸ Connection Health) do tmux
  and screen tabs detach from their server sessions; they re-attach when it is back.
- **Before the Mac sleeps,** tmux and screen tabs let go of their server sessions (they keep running
  on the server) and monitoring stops, so the server has nothing to send while the Mac cannot
  answer — a server whose data goes unacknowledged gives up on the connection after some minutes.
  Tether never keeps the Mac awake and changes no power setting.
- **When the Mac wakes or the network returns** (also when it changes, e.g. Wi-Fi to Ethernet or a
  VPN), each shared connection is checked over its own link. It is closed only when it clearly no
  longer reaches the server, or stays silent for 20 s while the Mac is awake and online (10 s after
  the way out changed: a connection over the old one has most likely died with it; Settings ▸
  Sessions ▸ Connection Health). Tabs waiting on it say "Checking the connection…". They then
  re-attach through the connection that survived, or sign in again by themselves.
- **Retry / Reconnect Now** starts again at once, also while an attempt hangs: the connection is
  asked for up to 4 s, closed if it does not answer, and the tab (with the host's other waiting
  tabs) starts afresh.
- **A server that does not answer is tried once per round, for all its tabs.** A sign-in waits
  20 s for the server (Settings ▸ Sessions ▸ Reconnecting; with or without connection sharing).
  When it gets no answer — timed out, refused, no route, host name not found — the server's waiting
  tabs try again together after 2 s, then 4 s, 8 s and so on, up to 2 minutes (the first and the
  longest wait are set there too). A hundred tabs mean one attempt per round, not a hundred:
  without connection sharing, where each tab signs in by itself one after another, a tab whose
  turn comes right after another tab's attempt failed takes that failure as its own and waits for
  the next round. The rounds start afresh, and every waiting tab tries at once, when the network
  comes back or changes, when another tab to that server connects, and for the tab you press
  *Reconnect Now* on. A new tab waits for such a server too, instead of giving up (an unknown host
  name or a changed host key still end it). A wrong password or a cancelled question is not the
  server's absence: it pauses only that tab until you press Reconnect, and the server's other tabs
  go on with their own sign-ins. Host panels ask
  a server that does not answer less and less often in the same way, and at once when a tab to it
  connects.
- **A tab that hears nothing** for 15 s (awake and online time only) re-attaches through the
  shared connection, and that connection is checked.
- **Quit** ends every shared connection at once; the sessions on the servers keep running and the
  next launch signs in once per server. With *Keep connections open after quitting* (Settings ▸
  SSH ▸ Multiplexing, off by default) they stay for the time set there, so relaunching within it
  signs in nobody — and, like any ssh ControlMaster, any program of yours can use them meanwhile
  without a password. If Tether ends unexpectedly, the silent channel's input closes and the
  connection ends after that time too.

## Signing in again

A connection that really ended — the server restarted, a firewall dropped it during a long
absence — needs a new sign-in, as does a further connection for more tabs. Tether asks for it
once per server, never once per tab:

- Tabs, windows and transfers waiting for the same server share the one sign-in. A tab in the
  background does not raise the question; it appears when you look at a tab of that server.
- A server's connections sign in one after another: while one signs in (the first or a further
  one), the others wait, so the password typed there answers them too and a remembered one is
  never sent by several connections at once.
- **Cancel** stops every tab of that server from asking again until you press Reconnect.
- A password you type answers the sign-ins of the same server that are waiting at that moment.

### Remembered for this run (Settings ▸ Passwords ▸ Signing In Again)

With *Remember sign-in passwords while Tether runs* (on by default), a password you typed — or a
saved one unlocked with Touch ID — also answers that connection's later sign-ins while Tether runs:
a reconnect after the connection really ended (also from tabs in the background), a further
connection for more tabs, every tab's own sign-in when connections are not shared. This is what
other SSH clients call caching session passwords (SecureCRT keeps such passwords in memory as they
are; Tether keeps them sealed). Tether keeps it as follows:

- **Only sealed.** It is encrypted with a P-256 key created inside the Mac's Secure Enclave when
  Tether needs it. That key cannot be exported, is never saved (not in the keychain, not on disk)
  and is gone when Tether quits. A copy of Tether's memory — a dump, a swap file — taken while no
  sign-in is in progress holds only the encrypted form, which nothing but this running Tether on
  this Mac can open — no other process, no other Mac, no later run. It is opened when a sign-in
  needs it. To be plain about the limits: the copies made while handing it to ssh (and while you
  type it) are ordinary memory that Tether cannot reliably overwrite, so freed copies can linger
  for a while, as they do in ssh itself. Other programs of the same user cannot read Tether's
  memory (hardened runtime, see below).
- **Never written anywhere.** Nothing of it goes to disk, preferences, logs or recordings.
- **Only after it worked.** It is kept only once the server accepted it; a typo is never kept.
- **Only for its connection.** (A key's passphrase is the exception: see *Key passphrases* below.)
  It belongs to the connection it was typed for — ssh's own name
  for it, made from the host name, port, user and jump host — and to the login ssh named in its
  question. Another port, another jump host or another user is another entry, even when the
  question looks the same. It answers only ssh's own question (`user@host's password:` or
  `(user@host) Password:`) for a host on that connection's own path — never text a server prints,
  never a jump host asking for another host's password. With an ssh older than OpenSSH 8.4, which
  does not mark a server's own questions, nothing is remembered — and nothing saved is filled in by
  itself either: the ssh that actually asks is checked (also one a ProxyCommand starts from PATH),
  and its question is shown with a warning, since a jump host behind it could have written it.
- **Never anything else.** It never answers a one-time code, a "new password" question or any
  question in a terminal: `sudo`, `su` and the like still ask you (or use a password you saved in
  the keychain, as before). Background work never receives it.
- **Touch ID still applies.** A saved password remembered this way is used again only as your
  Touch ID setting allows (after the time you chose, and again after locking the screen or sleeping,
  when it is also forgotten). A password you typed is used without asking — also one you typed
  and ticked *Remember in Keychain* for, in this run (you have just typed it); after Tether
  restarts, the saved copy asks for Touch ID as set.
- **Forgotten** when a sign-in it answered fails, whatever the reason — the server refused it, or
  hung up instead of asking again (fail2ban, pam_faillock, network devices), or the sign-in was
  stopped —, so a changed password is never retried on every reconnect. (A sign-in that fails
  before ssh asks for it — no network, host not found — forgets nothing.) Also when Tether locks (App Lock), when
  you press *Forget*
  (each entry is listed, with its login and since when) or turn the setting off, after the time
  you choose (*Forget them*: 1 hour, 8 hours or a day — the default — after it
  was typed, using it does not extend that; or only when Tether quits),
  with *Also forget them when the screen locks or the Mac sleeps*, and when Tether quits.
- **Not available** on a Mac without a Secure Enclave (Intel Macs without a T2 chip): there nothing
  is remembered, rather than keeping it unsealed.

Turned off, nothing is kept: every new sign-in asks once per server.

### What cannot be promised

- A password you type passes through Tether to ssh (`/usr/bin/ssh` holds it while it signs in).
  Tether is built with the hardened runtime and without the debugging entitlement, so other
  programs of the same user cannot read its memory; an administrator who switched off System
  Integrity Protection can.
- A sign-in nobody can answer (you are away, nothing remembered or saved) waits until you are back.
  The same holds for a session you asked to *End When Connected*.
- For servers that end connections often, an SSH key (*Set Up SSH Key…* on a host in the sidebar) signs in without any password at all.

## Servers that ask something first, or have no full shell

Tether starts each terminal with a short shell script (it finds tmux or screen). Not every server
runs it:

- **A question at login** (a notice to accept, a menu, a program the server runs instead of a shell
  — `ForceCommand`): what the server prints is shown as it comes. When it prints something and then
  waits, the connection card steps aside after 2 s ("Waiting for the server"), so the question can
  be read and answered in the terminal; the session starts when the server's shell does. A host
  never seen before is asked one short question first: one that answers with anything but a
  shell's answer is taken as a network device or limited shell and gets a plain login, shown at once.
- **A forced password change** ("Your password has expired"): ssh shows the server's questions in
  the sign-in panel. A remembered or saved password never answers them by itself — only ssh's own
  `user@host's password:` question is answered that way —, so *Current password*, *New password* and
  *Retype* are always yours to type. Afterwards the old password is refused once and forgotten;
  update a saved one in Settings ▸ Passwords.
- **A restricted shell** (`rbash` and the like) answers the first question like any shell, then
  refuses the script. Tether says so in the terminal, remembers the host as a limited shell and
  opens a plain login at once. Nothing is run on such a host (Host ▸ Edit ▸ Shell changes that).
- **No answer at all** within 20 s while something is on the screen and nothing asks for a password:
  the tab is used as it is, as a plain session.

## Saved passwords (keychain)

Saving a password is separate and always your choice (*Remember in Keychain*). Saved passwords
stay in the login keychain, encrypted by macOS; with Touch ID required (Settings ▸ Passwords), it
is asked before one is read, then not again for the time you chose — locking the screen or sleeping
asks again, also for the remembered copy above. See `docs/data-storage.md` for where things are
stored.

## Key passphrases

A passphrase opens a key file on this Mac; it never goes to a server. ssh asks for it
(`Enter passphrase for key '/path/to/key':`) and Tether answers the same way as for a password,
with these differences:

- **One passphrase per key file**, whatever hosts and tabs use it. The keychain item and the copy
  remembered for the run belong to the key file (one name however it is reached: `~`, a symbolic
  link), not to a connection. Many tabs or hosts opening the same key at once are asked once.
- **Asked only by ssh itself.** A passphrase is answered without asking only when the ssh asking
  marks a server's own questions (OpenSSH 8.4 and later, as on every supported macOS). Tether looks
  at the program that asks — also the ssh a jump host or a ProxyCommand starts, which may be
  another build found on PATH — and asks it `-V` once (again after it is updated). With an older or
  unknown ssh, the question is shown with a warning that the server may have written it, and
  nothing is filled in or saved, so a server cannot word a question as your key's prompt.
- **A wrong passphrase** makes ssh ask again: a saved one is then not sent again, you are told it
  did not open the key, and what you type replaces it. After `ssh-keygen -p` outside Tether, the
  saved passphrase is out of date in the same way; Settings ▸ SSH ▸ Keys changes both together.
- **Jump hosts:** a jump host and the target that use the same key each open it (they are
  separate ssh processes); the second is not taken for a wrong passphrase.
- **Skip This Key** lets ssh go on without the key (the next key, or the server's password);
  *Cancel* ends the sign-in.
- **Kept when the server refuses.** A remembered passphrase stays when a server turns the key
  down: the key opened with it, the server refused something else.
- **Security keys** (FIDO, `sk-ed25519`): the PIN is asked every time and never remembered; while
  the key waits to be touched, Tether says so, and the notice goes when ssh is done.
- **ssh-agent** and macOS's `UseKeychain`: a key the agent holds is not asked for at all. Key setup
  writes `IgnoreUnknown UseKeychain` before `UseKeychain yes`, so an ssh other than Apple's (such as
  Homebrew's) still reads the config. `AddKeysToAgent ask` is asked with Yes and No.
- **In a terminal** (`git push`, `ssh` from a shell on this Mac), the bar fills a key's saved
  passphrase only while an ssh tool on this Mac reads it: the terminal is in line mode with echo
  off, the program in its foreground is ssh, ssh-add or ssh-keygen (or runs one, as git does), and
  every ssh there is OpenSSH 8.4 or later. This is checked again right before typing. Text a server
  prints through an ssh that is already connected (the terminal is in raw mode then), or asks
  through an older ssh, is never answered with your key's passphrase, even when it looks like the
  prompt.
- **Background work** (monitoring, checks) never gets a passphrase: it uses the shared connection,
  or waits for you.
- Settings ▸ Passwords lists saved passphrases and marks those whose key file is gone.

## Ending a session while its server cannot be reached

*Terminate* on a tmux or screen tab whose connection is down first reaches the server (one sign-in
for it if needed) and ends the session there. If the server cannot be reached, you choose:
*End When Connected* moves the tab to the background (marked "Ends when connected") and ends the
session as soon as the server can be reached again, also after Tether restarts; opening the tab
again, or *Don't End* in its menu, takes that back. *Keep in Background* keeps it for you to close
later. Closing a tab without ending its session needs nothing from the server and happens at once.

## When a session ends on the server

A shell (or tmux session) can end on the server while the connection is fine — the server ran out
of memory and its kernel ended processes, the shell has an idle limit, the server restarted. Only
that tab is affected; the connection and the other tabs carry on. Unless you ended it yourself
(`exit`, `logout`, Ctrl-D — only those words are looked for in what you type, nothing is kept),
Tether takes one short, read-only look over the connection and says what it found next to
"Session ended": memory in use, the kernel's out-of-memory messages from the last 15 minutes (when
the account may read them), `TMOUT`, the server's uptime, the signal that ended the shell. The same
goes to the Connection Log.

## Following what happened

Help ▸ Connection Log lists what happened to connections while Tether runs, newest first:

- **Sign-ins**: when one starts (and through which jump host), how long it took and how ssh signed
  in (`password`, `publickey`, …), with ssh's steps below it — where it connected, the server's
  software, the host key check, which ways of signing in the server offered. A failed sign-in
  shows the same steps and ssh's last words. Questions cancelled, answered with a remembered
  password, or ended because nobody answered.
- **Connections**: reused, checked after waking or a network change (and how long the check took),
  closed as dead, ended (and how long they lived).
- **Tabs**: connecting (new or re-attaching, tmux or screen, which try), connected and how long it
  took, letting go, trying again and when, re-attaching (how many lines were printed while away),
  refused sessions, ending and why.
- **Network and sleep**: sleeping, waking, the network going and coming back, with the network
  interfaces in use; **port forwards** made or stopped; **Tether** starting, locking and unlocking.

Each event names its host and its tab (the tab's title and its tmux or screen session). The bar at
the top shows everything, notices and problems, or problems only, one host, one kind of event, or
what matches a search. *Copy* and *Save…* take the events shown, oldest first, with ssh's words
indented below each. It is kept in memory only (the last 3,000 events) and never holds a password,
a passphrase or anything typed; your home folder is written `~`.

The same events go to macOS's own log (Console.app: subsystem `io.github.whileendless.tether`,
category `connections`), where host names and ssh's own messages are marked private.
