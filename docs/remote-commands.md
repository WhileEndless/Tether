# What Tether runs on your hosts

Tether installs nothing on a server. Everything it needs to know about a host comes from small
scripts. They are sent over the SSH connection that is already open, and they run with the
tools the host already has. On this Mac, the same scripts run in the local shell. This page lists
every one of them and explains, for each:

- when it runs,
- what it reads,
- what it changes,
- how it ends.

The app shows the same list, with the full text of each script, in
**Settings ▸ Monitoring ▸ What Runs on Hosts…**. That list is built from the scripts the app runs,
so it is always current. A test checks that this page names every entry in it.

## Switching it off

Everything below that runs by itself can be switched off: for every host in **Settings ▸
Monitoring**, or for one host from its sidebar menu (**Monitoring**), the host panel's menu, or its
editor. A host's own choice comes before the system setting. **Monitor the host** off stops every
script that reads the host's system at once; browsing files and your port forwards keep working.
The in-app list names, for each script, the switches that stop it.

## Network devices and limited shells

Routers, switches and firewalls (Cisco IOS/NX-OS/ASA, Arista, Junos, FortiOS, PAN-OS, RouterOS,
Check Point, F5), menus and limited shells (git-shell, ForceCommand) have no shell Tether's scripts
could run in, and their command line could take a script's lines as its own commands. So:

- On first contact Tether asks two harmless questions: `echo "TETHER:%OS%:$PSHOME:"` (which also
  tells sh, cmd and PowerShell apart) and, only when that got no shell's answer, `echo TETHER-SHELL`
  (which csh, fish and every other shell answer). A host that answers neither is remembered as a
  network device or limited shell. A host that cannot be reached is asked again later.
- To such a host Tether sends nothing but the terminal's login: `ssh -tt host` with no command, so
  the device shows its own command line. No script below runs there; monitoring, file browsing,
  uploads, session persistence and key setup are off. Downloads use classic scp (`scp -O`), and port
  forwards use the connection (`ssh -O forward`), checked with `ssh -O check`.
- If a host does not start Tether's session at all but shows something (a menu, a device that
  ignores the command), the tab is used as it is after 20 seconds instead of waiting.
- Each host's choice can be set by hand: Edit Host ▸ Shell, or the host's Monitoring menu.

## Principles

- **Nothing is installed.** Scripts are POSIX `sh` on Linux, macOS and the BSDs, and PowerShell on
  Windows. They use only standard tools: `/proc`, `ps`, `ss`/`netstat`, `lsof`, `awk`,
  `nettop` on macOS, CIM on Windows. A missing tool means less detail, never an error in your
  terminal.
- **Nothing is written on the host.** No script creates files. The only exception is the GNU screen
  settings file described under *Terminals* below, which is private and removed after 10 seconds.
- **Nothing is left running.**
  - One-off scripts end by themselves.
  - Streams (the host status, the command watcher, traffic by process) end when Tether stops
    reading them: the connection closes and their next write fails. Each stream writes a
    heartbeat at least every 10 seconds, so this happens within seconds even when nothing changes.
    On Windows the watcher and the traffic stream also end as soon as the SSH session that started
    them is gone.
  - The traffic stream also stops the `nethogs` it started (and the `script` and `tail` helpers
    started with it).
- **One per host, not one per tab.** All terminals of a host share one command watcher and one
  command look. The host status, server sessions and traffic by process are also one per host.
- **Read-only unless you ask.** Only actions you start yourself change anything:
  - stopping a command or process,
  - service and container actions,
  - deleting a Kubernetes pod,
  - installing a key,
  - transferring files.
  Actions that need root use `sudo -n`, which never asks for a password and fails instead.
- **Everything is optional.** Turn features off in Settings ▸ Monitoring:
  - the bar below the terminal,
  - the command watcher (and how often it checks),
  - how often commands and traffic are measured,
  - the command history and its details.
- **Private tabs** (⌥⇧⌘T) still run the watcher and the looks while the tab is open, for the live
  view. Nothing about them is kept on this Mac.

## Host panel and running commands

### Host status stream
- **When:** while the host status bar or the host panel is shown, every few seconds (Settings ▸
  Monitoring ▸ Refresh).
