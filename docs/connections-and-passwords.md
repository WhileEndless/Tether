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
  port and jump host share it. Its socket is named after that server (a short hash in Tether's
  socket folder), not after this Mac's own host name as ssh's `%C` is — that name can change with
  the network, and a second connection would then sign in next to the first. What ssh_config says
  is worked out afresh when the network changes or the Mac wakes (`Match` rules may pick another
  jump host then).
- **Jump hosts.** A server behind a single jump host is reached through the jump host's own shared
  connection, so the jump host is signed in to once for every server behind it. A chain of jump
  hosts, or a ProxyCommand of your own, uses ssh's own hop.
- **More tabs than a connection carries.** sshd allows 10 sessions per connection by default
  (`MaxSessions`). Tether puts up to 5 terminals on the first connection (it also carries the file
  manager and monitoring) and 8 on each further one; a server that allows fewer says so and the tab
  moves on. Each further connection is a sign-in of its own (see "Signing in again" below). Work in
  the background (file listings, panels) that the server's limit refuses for a moment is asked
  again shortly; a command that already started is never run twice.
- **Servers that ask a second step** (a one-time code, a push to approve) after the password: every
  further connection would ask it again, so once a server has asked one, all its tabs, file
  windows, transfers and panels share its first connection for as long as the server allows (a
  session it refuses moves that tab to another connection). The code is asked once, in the sign-in
  panel — a file window never needs one of its own.
- **Plain shells on a connection of their own.** A tab set to a plain shell (no tmux or screen) on
  a server whose other tabs use tmux gets its own shared connection: a plain shell that keeps
  printing while the Mac sleeps can make the server end the connection it is on, and that should
  not be the one the re-attaching tabs use.
- **Your ssh_config.** Tether adds its own options on the command line, where they win over
  ssh_config, and keeps what matters from yours: a `ConnectTimeout` you set is used (a sign-in
  through a browser-based proxy may need longer), a `ServerAliveInterval` you set is kept (below),
  forwards from ssh_config are set up by the first connection only, and one that cannot be set up
  never fails the sign-in. A `RemoteCommand` is not run: every tab, listing and transfer runs its
  own command (ssh would refuse both); a tab says so once.

## Keeping the connection

A short outage, a Wi-Fi hand-over or a sleeping Mac should not end a connection, and an idle one
should not be forgotten by a firewall or router on the way:

- **Patient keep-alives.** Every 60 s Tether's shared connection sends a keep-alive (Settings ▸
  Sessions ▸ Connection Health), so firewalls and NAT routers that forget idle connections after a
  few minutes keep it. They end a connection only after at least 10 minutes without any answer,
  whatever count is set, so a Wi-Fi hand-over, a VPN reconnecting or the first moments after
  waking do not end it. A `ServerAliveInterval` in your ssh_config is kept (a short one is usually
  there for a firewall that forgets fast) and only its count raised to last as long. Network
  devices get none from Tether. Turned off, only an interval set in your ssh_config is used (its
  count still raised). These rules are for the shared connections; with connection sharing off,
  each ssh gets Tether's keep-alive and ConnectTimeout as set.
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
- **When the Mac wakes or the network returns** (also when it changes: Wi-Fi to Ethernet, a VPN,
  another Wi-Fi network on the same interface, a new address, another interface preferred), each
  shared connection is checked over its own link: the server is asked to forward to a closed port
  on itself (`ssh -W 127.0.0.1:9` through the connection). Nothing runs on the server — no session,
  no shell, nothing counted against its session limit —, and its refusal, which comes at once, is
  the answer (also where forwarding is forbidden). The server's log may show the refused forward
  ("connect_to 127.0.0.1 port 9: failed" or "refused local port forward"). A connection is closed
  only when it clearly no longer reaches the server, or stays silent for 20 s while the Mac is
  awake and online and nothing else arrives on it (10 s after a long sleep or when the way out
  changed: a connection over the old one has most likely died with it; Settings ▸ Sessions ▸
  Connection Health). One that does not even answer when asked to close has its ssh ended. Tabs
  waiting on it say "Checking the connection…". They then re-attach through the connection that
  survived, or sign in again by themselves, at once. A connection kept from the last run (*Keep
  connections open after quitting*) is checked the same way before it is used; there, no answer
  within 8 s counts as dead (its tabs would otherwise hang on it), and it is replaced.
