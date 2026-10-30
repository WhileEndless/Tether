import Foundation

/// Remote shell scripts. All are POSIX sh, use only tools present on stock systems,
/// and print `@@section` markers that the parsers rely on.
public enum ProbeScripts {
    /// One snapshot of the system. `$1 = 1` adds slow-changing details (OS, CPU model, sshd ports,
    /// GPU presence) and takes two CPU samples so utilisation is known immediately.
    static let systemFrame = #"""
OS=$(uname -s)
if [ "$1" = 1 ]; then
  echo "@@uname"; uname -n; uname -r; uname -m
  echo "@@os"
  if [ -r /etc/os-release ]; then . /etc/os-release; echo "${PRETTY_NAME:-$NAME}"
  elif [ "$OS" = Darwin ]; then echo "macOS $(sw_vers -productVersion 2>/dev/null)"
  else uname -sr; fi
  echo "@@osinfo"
  if [ -r /etc/os-release ]; then . /etc/os-release; echo "id=$ID"; echo "version=$VERSION_ID"; echo "codename=${VERSION_CODENAME:-}"; fi
  [ "$OS" = Darwin ] && { echo "id=macos"; echo "version=$(sw_vers -productVersion 2>/dev/null)"; echo "build=$(sw_vers -buildVersion 2>/dev/null)"; }
  echo "kernelbuild=$(uname -v 2>/dev/null)"
  v=$(systemd-detect-virt 2>/dev/null); [ -n "$v" ] && echo "virt=$v"
  if [ -r /sys/class/dmi/id/product_name ]; then echo "hardware=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
  elif [ -r /proc/device-tree/model ]; then echo "hardware=$(tr -d '\0' < /proc/device-tree/model)"
  elif [ "$OS" = Darwin ]; then echo "hardware=$(sysctl -n hw.model 2>/dev/null)"; fi
  if [ -r /proc/cpuinfo ]; then echo "sockets=$(grep 'physical id' /proc/cpuinfo | sort -u | wc -l)"; fi
  echo "shell=${SHELL:-}"
  echo "@@cpumodel"
  if [ -r /proc/cpuinfo ]; then grep -m1 -E '^(model name|Model|Hardware)' /proc/cpuinfo | cut -d: -f2-
    command -v lscpu >/dev/null 2>&1 && lscpu 2>/dev/null | grep -m1 'Model name' | cut -d: -f2-
  else sysctl -n machdep.cpu.brand_string 2>/dev/null; fi
  echo "@@ips"; (hostname -I 2>/dev/null || ifconfig 2>/dev/null | awk '/inet /{print $2}') | tr ' ' '\n' | grep -v '^127\.' | grep -v '^$'
  echo "@@sshports"
  if command -v ss >/dev/null 2>&1; then ss -tlnpH 2>/dev/null | grep -E '"sshd' | awk '{print $4}'; fi
  grep -iE '^[[:space:]]*Port[[:space:]]' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print "cfg:" $NF}'
  echo "@@tools"
  for t in docker podman kubectl k3s microk8s oc; do command -v "$t" >/dev/null 2>&1 && echo "$t"; done
fi
echo "@@conn"; echo "$SSH_CONNECTION"
if [ "$OS" = Linux ]; then
  echo "@@uptime"; cut -d' ' -f1 /proc/uptime
  echo "@@load"; cut -d' ' -f1-3 /proc/loadavg
  [ -n "$NCPU" ] || NCPU=$(getconf _NPROCESSORS_ONLN 2>/dev/null || grep -c ^processor /proc/cpuinfo)
  echo "@@ncpu"; echo "$NCPU"
  echo "@@cpu"; head -n1 /proc/stat
  if [ "$1" = 1 ]; then sleep 0.4 2>/dev/null || sleep 1; head -n1 /proc/stat; fi
  echo "@@meminfo"; grep -E '^(MemTotal|MemAvailable|MemFree|Buffers|Cached|SReclaimable|SwapTotal|SwapFree):' /proc/meminfo
elif [ "$OS" = Darwin ]; then
  echo "@@uptime"; b=$(sysctl -n kern.boottime | sed 's/^{ sec = \([0-9]*\).*/\1/'); echo $(( $(date +%s) - b ))
  echo "@@load"; sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1, $2, $3}'
  [ -n "$NCPU" ] || NCPU=$(sysctl -n hw.ncpu)
  echo "@@ncpu"; echo "$NCPU"
  echo "@@cpupct"; top -l 2 -n 0 -s 1 2>/dev/null | grep 'CPU usage' | tail -n1
  echo "@@darwinmem"; sysctl -n hw.memsize; vm_stat; echo "swap $(sysctl -n vm.swapusage)"
