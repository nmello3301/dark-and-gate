<#
.SYNOPSIS
  Zip every log a co-op playtest needs from this PC into one file on the Desktop.

.DESCRIPTION
  Works on the host and on a friend's PC (it ships in the friend package and
  runs from COLLECT-LOGS.bat), and while the game is still running: every file
  is first copied with shared read access, so files the game holds open are
  fine.

  Collects:
    Script Extender\DarkAndGate\   client.log, server.log (host only), native.log,
                                   native-*.txt, native-*.toml, session.log
    Script Extender Logs\          the newest "Extender Runtime" logs and the newest
                                   "Osiris Runtime" log (or SE's LogDirectory if set)
    <game>\bin\NativeMods\*.log    BG3WASD.log, BG3NativeCameraTweaks.log
    <game>\bin\                    Ch4nKyysModLoader.log, the newest network.*.log,
                                   ScriptExtenderSettings.json
    PlayerProfiles\Public\modsettings.lsx  (the load order)
    the newest DarkAndGate-backup-*\install.log + RESTORE.txt (friend installer)
    info.txt                       versions + SHA256 of the installed mod files

  Writes <Desktop>\DAG-logs-<who>-<COMPUTERNAME>-<time>.zip, where <who> is
  this machine's co-op tag from client.log ("p2", "p1-host"), else a guess
  ("host" / "client").

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\mp-collect-logs.ps1
#>
param(
  [string]$GameRoot,
  [string]$OutDir = [Environment]::GetFolderPath('Desktop'),
  [int]$Sessions = 3,
  [string]$Tag,
  [switch]$Reveal
)

$ErrorActionPreference = 'Stop'

$larian  = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3"
$ourDir  = Join-Path $larian 'Script Extender\DarkAndGate'
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$stage   = Join-Path ([System.IO.Path]::GetTempPath()) ("DAG-logs-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$notes   = New-Object System.Collections.Generic.List[string]
$copied  = 0

# ---------------------------------------------------------------- helpers

function Test-GameRoot([string]$p) {
  if (-not $p) { return $false }
  return ((Test-Path -LiteralPath (Join-Path $p 'bin\bg3_dx11.exe')) -or (Test-Path -LiteralPath (Join-Path $p 'bin\bg3.exe')))
}

function Find-GameRoot {
  # 1. the running game knows where it lives
  foreach ($proc in @(Get-Process -Name bg3_dx11, bg3 -ErrorAction SilentlyContinue)) {
    try { $p = Split-Path -Parent (Split-Path -Parent $proc.Path); if (Test-GameRoot $p) { return $p } } catch { }
  }
  # 2. Steam library folders, GOG, defaults
  $roots = New-Object System.Collections.Generic.List[string]
  foreach ($k in @(@('HKCU:\Software\Valve\Steam', 'SteamPath'), @('HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'InstallPath'))) {
    try { $v = (Get-ItemProperty -Path $k[0] -Name $k[1] -ErrorAction Stop).($k[1]); if ($v) { $roots.Add(($v -replace '/', '\').TrimEnd('\')) } } catch { }
  }
  $roots.Add('C:\Program Files (x86)\Steam')
  $cands = New-Object System.Collections.Generic.List[string]
  foreach ($s in $roots) {
    $cands.Add((Join-Path $s 'steamapps\common\Baldurs Gate 3'))
    $vdf = Join-Path $s 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
      foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
        $cands.Add((Join-Path ($m.Groups[1].Value -replace '\\\\', '\') 'steamapps\common\Baldurs Gate 3'))
      }
    }
  }
  foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games\1456460669')) {
    try { $p = (Get-ItemProperty -Path $k -Name path -ErrorAction Stop).path; if ($p) { $cands.Add($p) } } catch { }
  }
  $cands.Add("C:\GOG Games\Baldur's Gate 3")
  foreach ($c in $cands) { if (Test-GameRoot $c) { return $c } }
  return $null
}

# Copy a file the game may hold open (shared read, keeps the timestamp).
function Copy-Shared([string]$src, [string]$destRel) {
  $dst = Join-Path $stage $destRel
  try {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    $in = [System.IO.File]::Open($src, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]'ReadWrite, Delete')
    try {
      $out = [System.IO.File]::Create($dst)
      try { $in.CopyTo($out) } finally { $out.Dispose() }
    } finally { $in.Dispose() }
    try { [System.IO.File]::SetLastWriteTime($dst, [System.IO.File]::GetLastWriteTime($src)) } catch { }
    $script:copied++
  } catch {
    $script:notes.Add("could not copy ${src}: $($_.Exception.Message)")
  }
}

function Read-Shared([string]$src) {
  try {
    $in = [System.IO.File]::Open($src, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]'ReadWrite, Delete')
    try { $r = New-Object System.IO.StreamReader($in); return $r.ReadToEnd() } finally { $in.Dispose() }
  } catch { return '' }
}

function Get-Sha([string]$path) {
  try {
    $in = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]'ReadWrite, Delete')
    try {
      $sha = [System.Security.Cryptography.SHA256]::Create()
      return (($sha.ComputeHash($in) | ForEach-Object { $_.ToString('X2') }) -join '')
    } finally { $in.Dispose() }
  } catch { return "unreadable ($($_.Exception.Message))" }
}

function New-ZipFromFolder([string]$folder, [string]$zipPath) {
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
  $root = (Get-Item -LiteralPath $folder).FullName.TrimEnd('\')
  $fs = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew)
  try {
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
      foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File)) {
        $rel = $f.FullName.Substring($root.Length + 1) -replace '\\', '/'
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.FullName, $rel, [System.IO.Compression.CompressionLevel]::Optimal)
      }
    } finally { $zip.Dispose() }
  } finally { $fs.Dispose() }
}

