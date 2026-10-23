import Foundation

/// PowerShell versions of the probes for Windows hosts (Windows 10 / Server 2016 and later with
/// OpenSSH). They print the same `@@section` format as `ProbeScripts`, so the same parsers read
/// them. Arguments arrive as `$A` (see `PowerShell.prepare`).
public enum WindowsProbeScripts {
    /// Frames separated by `@@end`; `$A[0]` = interval in seconds. Static details only in the first frame.
    public static let systemStream = frameFunction + #"""
Frame $true; '@@end'
while ($true) { Start-Sleep -Seconds ([int]$A[0]); Frame $false; '@@end' }
"""#

    public static let system = frameFunction + "\nFrame $true\n"

    static let frameFunction = #"""
function Net($s) { ($s -replace '\s+', '_') }
function Frame($first) {
  $os = Get-CimInstance Win32_OperatingSystem
  if ($first) {
    '@@uname'; $env:COMPUTERNAME; $os.Version; $env:PROCESSOR_ARCHITECTURE
    '@@os'; $os.Caption
    '@@osinfo'
    'id=windows'; "version=$($os.Version)"; "build=$($os.BuildNumber)"
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    if ($cv.DisplayVersion) { "codename=$($cv.DisplayVersion)" }
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs) { "hardware=$($cs.Manufacturer) $($cs.Model)"; "sockets=$($cs.NumberOfProcessors)" }
    "shell=PowerShell $($PSVersionTable.PSVersion)"
    '@@cpumodel'; (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
    '@@ips'
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
      Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object { $_.IPAddress }
    '@@sshports'
    $sshd = Get-Process sshd -ErrorAction SilentlyContinue
    if ($sshd) {
      Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $sshd.Id -contains $_.OwningProcess } | ForEach-Object { "cfg:$($_.LocalPort)" } | Sort-Object -Unique
    }
  }
  '@@conn'; $env:SSH_CONNECTION
  '@@uptime'; [int64]((Get-Date) - $os.LastBootUpTime).TotalSeconds
  '@@ncpu'; [Environment]::ProcessorCount
  $load = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
  if ($load -ne $null) { '@@cpupct'; "CPU usage: $load% user, 0% sys, $(100 - $load)% idle" }
  '@@meminfo'
  "MemTotal: $($os.TotalVisibleMemorySize) kB"; "MemAvailable: $($os.FreePhysicalMemory) kB"
  "SwapTotal: $($os.SizeStoredInPagingFiles) kB"; "SwapFree: $($os.FreeSpaceInPagingFiles) kB"
  '@@disk'
  Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | Where-Object { $_.Size -gt 0 } | ForEach-Object {
    $used = $_.Size - $_.FreeSpace
    "$($_.DeviceID) $([int64]($_.Size / 1024)) $([int64]($used / 1024)) $([int64]($_.FreeSpace / 1024)) $([int](100 * $used / $_.Size))% $($_.DeviceID)/"
  }
  '@@netdev'
  Get-NetAdapterStatistics -ErrorAction SilentlyContinue | ForEach-Object { "$(Net $_.Name) $($_.ReceivedBytes) $($_.SentBytes)" }
  if ($first) {
    '@@netinfo'
    Get-NetAdapter -ErrorAction SilentlyContinue | ForEach-Object {
      $state = if ($_.Status -eq 'Up') { 'up' } else { 'down' }
      $physical = if ($_.Virtual) { 0 } else { 1 }
      "$(Net $_.Name)|$state|$($_.MacAddress -replace '-', ':')|$([int64]($_.Speed / 1000000))|$physical"
    }
    '@@netaddr'
    Get-NetIPAddress -ErrorAction SilentlyContinue | ForEach-Object { "$(Net $_.InterfaceAlias) $($_.IPAddress)/$($_.PrefixLength)" }
  }
  if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    '@@nvidia'
    nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit --format=csv,noheader,nounits 2>$null
  }
}
"""#

    /// `pid user cpu% mem% rssKB elapsed command`, like `ps -eo pid,user,pcpu,pmem,rss,etime,args`.
    public static let processes = #"""
$total = (Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize * 1024
$cores = [Environment]::ProcessorCount
$cpu = @{}
Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction SilentlyContinue | ForEach-Object { $cpu[[int]$_.IDProcess] = $_.PercentProcessorTime }
$owners = @{}
try { Get-Process -IncludeUserName -ErrorAction Stop | ForEach-Object { $owners[$_.Id] = $_.UserName } } catch {}
Get-Process | ForEach-Object {
  $user = $owners[$_.Id]; if (-not $user) { $user = '-' }
  $user = (($user -split '\\')[-1]) -replace '\s+', '_'
  $c = 0; if ($cpu.ContainsKey($_.Id)) { $c = [math]::Round($cpu[$_.Id] / $cores, 1) }
  $m = [math]::Round(100 * $_.WorkingSet64 / $total, 1)
  $elapsed = '-'
  try { $t = (Get-Date) - $_.StartTime; $elapsed = '{0}-{1:00}:{2:00}:{3:00}' -f $t.Days, $t.Hours, $t.Minutes, $t.Seconds } catch {}
  $command = $_.Path; if (-not $command) { $command = $_.ProcessName }
  "$($_.Id) $user $c $m $([int64]($_.WorkingSet64 / 1024)) $elapsed $command"
}
"""#

    /// `$A[0]` = TERM or KILL, `$A[1]` = pid. TERM asks the program to close; KILL ends it.
    public static let kill = #"""
$id = [int]$A[1]
if ($A[0] -eq 'KILL' -or $A[0] -eq '9') { Stop-Process -Id $id -Force -ErrorAction Stop }
else { taskkill /PID $id 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { Stop-Process -Id $id -ErrorAction Stop } }
"""#

    /// `proto<TAB>addr:port<TAB>process<TAB>pid`, IPv6 addresses in brackets like `ss`.
    public static let listening = #"""
$names = @{}; Get-Process | ForEach-Object { $names[$_.Id] = $_.ProcessName }
function Addr($a, $p) { if ($a -like '*:*') { "[$a]:$p" } else { "$($a):$p" } }
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
  "tcp`t$(Addr $_.LocalAddress $_.LocalPort)`t$($names[[int]$_.OwningProcess])`t$($_.OwningProcess)" }