fi
# Disks change slowly, and df can be slow (network mounts): every half minute in a stream.
if [ "${DISKNOW:-1}" = 1 ]; then echo "@@disk"; df -kP 2>/dev/null | tail -n +2; fi
echo "@@netdev"
if [ -r /proc/net/dev ]; then
  tail -n +3 /proc/net/dev | tr ':' ' ' | awk '{print $1, $2, $10}'
else
  netstat -ibn 2>/dev/null | awk 'NR>1 && $3 ~ /Link/ {print $1, $7, $10}'
fi
if [ "$1" = 1 ]; then
  echo "@@netinfo"
  for d in /sys/class/net/*; do
    [ -e "$d" ] || continue
    n=${d##*/}; p=0; [ -e "$d/device" ] && p=1
    echo "$n|$(cat "$d/operstate" 2>/dev/null)|$(cat "$d/address" 2>/dev/null)|$(cat "$d/speed" 2>/dev/null)|$p"
  done
  echo "@@netaddr"
  if command -v ip >/dev/null 2>&1; then ip -o addr show 2>/dev/null | awk '{print $2, $4}'
  else ifconfig 2>/dev/null | awk '/^[a-z]/{i=$1; sub(":","",i)} /inet6? /{print i, $2}'; fi
fi
# GPU tools start their driver library on every call: every ten seconds or so in a stream.
if [ "${GPUNOW:-1}" = 1 ] && [ -n "$HAS_NVIDIA" ]; then
  echo "@@nvidia"
  nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit,uuid --format=csv,noheader,nounits 2>/dev/null
fi
if [ "${GPUNOW:-1}" != 1 ]; then :
elif [ -n "$HAS_ROCM" ]; then
  echo "@@rocm"; rocm-smi --showproductname --showuse --showmeminfo vram --showtemp --showpower --json 2>/dev/null
elif [ -n "$HAS_AMDSYSFS" ]; then
  echo "@@amdsysfs"
  i=0
  for d in /sys/class/drm/card*/device; do
    [ -r "$d/gpu_busy_percent" ] || continue
    t=$(cat "$d"/hwmon/hwmon*/temp1_input 2>/dev/null | head -n1)
    p=$(cat "$d"/hwmon/hwmon*/power1_average 2>/dev/null | head -n1)
    echo "$i|$(cat "$d/gpu_busy_percent")|$(cat "$d/mem_info_vram_used" 2>/dev/null)|$(cat "$d/mem_info_vram_total" 2>/dev/null)|$t|$p"
    i=$((i+1))
  done
fi
echo "@@end"
"""#

    /// Streams `systemFrame` every `$1` seconds until the connection is closed. GPU tools are
    /// detected once. Each frame ends with `@@end`.
    public static let systemStream = #"""
export LC_ALL=C
command -v nvidia-smi >/dev/null 2>&1 && HAS_NVIDIA=1
command -v rocm-smi >/dev/null 2>&1 && HAS_ROCM=1
ls /sys/class/drm/card*/device/gpu_busy_percent >/dev/null 2>&1 && HAS_AMDSYSFS=1
export HAS_NVIDIA HAS_ROCM HAS_AMDSYSFS
frame() {
"""# + "\n" + systemFrame + "\n" + #"""
}
interval="${1:-3}"
case $interval in ''|*[!0-9]*) interval=3 ;; esac
[ "$interval" -ge 1 ] || interval=1
# Slow sections (disks, GPUs) only every few frames; the parser keeps their last values.
kd=$(( (30 + interval - 1) / interval )); kg=$(( (10 + interval - 1) / interval ))
n=0
frame 1
while sleep "$interval"; do
  n=$((n + 1))
  DISKNOW=0; [ $((n % kd)) -eq 0 ] && DISKNOW=1
  GPUNOW=0; [ $((n % kg)) -eq 0 ] && GPUNOW=1
  frame 0 || exit 0
done
"""#

    /// Single snapshot (used when streaming is not possible).
    public static let system = #"""
export LC_ALL=C
command -v nvidia-smi >/dev/null 2>&1 && HAS_NVIDIA=1
command -v rocm-smi >/dev/null 2>&1 && HAS_ROCM=1
ls /sys/class/drm/card*/device/gpu_busy_percent >/dev/null 2>&1 && HAS_AMDSYSFS=1
"""# + "\n" + systemFrame

    /// Listening sockets: `proto<TAB>addr:port<TAB>process<TAB>pid`. Process names need permission
    /// (other users' processes show up without a name unless run as root).
    public static let listening = #"""