function Newest([string]$dir, [string]$filter, [int]$n) {
  if (-not (Test-Path -LiteralPath $dir)) { return @() }
  return @(Get-ChildItem -LiteralPath $dir -Filter $filter -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First $n)
}

# ---------------------------------------------------------------- who am I?

$clientLog = Join-Path $ourDir 'client.log'
$serverLog = Join-Path $ourDir 'server.log'
$tagSource = 'given'
if (-not $Tag) {
  $text = ''
  if (Test-Path -LiteralPath $clientLog) { $text = Read-Shared $clientLog }
  $m = [regex]::Matches($text, '\[Client (p\d+)( host)?\]')
  if ($m.Count -gt 0) {
    $last = $m[$m.Count - 1]
    $Tag = $last.Groups[1].Value + $(if ($last.Groups[2].Success) { '-host' } else { '' })
    $tagSource = 'client.log tag'
  } else {
    $m = [regex]::Matches($text, 'MP: welcome: user \d+ \(peer (\d+)')
    if ($m.Count -gt 0) {
      $Tag = 'p' + $m[$m.Count - 1].Groups[1].Value
      $tagSource = 'client.log welcome'
    }
  }
  if (-not $Tag) {
    # server.log is only written by the host's game; on a friend's PC it is
    # either missing or left over from an older solo session.
    $Tag = 'client'
    if ((Test-Path -LiteralPath $serverLog) -and (Test-Path -LiteralPath $clientLog)) {
      $gap = [math]::Abs(((Get-Item -LiteralPath $serverLog).LastWriteTime - (Get-Item -LiteralPath $clientLog).LastWriteTime).TotalMinutes)
      if ($gap -lt 15) { $Tag = 'host' }
    }
    $tagSource = 'guess (no MP tag in client.log)'
  }
}
$computer = ($env:COMPUTERNAME -replace '[^A-Za-z0-9_-]', '')
$who = "$Tag-$computer"
Write-Host "Collecting Dark and Gate logs as '$who' ($tagSource)" -ForegroundColor Cyan

# ---------------------------------------------------------------- collect

