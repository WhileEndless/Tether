import Foundation

// Scripts for the command running in a terminal (`CommandSampler`) and for traffic per process
// (`ProcessTraffic`). Nothing is installed: Linux is read from /proc with awk (the same on
// Debian, RHEL/CentOS, Arch, Alpine/busybox …), macOS and the BSDs from ps, Windows from CIM.
// Every part is optional: what a host cannot tell is simply missing from the output.

extension ProbeScripts {
    /// Shell functions that print network use per process and per connection as `@@flows` lines:
    ///
    ///     P<TAB>pid<TAB>name<TAB>bytes received<TAB>bytes sent              a process (totals)
    ///     F<TAB>pid<TAB>name<TAB>proto<TAB>local<TAB>peer<TAB>received<TAB>sent    a connection
    ///
    /// Counters are totals since the process or socket started ("-" when unknown); rates come from
    /// two looks. `$1` = " pid pid … " to keep, "" for all. Nothing is captured or installed:
    /// Both read their source on stdin, so one read can serve several terminals:
    /// - `tcp_counters` (Linux) reads `ss -tinp`: the kernel's tcp_info counters of each TCP socket
    ///   (kernel 4.1+; one's own processes, root sees all; no UDP).
    /// - `nettop_flows` (macOS) reads one sample of `nettop -L 1 -n -x -J bytes_in,bytes_out`.
    static let flowFunctions = #"""
tcp_counters() {
  awk -v pids="$1" '
    /^[^ \t]/ { k = ""; n = ""; if (match($0, /\("[^"]*",pid=[0-9]+/)) { u = substr($0, RSTART + 2, RLENGTH - 2); n = u; sub(/",pid=.*/, "", n); p = u; sub(/.*pid=/, "", p)
      if (pids == "" || index(pids, " " p " ")) k = "F\t" p "\t" n "\tTCP\t" $4 "\t" $5 } next }
    k != "" { r = "-"; s = "-"; a = "-"
      for (i = 1; i <= NF; i++) { if ($i ~ /^bytes_received:/) r = substr($i, 16); else if ($i ~ /^bytes_sent:/) s = substr($i, 12); else if ($i ~ /^bytes_acked:/) a = substr($i, 13) }
      if (s == "-") s = a; print k "\t" r "\t" s; k = "" }'
}
nettop_flows() {
  awk -F, -v pids="$1" '
    NR == 1 { next }
    $1 ~ /^(tcp|udp)[46]? / { if (keep) { split($1, a, " "); m = split(a[2], e, "<->")
        print "F\t" p "\t" name "\t" toupper(substr(a[1], 1, 3)) "\t" e[1] "\t" (m > 1 ? e[2] : "*:*") "\t" $2 "\t" $3 }
      next }
    { name = $1; p = $1; sub(/.*\./, "", p); sub(/\.[0-9]+$/, "", name)
      keep = (pids == "" || index(pids, " " p " ")); if (keep) print "P\t" p "\t" name "\t" $2 "\t" $3 }'
}
"""#

    /// The process trees below several terminals' shells on one host, in one run: what the host is
    /// asked for (all processes, sockets, counters) is read once and shared by every terminal, so ten
    /// tabs on a host cost one look, not ten. Arguments: pairs of `pid <shell pid>` or
    /// `screen <session name>`. Output: `@@now` (the host's clock, epoch seconds), then for each
    /// pair `@@@tab <index>` followed by its sections:
    ///
    ///     @@problem   no-shell (the shell is gone)
    ///     @@root      the pid the tree starts at (the shell, or the screen server)
    ///     @@linux     clock ticks per second, page size, boot time
    ///     @@procs     Linux: pid ppid pgrp tpgid state cpu-ticks threads start-ticks rss-pages
    ///                 others: pid ppid pgid tpgid stat uid user time rss-kB etime args
    ///     @@detail    Linux: pid<TAB>uid<TAB>read write bytes<TAB>command line
    ///     @@users     uid name
    ///     @@sockets   pid<TAB>a line of ss / netstat / lsof
    ///     @@flows     network use per process and connection (see `flowFunctions`)
    ///     @@icmp      pid<TAB>ICMP or RAW (Linux: ping and raw sockets, which ss does not list)
    public static let command = flowFunctions + "\n" + #"""
export LC_ALL=C
echo "@@now"; date +%s
LINUX=""; [ -r /proc/self/stat ] && LINUX=1
STAT=""; PSALL=""; SSP=""; SSI=""; ICMP=""; NT=""; GOT=""
# Shared reads, each done at most once per run and only when a terminal needs it.
need() {
  case " $GOT " in *" $1 "*) return ;; esac
  GOT="$GOT $1"
  case $1 in
    stat) STAT=$(cat /proc/[0-9]*/stat 2>/dev/null) ;;
    ps) PSALL=$(ps -A -o pid= -o ppid= -o pgid= -o tpgid= -o stat= -o uid= -o user= -o time= -o rss= -o etime= -o args= 2>/dev/null) ;;
    ssp) SSP=$({ ss -tunap 2>/dev/null || netstat -tunap 2>/dev/null; }) ;;
    ssi) SSI=$(ss -tinp 2>/dev/null) ;;
    icmp) ICMP=$(for f in icmp icmp6 raw raw6; do awk -v k="$f" 'NR > 1 && $10 ~ /^[1-9][0-9]*$/ { print k ":" $10 }' "/proc/net/$f" 2>/dev/null; done) ;;
    nettop) NT=$(nettop -L 1 -n -x -J bytes_in,bytes_out 2>/dev/null) ;;
  esac
}
# Breadth-first below the root, at most 400 processes; `line` and `kids` are filled by the caller.
TREE='END { if (!(root in line)) exit
  q[1] = root; h = 1; t = 1
  while (h <= t) { p = q[h++]; print line[p]; m = split(kids[p], k, " "); for (i = 1; i <= m && t < 400; i++) if (k[i] in line) q[++t] = k[i] } }'