export LC_ALL=C
if command -v ss >/dev/null 2>&1; then
  ss -tulnpH 2>/dev/null | awk '{proto=$1; if (proto!="tcp" && proto!="udp") next; p=""; pid="";
    if (match($0, /users:\(\("[^"]+",pid=[0-9]+/)) { s=substr($0, RSTART+9, RLENGTH-9); split(s, a, "\",pid="); p=a[1]; pid=a[2] }
    print proto "\t" $5 "\t" p "\t" pid}'
elif command -v lsof >/dev/null 2>&1; then
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print "tcp\t" $9 "\t" $1 "\t" $2}'
  lsof -nP -iUDP 2>/dev/null | awk 'NR>1 && $9 !~ /->/ {print "udp\t" $9 "\t" $1 "\t" $2}'
else
  netstat -an -p tcp 2>/dev/null | awk '/LISTEN/ {print "tcp\t" $4 "\t\t"}'
fi
"""#

    public static let gpuProcesses = #"""
export LC_ALL=C
command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null
command -v rocm-smi >/dev/null 2>&1 && rocm-smi --showpids 2>/dev/null | grep -E '^[0-9]+' | awk '{print "amd," $1 "," $2 "," $4}'
true
"""#

    /// systemd services (or launchd jobs on macOS).
    public static let services = #"""
export LC_ALL=C
if command -v systemctl >/dev/null 2>&1; then
  echo "@@systemd"; systemctl list-units --type=service --all --no-pager --plain --no-legend 2>/dev/null
elif [ "$(uname -s)" = Darwin ]; then
  echo "@@launchd"; launchctl list 2>/dev/null | tail -n +2
else
  echo "@@sysv"; service --status-all 2>&1
fi
"""#

    /// `$1` = start|stop|restart, `$2` = unit. Tries without sudo, then passwordless sudo.
    public static let serviceAction = #"""
systemctl "$1" "$2" 2>/dev/null || sudo -n systemctl "$1" "$2"
"""#

    public static let containers = #"""
export LC_ALL=C
F='{{.ID}}\t{{.Image}}\t{{.Names}}\t{{.Status}}\t{{.State}}\t{{.Ports}}'
for e in docker podman; do
  command -v $e >/dev/null 2>&1 || continue
  out=$($e ps -a --format "$F" 2>/dev/null || sudo -n $e ps -a --format "$F" 2>/dev/null) || continue
  echo "@@$e"; printf '%s\n' "$out"
done
true
"""#

    /// `$1` = engine, `$2` = start|stop|restart|logs, `$3` = container id.
    public static let containerAction = #"""
if [ "$2" = logs ]; then set -- "$1" logs "$3" --tail 300; else set -- "$1" "$2" "$3"; fi
"$@" 2>&1 || sudo -n "$@" 2>&1
"""#

    public static let processes = #"""
export LC_ALL=C
ps -eo pid=,user=,pcpu=,pmem=,rss=,etime=,args= 2>/dev/null || ps -eo pid,user,pcpu,pmem,rss,etime,args | tail -n +2
"""#

    /// `$1` = signal name, `$2` = pid.
    public static let kill = #"""
kill -s "$1" "$2"
"""#

    /// `$1` = lines, `$2` = all|warnings|errors, `$3` = the file (for a file). A level other than
    /// all asks journalctl for that priority, `log show` for errors and faults, `dmesg` for its
    /// levels, and looks for the usual words in plain files (in their last 200,000 lines).
    public static func logs(_ source: LogSource, lines: Int, level: LogLevel = .all) -> (script: String, arguments: [String]) {
        let n = String(max(lines, 10))
        let common = #"""
export LC_ALL=C
N=$1 L=$2
P=; case $L in errors) P='-p err' ;; warnings) P='-p warning' ;; esac
W='emerg|alert|crit|err|fail|fatal|panic|denied|refused|segfault|oom|killed process'
[ "$L" = warnings ] && W="$W|warn"
pick() { if [ "$L" = all ]; then tail -n "$N"; else tail -n 200000 | grep -iE "$W" | tail -n "$N"; fi; }
journal() { command -v journalctl >/dev/null 2>&1 && journalctl -n 1 --no-pager "$@" >/dev/null 2>&1; }
MACERR='messageType == error OR messageType == fault'
"""#
        switch source {
        case .system:
            return (common + "\n" + #"""