- **Reads:** CPU, memory, disk, load, network counters, GPU (nvidia-smi, rocm-smi or sysfs when
  present) and OS details. Once per stream it also checks which of docker, podman, kubectl, k3s,
  microk8s and oc exist (`command -v`), so the Containers and Kubernetes tabs show only where they
  can work.
- **Changes:** nothing. Ends when Tether stops reading.

### Running command watcher
- **When:** while terminals to the host are online. One watcher covers all of a host's terminals.
  By default it checks every 0.5 s (Settings ▸ Monitoring ▸ Check every), and it can be turned off.
- **Reads:** the foreground process group of each terminal's shell. When that changes, it also
  reads the command line of the program in front.
  - On Linux it reads `/proc/<pid>/stat` with shell built-ins; only `sleep` runs between checks.
  - Elsewhere it runs one `ps` (and `awk`) per check for all terminals together.
  - On Windows it runs one CIM process query per second.
- **Changes:** nothing.
- **Writes back:** one line per change, plus a heartbeat every 10 s. Ends when Tether stops
  reading.
- **Why:** idle terminals then cost nothing, and commands are noticed the moment they start, even
  short ones.

### Running command look
- **When:** while a command runs in a terminal (or its details are shown). By default every
  3 s (Settings ▸ Monitoring ▸ Measure running commands every). One look covers all terminals of the
  host. Without the watcher (turned off, or not working on that host), terminals whose state is
  unknown are looked at every 5 s instead.
- **Reads, once per look and shared between terminals:**
  - all processes (`/proc/*/stat`, or `ps`) and the process tree below each shell,
  - command lines, users, CPU time, memory, threads, and disk I/O counters (`/proc/<pid>/io`),
  - sockets (`ss -tunap` or `netstat`; `lsof` on macOS and the BSDs),
  - the kernel's TCP byte counters (`ss -tinp`) or `nettop` on macOS,
  - ICMP and raw sockets (`/proc/net/icmp`, `/proc/net/raw`).
  - On Windows: `Win32_Process`, `Get-NetTCPConnection` and `Get-NetUDPEndpoint`.
- **Changes:** nothing. Ends when done.

### Traffic by process
- **When:** while the Network tab of the host panel is shown. By default every 2 s (Settings ▸
  Monitoring ▸ Sample traffic by process every).
- **Reads, the first of these that works:**
  1. `nettop` on macOS.
  2. `nethogs`, only when it is already installed and may run as root or with passwordless sudo
     for nethogs.
  3. The kernel's TCP counters (`ss -tinp`).
  4. Connections only (`netstat`; `Get-NetTCPConnection` on Windows).
- **Changes:** nothing. Ends when Tether stops reading, and stops the `nethogs` it started.
- **Suggestions:** when a tool would give more detail, the card suggests the install command for the
  host's distribution, for example `sudo apt install iproute2 nethogs`. Tether never runs it; you
  decide.

### Stop a running command
- **When:** only when you click Terminate or Kill in the Command tab, after confirming.
- **Changes:**
  - Sends TERM or KILL to the command's process group and to each of its processes, so nothing it
    started keeps running in the background.
  - Never signals the shell, the shell's group, group 1 or its own group. When those groups cannot
    be read, only the listed processes are signalled.
  - On Windows: `taskkill /T`, plus `/F` for Kill. Console programs often ignore Terminate there;
    the panel then says so, and Kill ends them.
- **Reads:** whether any of the processes are still running a second later. If some are, the panel
  tells you.

### Host name of a connection
- **When:** only when you open the details of a connection.
- **Reads:** the host's own name for the remote address (`getent`, `host`, `dscacheutil`; .NET DNS on
  Windows).
- **Changes:** nothing.

### Processes
- **When:** while the Processes tab is shown.
- **Reads:** `ps` (`Get-Process` on Windows).
- **Changes:** nothing.

### Send a signal to a process
- **When:** only when you choose Terminate, Kill, Hang Up or Interrupt in the Processes tab.
- **Changes:** sends that signal to the selected process.

### Listening ports
- **When:** while the Ports or Network tab is shown.
- **Reads:** listening sockets (`ss`, `netstat` or `lsof`).
- **Changes:** nothing.

