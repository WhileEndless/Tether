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

    /// The file manager's search: the resolved folder, then the matches in the listing's format
    /// with paths relative to it. Arguments: folder, mode, (POSIX pattern), pattern for -like,
    /// hidden (1/0), limit. Hidden items (a name starting with a dot, or the Hidden attribute) and
    /// what is inside hidden folders are left out unless asked; stops after the limit.
    static let search = pathHelper + #"""
$p = WinPath $A[0]
try { $item = Get-Item -LiteralPath $p -Force -ErrorAction Stop } catch { [Console]::Error.WriteLine("Cannot open directory: $($A[0])"); exit 1 }
$root = $item.FullName.TrimEnd('\', '/')
Slash $item.FullName
$mode = $A[1]; $pat = $A[3]; $hidden = $A[4] -eq '1'; $max = [int]$A[5] + 1
function Visible($f) {
  if ($hidden) { return $true }
  $rel = $f.FullName.Substring($root.Length).TrimStart('\', '/')
  if (($rel -split '[\\/]') | Where-Object { $_ -like '.*' }) { return $false }
  return -not ($f.Attributes -band [IO.FileAttributes]::Hidden)
}
Get-ChildItem -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
  (Visible $_) -and $(if ($mode -eq 'content') {
    (-not $_.PSIsContainer) -and $_.Length -lt 20MB -and (Select-String -LiteralPath $_.FullName -SimpleMatch -Pattern $pat -Quiet -ErrorAction SilentlyContinue)
  } else { $_.Name -like $pat })
} | Select-Object -First $max | ForEach-Object {
  $kind = if ($_.LinkType) { 'l' } elseif ($_.PSIsContainer) { 'd' } else { 'f' }
  $bits = if ($_.PSIsContainer) { '755' } elseif ($_.IsReadOnly) { '444' } else { '644' }
  $size = if ($_.PSIsContainer) { 0 } else { $_.Length }
  $target = if ($_.LinkType) { ($_.Target | Select-Object -First 1) -replace '\\', '/' } else { '' }
  $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
  "$kind`t$bits`t-`t-`t$size`t$(Epoch $_.LastWriteTime)`t$target`t$rel"
}
"""#

    /// First line: the resolved folder. Then one free name per wanted name (`name-1.ext`, …).
    static let uniqueNames = pathHelper + #"""
$d = WinPath $A[0]
try { New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop | Out-Null } catch { [Console]::Error.WriteLine("Cannot write to $($A[0])"); exit 1 }
$d = (Get-Item -LiteralPath $d -Force).FullName
Slash $d
$taken = @{}
# name, the part before the number, the extension after it — for each wanted name.
for ($k = 1; $k + 2 -le $A.Count - 1; $k += 3) {
  $n = $A[$k]; $base = $A[$k + 1]; $ext = $A[$k + 2]
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

    /// `$A[0]` = 1 to move, `$A[1]` = folder, rest = paths. Free names (`name-1.ext`), never into
    /// itself, printed one per line (as the POSIX `pasteScript`).
    static let paste = pathHelper + #"""
$move = $A[0] -eq '1'
$d = WinPath $A[1]
if (-not (Test-Path -LiteralPath $d -PathType Container)) { [Console]::Error.WriteLine("Cannot write to $($A[1])"); exit 1 }
$dFull = (Get-Item -LiteralPath $d -Force).FullName.TrimEnd('\') + '\'
$taken = @{}
foreach ($p in ($A | Select-Object -Skip 2)) {
  $src = WinPath $p
  if (-not (Test-Path -LiteralPath $src)) { [Console]::Error.WriteLine("$p is no longer there"); exit 1 }
  $item = Get-Item -LiteralPath $src -Force
  $n = $item.Name
  if ($move -and ($item.FullName | Split-Path -Parent).TrimEnd('\') + '\' -eq $dFull) { $n; continue }
  if ($dFull.StartsWith($item.FullName.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { [Console]::Error.WriteLine("$n cannot be put into itself"); exit 1 }
  $base = $n; $ext = ''
  if ($n.LastIndexOf('.') -gt 0) { $base = $n.Substring(0, $n.LastIndexOf('.')); $ext = $n.Substring($n.LastIndexOf('.')) }
  $c = $n; $i = 1
  while ((Test-Path -LiteralPath (Join-Path $d $c)) -or $taken.ContainsKey($c.ToLower())) { $c = "$base-$i$ext"; $i++ }
  $taken[$c.ToLower()] = $true
  $dst = Join-Path $d $c
  if ($move) { Move-Item -LiteralPath $src -Destination $dst -ErrorAction Stop }
  else { Copy-Item -LiteralPath $src -Destination $dst -Recurse -ErrorAction Stop }
  $c
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