if [ "$(uname -s)" = Darwin ]; then
  if [ "$L" = all ]; then log show --last 10m --style syslog 2>/dev/null | tail -n "$N"
  else log show --last 1h --style syslog --predicate "$MACERR" 2>/dev/null | tail -n "$N"; fi
  exit; fi
# shellcheck disable=SC2086
if journal; then journalctl -n "$N" --no-pager -o short-iso $P 2>&1; exit; fi
for f in /var/log/syslog /var/log/messages; do if [ -r "$f" ]; then pick < "$f"; exit; fi; done
echo "No readable system log (journalctl, /var/log/syslog, /var/log/messages)." >&2; exit 1
"""#, [n, level.rawValue])
        case .auth:
            return (common + "\n" + #"""
# sshd-session: OpenSSH 9.8 and later.
# shellcheck disable=SC2086
if journal; then journalctl -n "$N" --no-pager -o short-iso _COMM=sshd _COMM=sshd-session $P 2>&1; exit; fi
for f in /var/log/auth.log /var/log/secure; do if [ -r "$f" ]; then pick < "$f"; exit; fi; done
if [ "$(uname -s)" = Darwin ]; then
  Q='process == "sshd" OR process == "sshd-session"'
  [ "$L" = all ] || Q="($Q) AND ($MACERR)"
  log show --last 1h --style syslog --predicate "$Q" 2>/dev/null | tail -n "$N"; exit; fi
echo "No readable authentication log (may require root)." >&2; exit 1
"""#, [n, level.rawValue])
        case .kernel:
            return (common + "\n" + #"""
# shellcheck disable=SC2086
if journal -k; then journalctl -k -n "$N" --no-pager -o short-iso $P 2>&1; exit; fi
case $L in errors) D=emerg,alert,crit,err ;; warnings) D=emerg,alert,crit,err,warn ;; *) D= ;; esac
if [ -n "$D" ] && dmesg --level="$D" >/dev/null 2>&1; then dmesg --level="$D" | tail -n "$N"; exit; fi
if dmesg >/dev/null 2>&1; then dmesg | pick; exit; fi
echo "Kernel log is not readable (may require root)." >&2; exit 1
"""#, [n, level.rawValue])
        case .file(let path):
            return (common + "\n" + #"""
if [ -r "$3" ]; then pick < "$3"; else echo "Cannot read $3" >&2; exit 1; fi
"""#, [n, level.rawValue, path])
        }
    }

    public static let connections = #"""
export LC_ALL=C
echo "@@sshports"
command -v ss >/dev/null 2>&1 && ss -tlnpH 2>/dev/null | grep -E '"sshd' | awk '{print $4}'
grep -iE '^[[:space:]]*Port[[:space:]]' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print "cfg:" $NF}'
echo "@@conn"; echo "$SSH_CONNECTION"
echo "@@who"; who 2>/dev/null
if command -v ss >/dev/null 2>&1; then echo "@@ss"; ss -tnpH state established 2>/dev/null || ss -tnH state established
else echo "@@netstat"; netstat -an -p tcp 2>/dev/null | grep -i established || netstat -tn 2>/dev/null | grep -i established; fi
echo "@@end"
"""#

    public static let remoteSessions = #"""