New-Item -ItemType Directory -Force -Path $stage | Out-Null
try {
  # Our own logs
  if (Test-Path -LiteralPath $ourDir) {
    foreach ($f in @(Get-ChildItem -LiteralPath $ourDir -File)) {
      if ($f.Name -like '*.log' -or $f.Name -like 'native-*.txt' -or $f.Name -like 'native-*.toml') {
        Copy-Shared $f.FullName ("DarkAndGate\" + $f.Name)
      }
    }
  } else { $notes.Add("no Dark and Gate log folder: $ourDir") }

  # The game folder
  if (-not $GameRoot) { $GameRoot = Find-GameRoot }
  $bin = $null
  if ($GameRoot -and (Test-GameRoot $GameRoot)) { $bin = Join-Path $GameRoot 'bin' } else { $notes.Add('game folder not found: skipped bin\ logs (pass -GameRoot)') }

  # Script Extender's own logs: LogDirectory from its settings, else the default.
  $seLogDirs = New-Object System.Collections.Generic.List[string]
  $seSettings = $null
  if ($bin) {
    $seSettings = Join-Path $bin 'ScriptExtenderSettings.json'
    if (Test-Path -LiteralPath $seSettings) {
      Copy-Shared $seSettings 'bin\ScriptExtenderSettings.json'
      try { $sj = (Read-Shared $seSettings) | ConvertFrom-Json; if ($sj.LogDirectory) { $seLogDirs.Add([string]$sj.LogDirectory) } } catch { }
    }
  }
  $seLogDirs.Add((Join-Path $larian 'Script Extender Logs'))
  $seLogDirs.Add((Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'OsirisLogs'))
  $seFound = $false
  foreach ($d in $seLogDirs) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    $seFound = $true
    foreach ($f in (Newest $d 'Extender Runtime*.log' $Sessions)) { Copy-Shared $f.FullName ("SE-Logs\" + $f.Name) }
    foreach ($f in (Newest $d 'Osiris Runtime*.log' 1)) { Copy-Shared $f.FullName ("SE-Logs\" + $f.Name) }
    break
  }
  if (-not $seFound) { $notes.Add('no Script Extender log folder found (LogRuntime off in ScriptExtenderSettings.json?)') }

  if ($bin) {
    foreach ($f in (Newest (Join-Path $bin 'NativeMods') '*.log' 20)) { Copy-Shared $f.FullName ("bin\NativeMods\" + $f.Name) }
    foreach ($f in (Newest $bin '*ModLoader*.log' 5)) { Copy-Shared $f.FullName ("bin\" + $f.Name) }
    foreach ($f in (Newest $bin 'network.*.log' $Sessions)) { Copy-Shared $f.FullName ("bin\" + $f.Name) }
  }

  # Load order
  $lo = Join-Path $larian 'PlayerProfiles\Public\modsettings.lsx'
  if (Test-Path -LiteralPath $lo) { Copy-Shared $lo 'profile\modsettings.lsx' }

  # Friend installer's last run
  $lastBackup = @(Get-ChildItem -LiteralPath $larian -Directory -Filter 'DarkAndGate-backup-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1)
  foreach ($b in $lastBackup) {
    foreach ($n in 'install.log', 'RESTORE.txt') {
      $p = Join-Path $b.FullName $n
      if (Test-Path -LiteralPath $p) { Copy-Shared $p ("installer\" + $n) }
    }
  }

  # info.txt: what is installed here
  $info = New-Object System.Collections.Generic.List[string]
  $info.Add("Dark and Gate log bundle")
  $info.Add("who:      $who ($tagSource)")
  $info.Add("time:     $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
  $info.Add("windows:  $([Environment]::OSVersion.VersionString)")
  $procs = @(Get-Process -Name bg3_dx11, bg3 -ErrorAction SilentlyContinue)
  $info.Add("game running: $(if ($procs.Count -gt 0) { ($procs | ForEach-Object { "$($_.Name) pid $($_.Id)" }) -join ', ' } else { 'no' })")
  $info.Add("game folder: $(if ($GameRoot) { $GameRoot } else { 'not found' })")
  $info.Add("")
  $info.Add("Mods folder:")
  $modsDir = Join-Path $larian 'Mods'
  if (Test-Path -LiteralPath $modsDir) {
    foreach ($f in @(Get-ChildItem -LiteralPath $modsDir -File)) {
      $extra = ''
      if ($f.Name -eq 'DarkAndGate.pak') { $extra = '  sha256 ' + (Get-Sha $f.FullName) }
      $info.Add(("  {0,-60} {1,12:N0}  {2:yyyy-MM-dd HH:mm}{3}" -f $f.Name, $f.Length, $f.LastWriteTime, $extra))
    }
  } else { $info.Add("  (missing)") }
  if ($bin) {
    $info.Add("")
    $info.Add("bin (loaders, Script Extender):")
    foreach ($n in 'DWrite.dll', 'version.dll', 'bink2w64_original.dll', 'ScriptExtenderSettings.json') {
      $p = Join-Path $bin $n
      if (Test-Path -LiteralPath $p) {
        # version.dll (Ch4nKyy's loader) is only stat'ed: Defender's cloud
        # check flags it the moment a script opens it.
        $desc = ''
        if ($n -eq 'DWrite.dll') { $vi = (Get-Item -LiteralPath $p).VersionInfo; $desc = "$($vi.ProductName) $($vi.FileVersion)" }
        $info.Add(("  {0,-28} {1,12:N0}  {2}" -f $n, (Get-Item -LiteralPath $p).Length, $desc))
      } else { $info.Add(("  {0,-28} (not present)" -f $n)) }
    }
    $info.Add("")
    $info.Add("bin\NativeMods:")
    $nm = Join-Path $bin 'NativeMods'
    if (Test-Path -LiteralPath $nm) {
      foreach ($f in @(Get-ChildItem -LiteralPath $nm -File)) {
        $extra = ''
        if ($f.Extension -eq '.dll') { $extra = "  $($f.VersionInfo.ProductName) $($f.VersionInfo.FileVersion)" }
        if ($f.Name -eq 'DarkAndGate.dll') {
          $extra = '  sha256 ' + (Get-Sha $f.FullName)
          $m = [regex]::Match([System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($f.FullName)), '(nogit|[0-9a-f]{7,12})(\+dirty)?-\d{8}T\d{6}Z')
          if ($m.Success) { $extra += "  build $($m.Value)" }
        }
        $info.Add(("  {0,-36} {1,12:N0}  {2:yyyy-MM-dd HH:mm}{3}" -f $f.Name, $f.Length, $f.LastWriteTime, $extra))
      }
    } else { $info.Add("  (missing)") }
  }
  # Windows Security detections on game / mod files (a blocked loader = no native mods).
  try {
    $hits = @(Get-MpThreatDetection -ErrorAction Stop | Where-Object { ($_.Resources -join ';') -match '(?i)Baldurs Gate 3|Baldur''s Gate 3|DarkAndGate' })
    if ($hits.Count -gt 0) {
      $names = @{}; foreach ($t in @(Get-MpThreat -ErrorAction SilentlyContinue)) { $names[[string]$t.ThreatID] = $t.ThreatName }
      $info.Add(""); $info.Add("Windows Security detections:")
      foreach ($h in $hits) { $info.Add(("  {0:yyyy-MM-dd HH:mm}  {1}  status {2}  {3}" -f $h.InitialDetectionTime, $names[[string]$h.ThreatID], $h.ThreatStatusID, ($h.Resources -join '; '))) }
    }
  } catch { }
  if ($notes.Count -gt 0) { $info.Add(""); $info.Add("notes:"); foreach ($n in $notes) { $info.Add("  $n") } }
  [System.IO.File]::WriteAllText((Join-Path $stage 'info.txt'), ($info -join "`r`n"), (New-Object System.Text.UTF8Encoding $false))

  if ($copied -eq 0) { Write-Host "No log files found on this PC (has the game run with the mod yet?). Zipping info.txt only." -ForegroundColor Yellow }

  if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
  $zipPath = Join-Path $OutDir "DAG-logs-$who-$stamp.zip"
  New-ZipFromFolder $stage $zipPath
} finally {
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($n in $notes) { Write-Host "  note: $n" -ForegroundColor DarkGray }
$size = (Get-Item -LiteralPath $zipPath).Length
Write-Host ""
Write-Host ("Logs zipped ({0} files, {1:N1} MB):" -f $copied, ($size / 1MB)) -ForegroundColor Green
Write-Host "  $zipPath" -ForegroundColor Green
Write-Host "Send this file to the host (Discord or similar)."
if ($Reveal) { try { Start-Process explorer.exe -ArgumentList "/select,`"$zipPath`"" } catch { } }