### Connections and logins
- **When:** while the Network tab is shown, every 10 s.
- **Reads:** `who`, established TCP connections and sshd's ports.
- **Changes:** nothing.

### GPU processes
- **When:** while the GPU tab is shown.
- **Reads:** `nvidia-smi` or `rocm-smi` process lists.
- **Changes:** nothing.

### Services
- **When:** while the Services tab is shown.
- **Reads:** `systemctl`, `launchctl` or rc.d service lists.
- **Changes:** nothing.

### Start, stop or restart a service
- **When:** only when you choose it.
- **Changes:** runs that action, with `sudo -n` when needed.

### Containers
- **When:** while the Containers tab is shown.
- **Reads:** `docker ps` or `podman ps`.
- **Changes:** nothing.

### Container actions
- **When:** only when you choose start, stop, restart or logs.
- **Changes:** that action on that container.

### Server sessions
- **When:** when terminals to the host connect, then every 15 s while a window is visible.
- **Reads:**
  - tmux and screen sessions and the program in front in each pane,
  - the names of coding-agent sessions (Claude Code, Codex, opencode), read from those tools' own
    files.
- **Changes:** nothing.

### Logs
- **When:** when you load a log in the Logs tab.
- **Reads:** `journalctl`, `/var/log` files, `log show` or the Windows event log, as chosen.
- **Changes:** nothing.

### Kubernetes
- **When:** while the Kubernetes tab is shown, on hosts with kubectl, k3s, microk8s or oc.
- **Reads:** the pods of the current context.
- **Changes:** only on request: deletes a pod you chose.

## Terminals

- **Starting a terminal:**
  - A one-line `sh` program picks the persistence that exists on the host (tmux, GNU screen, or a
    plain login shell). It reports its choice and the shell's process id with a private escape
    sequence that Tether removes from the output.
  - tmux gets its own session for the tab, with its scrollback limit set on that session only.
    Your tmux settings and other sessions are not touched.
  - GNU screen gets a private settings file (random name, readable only by you), removed after
    10 seconds.
- **Windows:** the tab runs PowerShell with `-EncodedCommand`. The command contains a random tag as
  a comment, so the watcher and the look can find that PowerShell later.
- **Latency:** without tmux, an empty command (`:`) is timed now and then over the shared connection.

## Files, transfers, keys and forwards

- **File manager:**
  - Lists folders with `find`, `stat` or `ls` (PowerShell on Windows).
  - Creates, renames, moves or deletes only what you ask for.
  - Never overwrites: new names are free ones (`name-1.ext`).
- **Transfers:** use `scp`, or a `tar` stream for many files (unpacked by `tar` on the host). They
  write only the files you transfer. Before an upload under a new name, the name is checked to be
  still free (the file manager's listing script). When such an upload fails or is cancelled, the
  partial file it made is removed (`rm -rf -- <that path>`, `Remove-Item` on Windows); nothing else
  is touched.
- **Key setup:** appends your public key to `~/.ssh/authorized_keys` (on Windows, also
  `administrators_authorized_keys` for administrators). Only when you ask, and only if the key is not
  there yet. Then one login with that key alone (`exit`, nothing else) checks that it works; a
  key's passphrase is given to ssh through Tether's askpass, never on a command line.
- **Port forwards:** handled by `ssh` itself. No command runs on the host.

## What stays on this Mac

The command history stays on this Mac:

- **Where:** `~/Library/Application Support/Tether/Command History`.
- **Format:** compressed, and encrypted when recordings are.
- **Limits:** kept for 90 days and up to 50 MB by default. Commands still running are never removed.
- **Masking:** secrets in command lines are masked before anything is kept.

## Limits worth knowing

- Commands shorter than the watcher's check interval (0.5 s by default) are not seen.
- A command that ends before it is measured is kept with its command line and duration only.
- Network speed per connection:
  - Linux: TCP only, kernel 4.1 or later, and one's own processes unless the user is root.
  - macOS: TCP and UDP, through nettop.
  - Windows: connections are listed, but without speeds.
- ICMP (ping and similar) is not counted in bytes on any system. Its target is shown from the
  socket list or, where the system shows no socket (Windows), from the command line.