export LC_ALL=C
echo "@@tmux"; tmux ls -F '#{session_name}|#{session_created}|#{session_attached}|#{session_windows}|#{session_activity}' 2>/dev/null
panes=$(tmux list-panes -a -F '#{session_name}|#{window_index}|#{window_name}|#{window_active}|#{pane_active}|#{pane_id}|#{pane_tty}|#{pane_current_command}|#{pane_current_path}' 2>/dev/null)
echo "@@tmuxpanes"; printf '%s\n' "$panes"
echo "@@tmuxtitles"; [ -n "$panes" ] && tmux list-panes -a -F '#{pane_id}|#{host}|#{pane_title}' 2>/dev/null
# Foreground processes of tmux panes only (not every process on the host).
fg=
if [ -n "$panes" ]; then
  TTYS=$(printf '%s\n' "$panes" | awk -F'|' '{ t = $7; sub(/^\/dev\//, "", t); sub(/^tty/, "", t); print t }')
  # Only the panes' terminals are asked for (not every process on the host); ps without -t: all.
  TL=$(printf '%s\n' "$TTYS" | awk 'NF { printf "%s%s", s, $0; s = "," }')
  fg=$( { ps -t "$TL" -o pid=,tty=,stat=,args= 2>/dev/null || ps -A -o pid=,tty=,stat=,args= 2>/dev/null; } | TTYS="$TTYS" awk '
    BEGIN { n = split(ENVIRON["TTYS"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1 }
    $3 ~ /\+/ { t = $2; sub(/^tty/, "", t); if (t in want) print }')
fi
echo "@@fg"; [ -n "$fg" ] && printf '%s\n' "$fg"
# Coding agents (Claude Code, Codex, opencode) in the foreground: the name of their session.
# Only names and states are printed; nothing is read beyond the agent's own session index.
echo "@@agents"
set -f
sq() { printf '%s' "$1" | sed "s/'/''/g"; }
pcwd() { readlink "/proc/$1/cwd" 2>/dev/null || lsof -n -P -w -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'; }
[ -n "$fg" ] && printf '%s\n' "$fg" | while read -r pid tty stat args; do
  [ -n "$args" ] || continue
  set -- $args
  prog=${1##*/}
  case "$prog" in node|bun|sh|bash|python|python3) prog=${2:-}; prog=${prog##*/}; full=${2:-} ;; *) full=$1 ;; esac
  case "$prog|$full" in
    claude*|*/claude-code/*) kind=claude ;;
    codex*|*/codex/*) kind=codex ;;
    opencode*|.opencode*|*/opencode*) kind=opencode ;;
    *) continue ;;
  esac
  case $kind in
  claude)
    f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/$pid.json"
    [ -r "$f" ] && awk '{ for (i = 1; i <= 5; i++) { k = (i == 1 ? "name" : i == 2 ? "nameSource" : i == 3 ? "status" : i == 4 ? "tmux" : "waitingFor")
        if (match($0, "\"" k "\":\"([^\"\\\\]|\\\\.)*\"")) o = o (o == "" ? "" : ",") substr($0, RSTART, RLENGTH) }
        if (match($0, "\"statusUpdatedAt\":[0-9.]+")) o = o (o == "" ? "" : ",") substr($0, RSTART, RLENGTH) }
        END { print "'"$pid"'|claude|json|{" o "}" }' "$f"
    echo "$pid|claude|found|" ;;
  codex)
    d="${CODEX_HOME:-$HOME/.codex}"
    id=$(printf '%s\n' "$args" | sed -n 's/.*resume \([0-9a-f-]\{36\}\).*/\1/p')
    [ -n "$id" ] || id=$( { ls -l "/proc/$pid/fd" 2>/dev/null || lsof -n -P -w -p "$pid" -Fn 2>/dev/null; } |
      sed -n 's/.*rollout-.*\([0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}\)\.jsonl.*/\1/p' | head -n 1)
    [ -n "$id" ] && grep -h "\"$id\"" "$d/session_index.jsonl" 2>/dev/null | tail -n 1 | sed "s/^/$pid|codex|index|/"
    db=$(ls -t "$d" 2>/dev/null | grep '^state_[0-9]*\.sqlite$' | head -n 1)
    if [ -n "$db" ] && command -v sqlite3 >/dev/null 2>&1; then
      db="$d/$db"
      if [ -n "$id" ]; then w="id = '$(sq "$id")'"; else w="cwd = '$(sq "$(pcwd "$pid")")' AND archived = 0 ORDER BY updated_at DESC LIMIT 1"; fi
      sqlite3 -readonly "$db" "SELECT replace(coalesce(nullif(name, ''), title), char(10), ' ') FROM threads WHERE $w" 2>/dev/null |
        head -n 1 | sed "s/^/$pid|codex|title|/"
    fi
    echo "$pid|codex|found|" ;;
  opencode)
    db="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db"
    id=$(printf '%s\n' "$args" | awk '{ for (i = 1; i <= NF; i++) { if (($i == "-s" || $i == "--session") && i < NF) print $(i + 1); else if ($i ~ /^--session=/) print substr($i, 11) } }' | head -n 1)
    if [ -r "$db" ] && command -v sqlite3 >/dev/null 2>&1; then
      if [ -n "$id" ]; then w="id = '$(sq "$id")'"; else w="directory = '$(sq "$(pcwd "$pid")")' AND parent_id IS NULL AND time_archived IS NULL ORDER BY time_updated DESC LIMIT 1"; fi
      sqlite3 -readonly "$db" "SELECT replace(title, char(10), ' ') FROM session WHERE $w" 2>/dev/null |
        head -n 1 | sed "s/^/$pid|opencode|title|/"
    fi
    echo "$pid|opencode|found|" ;;
  esac
done
set +f
echo "@@screen"; screen -ls 2>/dev/null
echo "@@end"
"""#
}
