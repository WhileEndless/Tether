import Foundation

/// PowerShell versions of the file manager's remote operations, for Windows hosts. Paths use
/// forward slashes (`C:/Users/user/Documents`); `/` lists the drives. Arguments arrive as `$A`.
enum WindowsFileScripts {
    /// Shared helper: `/C:/x` → `C:/x`, `~` and `/tmp` → real folders.
    static let pathHelper = #"""
function WinPath($p) {
  if ($p -eq '' -or $p -eq '~') { return $HOME }
  if ($p -eq '/tmp') { return [IO.Path]::GetTempPath() }
  if ($p -like '~/*') { return Join-Path $HOME $p.Substring(2) }
  if ($p -match '^/[A-Za-z]:') { $p = $p.Substring(1) }
  # "C:" alone means the current folder on drive C; the drive root is meant.
  if ($p -match '^[A-Za-z]:$') { $p += '/' }
  return $p
}
function Slash($p) { $p = $p -replace '\\', '/'; if ($p -match '^[A-Za-z]:$') { $p += '/' }; if ($p.Length -gt 3) { $p = $p.TrimEnd('/') }; $p }
function Epoch($d) { [int64](($d.ToUniversalTime() - [datetime]'1970-01-01').TotalSeconds) }

"""#

    /// Same format as the POSIX listing: resolved folder, then
    /// kind, octal mode, owner, group, size, mtime, link target, name (tab-separated).
    static let list = pathHelper + #"""
$p = $A[0]
if ($p -eq '/') {
  '/'
  Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object { "d`t755`t-`t-`t0`t0`t`t$($_.Name):" }
  exit 0
}
$p = WinPath $p
try { $item = Get-Item -LiteralPath $p -Force -ErrorAction Stop } catch { [Console]::Error.WriteLine("Cannot open directory: $($A[0])"); exit 1 }
Slash $item.FullName
Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue | ForEach-Object {
  $kind = if ($_.LinkType) { 'l' } elseif ($_.PSIsContainer) { 'd' } else { 'f' }
  $mode = if ($_.PSIsContainer) { '755' } elseif ($_.IsReadOnly) { '444' } else { '644' }
  $size = if ($_.PSIsContainer) { 0 } else { $_.Length }
  $target = if ($_.LinkType) { ($_.Target | Select-Object -First 1) -replace '\\', '/' } else { '' }
  "$kind`t$mode`t-`t-`t$size`t$(Epoch $_.LastWriteTime)`t$target`t$($_.Name)"
}
"""#

    /// First line: the resolved folder. Then one free name per wanted name (`name-1.ext`, …).
    static let uniqueNames = pathHelper + #"""
$d = WinPath $A[0]
try { New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop | Out-Null } catch { [Console]::Error.WriteLine("Cannot write to $($A[0])"); exit 1 }
$d = (Get-Item -LiteralPath $d -Force).FullName
Slash $d
$taken = @{}
foreach ($n in ($A | Select-Object -Skip 1)) {
  $base = $n; $ext = ''
  $dot = $n.LastIndexOf('.')
  if ($dot -gt 0) { $base = $n.Substring(0, $dot); $ext = $n.Substring($dot) }
  $c = $n; $i = 1
  while ((Test-Path -LiteralPath (Join-Path $d $c)) -or $taken.ContainsKey($c.ToLower())) { $c = "$base-$i$ext"; $i++ }
  $taken[$c.ToLower()] = 1
  $c
}
"""#

    static let measure = pathHelper + #"""
$files = 0; $bytes = 0
foreach ($p in $A) {
  $item = Get-Item -LiteralPath (WinPath $p) -Force -ErrorAction SilentlyContinue
  if (-not $item) { continue }
  if ($item.PSIsContainer) {
    $m = Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
    $files += $m.Count; $bytes += [int64]$m.Sum
  } else { $files += 1; $bytes += $item.Length }
}
"$files $([int64]($bytes / 1024))"
"""#

    /// `$A[0]` = Move-Item or Copy-Item, `$A[1]` = folder, rest = items. Prints names that already exist (skipped).
    static let transfer = pathHelper + #"""
$d = WinPath $A[1]
if (-not (Test-Path -LiteralPath $d -PathType Container)) { [Console]::Error.WriteLine("No such folder: $($A[1])"); exit 1 }
foreach ($p in ($A | Select-Object -Skip 2)) {
  $src = WinPath $p
  $n = Split-Path -Leaf $src
  $dst = Join-Path $d $n
  if (Test-Path -LiteralPath $dst) { $n; continue }
  if ($A[0] -eq 'Move-Item') { Move-Item -LiteralPath $src -Destination $dst -ErrorAction Stop }
  else { Copy-Item -LiteralPath $src -Destination $dst -Recurse -ErrorAction Stop }
}
"""#

    /// `$A[0]` = folder, `$A[1]` = archive name, rest = names. Uses the tar.exe built into Windows 10+.
    static let compress = pathHelper + #"""
Set-Location -LiteralPath (WinPath $A[0])
$names = $A | Select-Object -Skip 2
tar -czf $A[1] @names
exit $LASTEXITCODE
"""#

    static let makeDirectory = pathHelper + "New-Item -ItemType Directory -Force -Path (WinPath $A[0]) -ErrorAction Stop | Out-Null\n"

    static let rename = pathHelper + "Move-Item -LiteralPath (WinPath $A[0]) -Destination (WinPath $A[1]) -ErrorAction Stop\n"

    static let delete = pathHelper + #"""
$p = WinPath $A[0]
if ($p -match '^[A-Za-z]:[\\/]?$') { [Console]::Error.WriteLine('Refusing to delete a drive root.'); exit 1 }
Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
"""#

    static let details = pathHelper + #"""
$item = Get-Item -LiteralPath (WinPath $A[0]) -Force -ErrorAction SilentlyContinue
if (-not $item) { exit 1 }
if ($item.PSIsContainer) {
  'Folder'
  [int64]((Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1024)
} else {
  $v = $item.VersionInfo
  if ($v -and $v.FileDescription) { "$($v.FileDescription) $($v.FileVersion)".Trim() } else { "$($item.Extension.TrimStart('.').ToUpper()) file" }
}
"""#

    static let readHead = pathHelper + #"""
$fs = [IO.File]::OpenRead((WinPath $A[0]))
try { $buf = New-Object byte[] ([int]$A[1]); $n = $fs.Read($buf, 0, $buf.Length) } finally { $fs.Close() }
[Console]::Out.Write([Text.Encoding]::UTF8.GetString($buf, 0, $n))
"""#
}