probe() {
  R="$2"
  if [ "$1" = screen ]; then
    # The screen server's pid is the number before the session name in `screen -ls`.
    R=$(screen -ls 2>/dev/null | awk -v n="$2" '$1 ~ /^[0-9]+\./ { p = $1; sub(/\..*/, "", p); s = substr($1, length(p) + 2); if (s == n) { print p; exit } }')
  fi
  if [ -z "$R" ] || { [ ! -d "/proc/$R" ] && ! ps -p "$R" >/dev/null 2>&1; }; then echo "@@problem"; echo "no-shell"; return; fi
  echo "@@root"; echo "$R"
  if [ -n "$LINUX" ] && [ -d "/proc/$R" ]; then
    need stat
    echo "@@linux"
    getconf CLK_TCK 2>/dev/null || echo 100
    getconf PAGESIZE 2>/dev/null || getconf PAGE_SIZE 2>/dev/null || echo 4096
    awk '$1 == "btime" { print $2 }' /proc/stat 2>/dev/null
    # The program name in /proc/<pid>/stat may hold spaces and parentheses: fields after the last ") ".
    T=$(printf '%s\n' "$STAT" | awk -v root="$R" '
      { s = $0; sub(/.*\) /, "", s); n = split(s, f, " "); if (n < 22) next
        p = $1; line[p] = p " " f[2] " " f[3] " " f[6] " " f[1] " " (f[12] + f[13]) " " f[18] " " f[20] " " f[22]
        kids[f[2]] = kids[f[2]] " " p }
      '"$TREE")
    echo "@@procs"; printf '%s\n' "$T"
    P=$(printf '%s\n' "$T" | awk 'NR > 1 && NR <= 65 { print $1 }')
    # Owner and disk counters of all processes in one awk (unreadable files, e.g. other users'
    # io, are left out first: some awks stop at a file they cannot open).
    F=""; for p in $P; do for f in "/proc/$p/status" "/proc/$p/io"; do [ -r "$f" ] && F="$F $f"; done; done
    D=$([ -n "$F" ] && awk '{ split(FILENAME, a, "/"); p = a[3] }
      FILENAME ~ /status$/ && $1 == "Uid:" { u[p] = $2 } FILENAME ~ /io$/ && $1 == "read_bytes:" { r[p] = $2 }
      FILENAME ~ /io$/ && $1 == "write_bytes:" { w[p] = $2 }
      END { for (p in u) print p "\t" u[p] "\t" ((p in r) ? r[p] " " w[p] : "-") }' $F 2>/dev/null)
    echo "@@detail"; printf '%s\n' "$D"
    # Command lines: arguments are NUL-separated; line breaks inside them become spaces too.
    echo "@@cmdline"
    for p in $P; do printf '%s\t' "$p"; { tr '\000\n\r\t' '    ' < "/proc/$p/cmdline"; } 2>/dev/null; echo; done
    echo "@@users"
    for u in $(printf '%s\n' "$D" | awk -F '\t' '$2 ~ /^[0-9]+$/ { print $2 }' | sort -u); do
      getent passwd "$u" 2>/dev/null || awk -F: -v u="$u" '$3 == u' /etc/passwd 2>/dev/null
    done | awk -F: '{ print $3 " " $1 }'
    [ -n "$P" ] || return
    PIDS=" $(printf '%s ' $P)"
    need ssp; need ssi
    echo "@@sockets"
    printf '%s\n' "$SSP" | awk -v pids="$PIDS" '
      { for (i = 1; i <= NF; i++) {
          p = ""
          if (match($i, /pid=[0-9]+/)) p = substr($i, RSTART + 4, RLENGTH - 4)
          else if ($i ~ /^[0-9]+\//) { p = $i; sub(/\/.*/, "", p) }
          if (p != "" && index(pids, " " p " ")) { print p "\t" $0; break } } }'
    echo "@@flows"; printf '%s\n' "$SSI" | tcp_counters "$PIDS"
    # ICMP (ping) and raw sockets: ss does not list them; their inodes are in /proc/net, matched
    # against the processes' open files — only when the host has any such socket at all.
    need icmp
    if [ -n "$ICMP" ]; then
      echo "@@icmp"
      for p in $P; do
        ls -l "/proc/$p/fd" 2>/dev/null | awk -v p="$p" -v want=" $(echo $ICMP) " '$NF ~ /^socket:\[/ { i = $NF; gsub(/[^0-9]/, "", i)
          if (index(want, ":" i " ")) { k = substr(want, 1, index(want, ":" i " ") - 1); sub(/.* /, "", k); print p "\t" (k ~ /^icmp/ ? "ICMP" : "RAW") } }'
      done
    fi
  else
    need ps
    T=$(printf '%s\n' "$PSALL" | awk -v root="$R" '
      $1 ~ /^[0-9]+$/ { line[$1] = $0; kids[$2] = kids[$2] " " $1 }
      '"$TREE")
    echo "@@procs"; printf '%s\n' "$T"
    P=$(printf '%s\n' "$T" | awk 'NR > 1 && NR <= 65 { print $1 }')
    [ -n "$P" ] || return
    L=$(printf '%s,' $P); L=${L%,}
    echo "@@sockets"
    lsof -nP -a -i -p "$L" 2>/dev/null | awk 'NR > 1 { print $2 "\t" $0 }'
    if [ "$(uname -s)" = Darwin ]; then
      need nettop
      echo "@@flows"; printf '%s\n' "$NT" | nettop_flows " $(printf '%s ' $P)"
    fi
  fi
}
i=0
while [ $# -ge 2 ]; do
  echo "@@@tab $i"
  probe "$1" "$2"
  i=$((i + 1)); shift 2
done
true
"""#

    /// Traffic per process on the whole host, as a stream of `@@end`-separated records; `$1` =
    /// interval in seconds. The first record names the source (`@@source`): `nettop` (macOS,
    /// cumulative bytes), `nethogs` (rates in KB/s; only as root or with passwordless sudo for
    /// nethogs), `tcp` (the kernel's byte counters of TCP sockets, from `ss -ti`; no root needed for
    /// one's own processes) or `connections` (only socket counts per process, from netstat).
    /// `@@failed` ends a source that stopped (e.g. nethogs without permission), with its messages.
    public static let processTraffic = flowFunctions + "\n" + #"""
export LC_ALL=C
I="${1:-2}"
if [ "$(uname -s)" = Darwin ] && command -v nettop >/dev/null 2>&1; then
  printf '@@source\nnettop\n@@end\n'
  while :; do echo "@@flows"; nettop -L 1 -n -x -J bytes_in,bytes_out 2>/dev/null | nettop_flows ""; echo "@@end"; sleep "$I"; done
fi
# nethogs only where it may capture (root, or passwordless sudo for it): it also sees UDP and
# every user's processes. Otherwise the kernel's TCP counters do without capturing anything.
N=""
if command -v nethogs >/dev/null 2>&1; then
  if [ "$(id -u)" = 0 ]; then N="nethogs"
  elif command -v sudo >/dev/null 2>&1 && sudo -n nethogs -V >/dev/null 2>&1; then N="sudo -n nethogs"; fi
fi
if [ -n "$N" ]; then
  # nethogs buffers its output into a pipe: give it a terminal (script, kept open by tail), or
  # line buffering (stdbuf) when it runs without sudo.
  C="$N -t -d $I"
  if command -v script >/dev/null 2>&1 && script -q -c true /dev/null </dev/null >/dev/null 2>&1; then
    C="tail -f /dev/null | script -q -c \"$C\" /dev/null"
  elif [ "$N" = nethogs ] && command -v stdbuf >/dev/null 2>&1; then
    C="stdbuf -oL $C"
  fi
  CR=$(printf '\r')
  # Every process below this shell (Linux): to stop nethogs, script and tail once nobody reads.
  below() {
    cat /proc/[0-9]*/stat 2>/dev/null | awk -v r="$1" '{ s = $0; sub(/.*\) /, "", s); split(s, f, " "); par[$1] = f[2] }
      END { q[1] = r; h = 1; t = 1; while (h <= t) { p = q[h++]; for (c in par) if (par[c] == p) { q[++t] = c; print c } } }'
  }
  printf '@@source\nnethogs\n@@end\n@@nethogs\n'
  # Read line by line (some awks read pipes in blocks, which would hold records back). When the
  # viewer is gone, writing fails: the reader then ends everything this script started — script
  # ignores a broken pipe and would otherwise keep nethogs (as root) running on the server.
  # Closing script's terminal also ends a nethogs started through sudo.
  trap '' PIPE
  eval "$C" 2>&1 | while IFS= read -r l; do
    l=${l%"$CR"}
    case "$l" in Refreshing:*) o='@@end\n@@nethogs\n' ;; *) o='' ;; esac
    if [ -n "$o" ]; then printf "$o"; else printf '%s\n' "$l"; fi 2>/dev/null || {
      # This reader is one of them: it signals the others, not itself (it would stop halfway).
      read -r me _ < /proc/self/stat
      kill $(below $$ | grep -vx "$me") 2>/dev/null
      exit 3
    }
  done
  [ $? = 3 ] && exit 0
  trap - PIPE
  printf '@@failed\n@@end\n'
fi
if command -v ss >/dev/null 2>&1 && ss -tinp >/dev/null 2>&1; then
  printf '@@source\ntcp\n@@end\n'
  while :; do echo "@@flows"; ss -tinp 2>/dev/null | tcp_counters ""; echo "@@end"; sleep "$I"; done
fi
printf '@@source\nconnections\n@@end\n'
while :; do
  echo "@@sockets"
  netstat -tunap 2>/dev/null | tail -n +3
  echo "@@end"; sleep "$I"
done
"""#
}

extension ProbeScripts {
    /// Stops a running command: the signal goes to its process group (the terminal's foreground
    /// job) and to each of its processes, so programs it started do not live on in the background.
    /// `$1` = signal, `$2` = the shell's pid (never signalled, nor its group, group 1 or this
    /// script's own group), `$3` = the command's process group, then the command's pids. After a
    /// second, `alive <pid>` names each process still running (e.g. it ignored TERM).
    public static let stopCommand = #"""
export LC_ALL=C
sig="$1"; shell="$2"; grp="$3"; shift 3
# The process group of a pid: field 5 of /proc/<pid>/stat, or ps.
pg() {
  if { read -r l < "/proc/$1/stat"; } 2>/dev/null; then l=${l##*") "}; set -- $l; echo "$3"
  else ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; fi
}
own=$(pg $$); sg=$(pg "$shell")
# The group only when it is surely the command's own: known, not 1, not the shell's, not ours.
if [ -n "$grp" ] && [ -n "$own" ] && [ "$grp" -gt 1 ] 2>/dev/null && [ "$grp" != "$shell" ] && [ "$grp" != "$sg" ] && [ "$grp" != "$own" ]; then
  { kill -s "$sig" -- "-$grp" || kill -s "$sig" "-$grp"; } 2>/dev/null
fi
for p in "$@"; do [ "$p" != "$shell" ] && kill -s "$sig" "$p" 2>/dev/null; done
sleep 1
for p in "$@"; do
  if [ -d /proc/self ]; then
    [ -d "/proc/$p" ] && ! grep -q '^State:[[:space:]]*Z' "/proc/$p/status" 2>/dev/null && echo "alive $p"
  else
    ps -p "$p" -o stat= 2>/dev/null | grep -qv Z && echo "alive $p"
  fi
done
true
"""#

    /// The host name of address `$1`, as the host itself resolves it (its DNS, its /etc/hosts); an
    /// empty line when it has none.
    public static let reverseLookup = #"""
export LC_ALL=C
n=$(getent hosts "$1" 2>/dev/null | awk '{ print $2; exit }')
if [ -z "$n" ] && command -v host >/dev/null 2>&1; then n=$(host "$1" 2>/dev/null | awk '/pointer/ { sub(/\.$/, "", $NF); print $NF; exit }'); fi
if [ -z "$n" ] && [ "$(uname -s)" = Darwin ]; then n=$(dscacheutil -q host -a ip_address "$1" 2>/dev/null | awk '/^name:/ { print $2; exit }'); fi
printf '%s\n' "$n"
"""#
}

extension ProbeScripts {
    /// Watches the shells of all of a host's terminals in one process and says, the moment it
    /// changes, what runs in each one's foreground — so short commands are seen, and the full look
    /// (`command`) runs only while something runs. Arguments as for `command`. One line per change:
    ///
    ///     <tab> busy <pid> <command line>   a program took the foreground (its group leader)
    ///     <tab> idle                        the shell waits for input again
    ///     <tab> gone                        the shell is not running
    ///     .                                 every 10 s: a watcher whose viewer is gone then fails
    ///                                       to write and ends, instead of staying on the server
    ///
    /// `$1` of the arguments may be preceded by `-i <seconds>` (0.5, 1, 2…; whole seconds where
    /// `sleep` takes no fractions). Linux reads /proc with shell built-ins — no process is started
    /// per check; other systems run one `ps` per check for all terminals together.
    public static let commandWatch = #"""
export LC_ALL=C
D=0.5
if [ "$1" = -i ]; then D="$2"; shift 2; fi
sleep "$D" 2>/dev/null || D=$(printf '%s\n' "$D" | awk '{ v = int($1 + 0.999); print (v < 1 ? 1 : v) }')
B=$(printf '%s\n' "$D" | awk '{ v = int(10 / $1); print (v < 1 ? 1 : v) }')
LINUX=""; [ -r /proc/self/stat ] && LINUX=1
SH=""
while [ $# -ge 2 ]; do
  s="$2"
  if [ "$1" = screen ]; then
    R=$(screen -ls 2>/dev/null | awk -v n="$2" '$1 ~ /^[0-9]+\./ { p = $1; sub(/\..*/, "", p); x = substr($1, length(p) + 2); if (x == n) { print p; exit } }')
    s=$(ps -A -o pid= -o ppid= 2>/dev/null | awk -v r="$R" '$2 == r { n++; s = $1 } END { if (n == 1) print s }')
  fi
  SH="$SH ${s:--}"; shift 2
done
# One line, whatever the arguments hold (a line break could otherwise pass for an event).
args() {
  if [ -r "/proc/$1/cmdline" ]; then a=$({ tr '\000\n\r\t' '    ' < "/proc/$1/cmdline"; } 2>/dev/null)
  else a=$(ps -o args= -p "$1" 2>/dev/null | tr '\n\r\t' '   '); fi
  while [ "${a% }" != "$a" ]; do a=${a% }; done
  printf '%s' "$a"
}
LIST=$(printf '%s\n' $SH | grep -v '^-$' | tr '\n' ',' | sed 's/,$//')
n=0
while :; do
  [ -z "$LINUX" ] && STATE=$(ps -o pid= -o pgid= -o tpgid= -p "${LIST:-1}" 2>/dev/null | awk '{ print $1 "=" (($3 == $2 || $3 <= 0) ? "idle" : $3) }')
  i=0
  for s in $SH; do
    cur=gone
    if [ "$s" != - ]; then
      if [ -n "$LINUX" ]; then
        if { read -r l < "/proc/$s/stat"; } 2>/dev/null; then
          l=${l##*") "}; set -- $l
          if [ "$6" = "$3" ] || [ "$6" -le 0 ] 2>/dev/null; then cur=idle; else cur="busy $6"; fi
        fi
      else
        for kv in $STATE; do case $kv in "$s="*) v=${kv#*=}; [ "$v" = idle ] && cur=idle || cur="busy $v" ;; esac; done
      fi
    fi
    eval "prev=\${L$i-}"
    if [ "$cur" != "$prev" ]; then
      case $cur in busy*) echo "$i $cur $(args "${cur#busy }" | head -c 1000)" ;; *) echo "$i $cur" ;; esac
      eval "L$i=\$cur"; n=0
    fi
    i=$((i + 1))
  done
  n=$((n + 1)); if [ "$n" -ge "$B" ]; then echo .; n=0; fi
  sleep "$D"
done
"""#
}

extension WindowsProbeScripts {
    /// `ProbeScripts.commandWatch` for Windows: `$A` holds the tags of the terminals' PowerShells
    /// (see `ShellAnchor.windows`). One process query per second for all of them; the newest program
    /// a shell started (console hosts aside) is its foreground.
    public static let commandWatch = #"""
$self = $PID
$skip = @('conhost.exe', 'OpenConsole.exe')
# Ends when nobody reads (a failed write) or when the ssh session that started it is gone.
function Say($text) { try { [Console]::Out.WriteLine($text); [Console]::Out.Flush() } catch { exit } }
$all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
$parent = [int](($all | Where-Object { $_.ProcessId -eq $self } | Select-Object -First 1).ParentProcessId)
$roots = @(foreach ($tag in $A) {
  $r = $all | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($tag) -and $_.ProcessId -ne $self } |
    Sort-Object CreationDate -Descending | Select-Object -First 1
  if ($r) { [int]$r.ProcessId } else { 0 }
})
$last = @{}; $n = 0
while ($true) {
  $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine, CreationDate -ErrorAction SilentlyContinue)
  $alive = @{}; foreach ($p in $all) { $alive[[int]$p.ProcessId] = $true }
  if ($parent -gt 0 -and -not $alive.ContainsKey($parent)) { exit }
  for ($i = 0; $i -lt $roots.Count; $i++) {
    $id = $roots[$i]
    if ($id -eq 0 -or -not $alive.ContainsKey($id)) { $cur = 'gone'; $line = "$i gone" }
    else {
      $kid = $all | Where-Object { [int]$_.ParentProcessId -eq $id -and $skip -notcontains $_.Name } | Sort-Object CreationDate -Descending | Select-Object -First 1
      if ($kid) {
        $cur = "busy $($kid.ProcessId)"
        $c = $kid.CommandLine; if (-not $c) { $c = $kid.Name }
        $c = $c -replace '[\r\n\t]', ' '; if ($c.Length -gt 1000) { $c = $c.Substring(0, 1000) }
        $line = "$i $cur $c"
      } else { $cur = 'idle'; $line = "$i idle" }
    }
    if ($last[$i] -ne $cur) { Say $line; $last[$i] = $cur; $n = 0 }
  }
  $n++; if ($n -ge 10) { Say '.'; $n = 0 }
  Start-Sleep -Seconds 1
}
"""#

    /// Connections per process on a Windows host (no byte counts without administrator tools), in
    /// the format of `ProbeScripts.processTraffic`'s `connections` source (netstat-like lines).
    public static let processTraffic = #"""
# Ends when nobody reads (a failed write) or when the ssh session that started it is gone.
function Say($text) { try { [Console]::Out.Write($text); [Console]::Out.Flush() } catch { exit } }
$parent = [int](Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue).ParentProcessId
Say "@@source`nconnections`n@@end`n"
while ($true) {
  if ($parent -gt 0 -and -not (Get-Process -Id $parent -ErrorAction SilentlyContinue)) { exit }
  $names = @{}; Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $names[$_.Id] = $_.ProcessName }
  $out = New-Object System.Text.StringBuilder
  [void]$out.AppendLine('@@sockets')
  Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | ForEach-Object {
    [void]$out.AppendLine("tcp 0 0 $($_.LocalAddress):$($_.LocalPort) $($_.RemoteAddress):$($_.RemotePort) ESTABLISHED $($_.OwningProcess)/$($names[[int]$_.OwningProcess])")
  }
  [void]$out.AppendLine('@@end')
  Say $out.ToString()
  Start-Sleep -Seconds ([int]$A[0])
}
"""#

    /// `ProbeScripts.stopCommand` for Windows: `$A` = TERM or KILL, the shell, (unused), then pids.
    /// taskkill /T ends each process with everything it started (/F for KILL).
    public static let stopCommand = #"""
$force = $A[0] -eq 'KILL'
$ids = @($A | Select-Object -Skip 3 | ForEach-Object { [int]$_ }) | Where-Object { $_ -ne [int]$A[1] }
foreach ($id in $ids) {
  if ($force) { taskkill /PID $id /T /F 2>&1 | Out-Null } else { taskkill /PID $id /T 2>&1 | Out-Null }
}
Start-Sleep -Seconds 1
foreach ($id in $ids) { if (Get-Process -Id $id -ErrorAction SilentlyContinue) { "alive $id" } }
"""#

    /// The host name of address `$A[0]`, or nothing.
    public static let reverseLookup = #"""
try { [Net.Dns]::GetHostEntry($A[0]).HostName } catch { '' }
"""#

    /// The processes below the PowerShells whose command lines contain the tags in `$A` (see
    /// `ShellAnchor.windows`), one `@@@tab <index>` per tag, after a shared `@@now` — the process
    /// and connection lists are read once for all of them:
    ///
    ///     @@windows   pid ppid cpu-seconds working-set threads start(epoch) read write user command (tabs)
    ///     @@tcp       proto state local peer pid (tabs)
    public static let command = #"""
$inv = [Globalization.CultureInfo]::InvariantCulture
$self = $PID
'@@now'; [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
$kids = @{}
foreach ($p in $all) { $pp = [int]$p.ParentProcessId; if (-not $kids.ContainsKey($pp)) { $kids[$pp] = New-Object System.Collections.ArrayList }; [void]$kids[$pp].Add($p) }
$tcp = $null; $udp = $null
for ($t = 0; $t -lt $A.Count; $t++) {
  "@@@tab $t"
  # The default shell that started it (cmd /c … or powershell -c …) carries the tag too and is
  # older: the newest match is the interactive PowerShell itself.
  $root = $all | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($A[$t]) -and $_.ProcessId -ne $self } |
    Sort-Object CreationDate -Descending | Select-Object -First 1
  if (-not $root) { '@@problem'; 'no-shell'; continue }
  '@@root'; $root.ProcessId
  $tree = New-Object System.Collections.ArrayList
  $queue = New-Object System.Collections.Queue
  $queue.Enqueue([int]$root.ProcessId)
  while ($queue.Count -gt 0 -and $tree.Count -lt 400) {
    $id = $queue.Dequeue()
    if ($kids.ContainsKey($id)) { foreach ($c in $kids[$id]) { if ([int]$c.ProcessId -ne $id -and $tree.Count -lt 400) { [void]$tree.Add($c); $queue.Enqueue([int]$c.ProcessId) } } }
  }
  '@@windows'
  $n = 0
  foreach ($p in $tree) {
    $cpu = ([double]$p.KernelModeTime + [double]$p.UserModeTime) / 10000000
    $start = '-'; if ($p.CreationDate) { $start = ([DateTimeOffset]$p.CreationDate).ToUnixTimeSeconds() }
    $user = '-'
    # The owner costs a call per process: asked for the first few (the command and its children).
    if ($n -lt 8) { try { $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop; if ($o.User) { $user = $o.User } } catch {} }
    $n++
    $cmd = $p.CommandLine; if (-not $cmd) { $cmd = $p.Name }
    $cmd = $cmd -replace '[\t\r\n]', ' '
    "$($p.ProcessId)`t$($p.ParentProcessId)`t$($cpu.ToString($inv))`t$($p.WorkingSetSize)`t$($p.ThreadCount)`t$start`t$($p.ReadTransferCount)`t$($p.WriteTransferCount)`t$user`t$cmd"
  }
  '@@tcp'
  $ids = @($tree | ForEach-Object { [int]$_.ProcessId })
  if ($ids.Count -gt 0) {
    if ($null -eq $tcp) { $tcp = @(Get-NetTCPConnection -ErrorAction SilentlyContinue); $udp = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue) }
    $tcp | Where-Object { $ids -contains $_.OwningProcess } | ForEach-Object {
      "TCP`t$($_.State)`t$($_.LocalAddress):$($_.LocalPort)`t$($_.RemoteAddress):$($_.RemotePort)`t$($_.OwningProcess)"
    }
    $udp | Where-Object { $ids -contains $_.OwningProcess } | ForEach-Object {
      "UDP`t-`t$($_.LocalAddress):$($_.LocalPort)`t*:*`t$($_.OwningProcess)"
    }
  }
}
"""#
}