Get-NetUDPEndpoint -ErrorAction SilentlyContinue | ForEach-Object {
  "udp`t$(Addr $_.LocalAddress $_.LocalPort)`t$($names[[int]$_.OwningProcess])`t$($_.OwningProcess)" }
"""#

    public static let gpuProcesses = #"""
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
  nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory --format=csv,noheader,nounits 2>$null
}
"""#

    /// `@@winsvc` lines: `name|status|start type|display name`.
    public static let services = #"""
'@@winsvc'
Get-Service -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name)|$($_.Status)|$($_.StartType)|$($_.DisplayName)" }
"""#

    /// `$A[0]` = start|stop|restart, `$A[1]` = service name. Needs an administrator account.
    public static let serviceAction = #"""
switch ($A[0]) {
  'start' { Start-Service -Name $A[1] -ErrorAction Stop }
  'stop' { Stop-Service -Name $A[1] -Force -ErrorAction Stop }
  'restart' { Restart-Service -Name $A[1] -Force -ErrorAction Stop }
}
"""#

    /// Recent Service Control Manager events mentioning a service. `$A[0]` = name, `$A[1]` = count.
    public static let serviceLogs = #"""
$svc = Get-Service -Name $A[0] -ErrorAction SilentlyContinue
$label = if ($svc) { $svc.DisplayName } else { $A[0] }
Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager' } -MaxEvents 2000 -ErrorAction SilentlyContinue |
  Where-Object { $_.Message -like "*$label*" -or $_.Message -like "*$($A[0])*" } | Select-Object -First ([int]$A[1]) |
  Sort-Object TimeCreated | ForEach-Object { '{0:yyyy-MM-ddTHH:mm:ss} {1}: {2}' -f $_.TimeCreated, $_.ProviderName, ($_.Message -replace '\s+', ' ') }
"""#

    public static let containers = #"""
$F = '{{.ID}}\t{{.Image}}\t{{.Names}}\t{{.Status}}\t{{.State}}\t{{.Ports}}'
foreach ($e in 'docker', 'podman') {
  if (-not (Get-Command $e -ErrorAction SilentlyContinue)) { continue }
  $out = & $e ps -a --format $F 2>$null
  if ($LASTEXITCODE -eq 0) { "@@$e"; $out }
}
"""#

    /// `$A[0]` = engine, `$A[1]` = start|stop|restart|logs, `$A[2]` = container id.
    public static let containerAction = #"""
if ($A[1] -eq 'logs') { & $A[0] logs $A[2] --tail 300 2>&1 } else { & $A[0] $A[1] $A[2] 2>&1 }
exit $LASTEXITCODE
"""#

    public static let connections = #"""
$names = @{}; Get-Process | ForEach-Object { $names[$_.Id] = $_.ProcessName }
function Addr($a, $p) { if ($a -like '*:*') { "[$a]:$p" } else { "$($a):$p" } }
'@@sshports'
$sshd = Get-Process sshd -ErrorAction SilentlyContinue
if ($sshd) { Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $sshd.Id -contains $_.OwningProcess } | ForEach-Object { "cfg:$($_.LocalPort)" } }
'@@conn'; $env:SSH_CONNECTION
'@@ss'
Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | ForEach-Object {
  "0 0 $(Addr $_.LocalAddress $_.LocalPort) $(Addr $_.RemoteAddress $_.RemotePort) users:((`"$($names[[int]$_.OwningProcess])`",pid=$($_.OwningProcess),fd=0))" }
'@@end'
"""#

    /// Windows has no tmux or screen; the list is always empty.
    public static let remoteSessions = "'@@tmux'\n'@@end'\n"

    /// Event logs. `$A[0]` = log name, `$A[1]` = count.
    public static let logs = #"""
$events = Get-WinEvent -LogName $A[0] -MaxEvents ([int]$A[1]) -ErrorAction SilentlyContinue
if (-not $events) { [Console]::Error.WriteLine("The $($A[0]) event log is empty or not readable (Security needs an administrator)."); exit 1 }
$events | Sort-Object TimeCreated | ForEach-Object {
  '{0:yyyy-MM-ddTHH:mm:ss} {1} {2}[{3}]: {4}' -f $_.TimeCreated, $env:COMPUTERNAME, $_.ProviderName, $_.Id, ($_.Message -replace '\s+', ' ') }
"""#

    public static func logName(_ source: LogSource) -> String {
        switch source {
        case .system: "System"
        case .auth: "Security"
        case .kernel: "Application"
        case .file(let path): path
        }
    }
}