- **Retry / Reconnect Now** starts again at once, also while an attempt hangs. The connection is
  checked as above; only one found dead is closed — never one that is merely slow, which other
  tabs may be using.
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
  name or a changed host key still end it, and a sign-in Tether restarted because the network changed
  under it counts as no answer, not as a failed sign-in). A wrong password or a cancelled question is not the
  server's absence: it pauses only that tab until you press Reconnect, and the server's other tabs
  go on with their own sign-ins. Host panels ask
  a server that does not answer less and less often in the same way, and at once when a tab to it
  connects.
- **A tab that hears nothing** for 15 s (awake and online time only) re-attaches through the
  shared connection, and that connection is checked. A plain shell in front whose server does not
  answer a check for 10 s has its connection checked too.
- **A new tab whose host name does not resolve** is tried a few times first (right after waking,
  or while a VPN comes up, names do not resolve for a moment), then ends.
- **Connection sharing turned off** (Settings ▸ SSH): the shared connections take nothing new;
  what runs on them — plain shells, transfers, forwards — goes on until it ends. Without sharing,
  every ssh and scp signs in by itself; each is told about as a sign-in of its server, so a
  password typed for one transfer or listing is remembered (Signing In Again) and answers the
  others, and a question open for one is answered for all open at the same time. A fixed time
  limit never ends one while its question is open.
- **When a server can be reached again** — it signed in (any tab, any window), the network came
  back, the Mac woke, Tether was unlocked — what waited for it goes on at that moment: file views
  whose listing failed load again (also their first listing), port forwards waiting for it are made
  (and forwards on a connection that ended are noticed the moment it ends),
  host panels start, and a transfer stopped by a lost connection, a moment's session limit or a
  sign-in nobody could answer is sent once more (right away, or as soon as the network is back:
  up to half an hour). A sign-in you cancel is not asked again by what follows by itself (the next
  queued transfer, a file window): Retry or Reconnect asks.
- **Quitting** asks first when it would end something that does not come back — plain shells (also
  on this Mac), running transfers, port forwards that are not reopened by themselves (not those
  listening only on this Mac, nor any while *Keep connections open after quitting* is on) — offering *Quit When Transfers Finish*, and *Don't
  ask again*. Not when macOS logs out, restarts or shuts down, nor for *Restart to Update* (which
  says the same in its own question).
- **A transfer** keeps the Mac from going to sleep by itself while it runs (closing the lid still
  does); sleeping time does not count as a stalled transfer, and one stopped by a lost or stalled
  connection is tried once more by itself a few seconds later. Previews, drags to Finder and
  copies for the clipboard go ahead of long transfers.
- **A plain shell** (no tmux or screen) ends with its connection; when the connection is back a new
  shell starts in the same tab, below the old output — unless the one before ended within 30 s
  three times in a row. What was typed while it was away is not sent to the new shell.
- **Before the Mac sleeps** the recording notes a pause, not a lost connection.
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
- **Cancel** stops every tab of that server from asking again until you press Reconnect; the
  server's other connections waiting for that sign-in stop too, instead of each asking in turn.
  The same goes for a password the server refused.
- **A password you type answers the server's other sign-ins for a minute** — the further
  connections for more tabs, a file window, a retry — also with remembering turned off (below). It
  is held sealed, only for that connection, and dropped at once when the server refuses it.
- **Take your time.** While the question is open, nothing times out on Tether's side; after you
  answer, the server gets 2 minutes to check it (PAM, LDAP, a push approval) before the sign-in is
  stopped. A question answered after the server's own login time (about 2 minutes) is not lost:
  the sign-in starts again and takes your answer without asking.
- **Nobody there.** A question for a tab in the background waits until you look at a tab of that
  server; after 90 s its sign-in is ended (the server would close it anyway), and every tab that
  waited for it — of that server, another name for it, or a server behind it — waits to be shown,
  then asks once. A saved password that needs Touch ID while the Mac sleeps or its screen is locked
  is handled the same way. While Tether is locked (App Lock) nothing signs in at all; tabs sign in
  once it is unlocked.

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
  (For a minute it is also handed to the same connection's other sign-ins, see above.)
- **Only for its connection.** (A key's passphrase is the exception: see *Key passphrases* below.)
  It belongs to the connection it was typed for — the host name, port, user, ProxyCommand and
  jump host as ssh works them out (`ssh -G`; not the socket name, which also depends on this Mac's
  own name and can change with the network) — and to the login ssh named in its question; the same
  account under another name for the server (another alias, Quick Connect) finds it too. Another
  port, another jump host or another user is another entry, even when the question looks the same.
  It answers only ssh's own question (`user@host's password:`, or `(user@host) Password:` also as
  PAM words it — `password:`, `Password for <account>:`) for a host on that connection's own path —
  the names ssh itself uses count, also those that come from wildcard or `Match` blocks, `%h` or a
  HostKeyAlias —, never text a server prints, never a jump host asking for another host's
  password. A directory account whose name holds "@" (`user@corp.example.com`) is recognized. With an ssh older than OpenSSH 8.4, which
  does not mark a server's own questions, nothing is remembered — and nothing saved is filled in by
  itself either: the ssh that actually asks is checked (also one a ProxyCommand starts from PATH),
  and its question is shown with a warning, since a jump host behind it could have written it.
- **Never anything else.** It never answers a one-time code, a "new password" question or any
  question in a terminal: `sudo`, `su` and the like still ask you (or use a password you saved in
  the keychain, as before). Background work never receives it.
- **Touch ID once.** A saved password is read from the keychain only after Touch ID, as your
  setting asks. Once it signed a connection in, it is remembered like a typed one: reconnects —
  also after the Mac slept or the screen locked — and new tabs to that server sign in without
  asking again, until it is forgotten (below). After Tether restarts, the keychain asks for Touch
  ID as set.
- **Forgotten** when the server judged it: it refused it, or hung up instead of asking again
  (fail2ban, pam_faillock, network devices), so a changed password is never retried on every
  reconnect. The same login question asked again right after it counts as a refusal —
  unless what you type then is only digits (4 to 10): that is taken as a one-time code the server
  asks with the same words, and the password before it is kept (the code is neither remembered
  nor saved). A sign-in the server never judged forgets nothing: one that failed before ssh asked
  for it (host not found), because the network did (no answer, no route, the network changed
  while signing in — usual right after waking), or that Tether or you stopped (a tab closed,
  Retry, Cancel on a later question, Tether locked). One the server received and then never
  answered within 2 minutes is sent once more at most, then forgotten. Also forgotten when you
  remove or replace the saved password it came from, when
  you press *Forget*
  (each entry is listed, with its login and since when) or turn the setting off, after the time
  you choose (*Forget them*: 1 hour, 8 hours or a day — the default — after it
  was typed, using it does not extend that; or only when Tether quits),
  with *Also forget them when the screen locks or the Mac sleeps*, and when Tether quits. Locking
  Tether (App Lock) keeps them, but nothing uses them — nothing signs in — until it is unlocked.
- **Not available** on a Mac without a Secure Enclave (Intel Macs without a T2 chip): there nothing
  is remembered, rather than keeping it unsealed.

Turned off, nothing is kept beyond the minute in which a typed password answers the server's other
sign-ins waiting for it (sealed, as above); a sign-in after that asks again, once per server.

### What cannot be promised

- A password you type passes through Tether to ssh (`/usr/bin/ssh` holds it while it signs in).
  Tether is built with the hardened runtime and without the debugging entitlement, so other
  programs of the same user cannot read its memory; an administrator who switched off System
  Integrity Protection can.
- A sign-in nobody can answer (you are away, nothing remembered or saved) waits until you are back.
  The same holds for checking a session you closed while its server could not be reached.
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

Saving a password is separate and always your choice (*Remember in Keychain*). Typed for a sign-in
through a shared connection, it is saved once that sign-in worked (one typed after the server's
login time ran out: once the fresh sign-in it is handed to worked); with connection sharing off,
in Quick Connect, or in the bar of a terminal, it is saved when you choose to, and only for the account's own password: a one-time code, a
second factor or a new password asked after it never replaces it. Saved passwords stay in the
login keychain, encrypted by macOS; with Touch ID required (Settings ▸ Passwords), it is asked
before one is read, then not again for the time you chose — locking the screen or sleeping asks
again before the keychain is read; unlocking Tether counts as that check. Touch ID is not asked
while nobody can answer it (the Mac asleep, its screen locked): the sign-in waits until you are
back. A copy already remembered for a connection (above) is not asked for again. A password typed
in Quick Connect goes to that connection without Touch ID, whether you saved it or not.

A saved password the server refused is not sent by itself again in that run, until you save it
anew: a stale saved password resent at every sign-in could lock the account. You are asked
instead, with *Update the saved password* ready.

When ssh asks although passwords are remembered, Help ▸ Connection Log says why (*No remembered
password for this sign-in*: nothing remembered for this connection yet, forgotten and why, or one
remembered for another connection of the same login), and when one was remembered. See `docs/data-storage.md` for where things are
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

*Terminate* on a tmux or screen tab whose connection is down first tries the server for a few
seconds (at once you choose when the network is away) and ends the session there. If the server
cannot be reached, you choose — and nothing is ended on the server without you:

- *Close for Now* moves the tab to the background, paused (marked "Closed while offline"). Once the
  server can be reached again (a sign-in, the network back, also after Tether restarts), Tether
  looks for the session quietly: still there, the mark says "Still running on server" and a
  notification tells you — open it, *End on Server…*, or *Keep Running* in its menu; gone, the tab
  goes. A server that needs a password for that is asked the next time you sign in to it.
- *Keep in Background* keeps it for you to close later.

A tab that never connected has nothing on the server and closes at once; so does closing a tab
without ending its session.

Paused tabs — suspended, or waiting for you to sign in or for Reconnect — are looked for the same
way when their server answers again: a tab whose session is gone from the server closes by itself
(its output stays in the archive); one whose session is still there stays as it was. A tab that
retries by itself finds out when it re-attaches: one you were working in stays, read-only, and
says the session no longer exists (or ended — see below); one in the background closes.

## Sessions left on a server

Closing a tab without ending its session leaves that session running on the server. Tether notes
it on this Mac — the server's session name, and the name and color you gave the tab (never a title
taken from what ran in it; private tabs leave no note) — for up to 90 days, 200 at most. Under the
host they are listed first, under their tabs' names, and open again with a click, as the tab they
were. *Open or End N Detached Sessions…* in the host's menu, and *Terminate All Sessions on This
Host…*, act only on these, and leave one alone that somebody attached to since the list was read.
A note goes when its session is ended from Tether (and is found gone afterwards), or found gone.

Other Tether sessions on the server — another Mac's, or someone else's who signs in with the same
account — are listed too ("Detached session"), but are only opened or ended one by one, by you.
Anyone who signs in with the same account can see and attach to all of them: that is how tmux and
screen work, and Tether cannot hide them; use your own account on shared servers. Tabs marked "Ends when connected" by earlier versions become "Closed
while offline": they are not ended by themselves.

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
  shows the same steps and ssh's last words. What kind of question was asked (the account's
  password, a one-time code, a key's passphrase — never its text), how it was answered (remembered,
  keychain, typed, handed on), why nothing remembered answered it, a refused password, Touch ID
  cancelled, an answer that came late, and every time a remembered password is forgotten, with why.
- **Connections**: the keep-alive and timeout each one signs in with; reused, checked (why, and how
  long the check took), closed as dead, ended — how long they lived and ssh's own last words about
  why (*Timeout, server not responding*, *Connection reset* …).
- **Tabs**: connecting (new or re-attaching, tmux or screen, which try), connected and how long it
  took, letting go, trying again — when, and what made it try now —, a server that stopped
  answering (with the times measured), re-attaching (how many lines were printed while away),
  refused sessions, ending and why.
- **Network and sleep**: sleeping, waking, the network going and coming back, with the network
  interfaces in use, how long the Mac slept and whether it woke on another network; the screen
  locking (and what that did to remembered passwords); **port forwards** made or stopped;
  **Tether** starting (with the settings that decide connections and sign-ins, and the ssh
  program's check), those settings changing, locking and unlocking.

Each event names its host and its tab: a number that stays the same while Tether runs, the tab's
title (in Tether only) and its tmux or screen session. The bar at the top shows everything, notices
and problems, or problems only, one host (events of no host — sleep, the network — stay, as they
explain the host's), one kind of event, or what matches a search. *Copy* and *Save…* take the events
shown, oldest first, with ssh's words indented below each, after a header (Tether's and macOS's
versions, the time zone, the span, and how many older events were let go); times are local, with
their offset from UTC, and tabs appear by number and session only — a title can hold a command
line. It is kept in memory only (the last 3,000 events) and never holds a password, a passphrase or
anything typed; your home folder is written `~`.

The same events go to macOS's own log (Console.app: subsystem `io.github.whileendless.tether`,
category `connections`), where host names and ssh's own messages are marked private.
