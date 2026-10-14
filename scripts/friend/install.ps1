<#
.SYNOPSIS
  Install the Dark and Gate playtest build on a friend's PC and check that
  everything else matches the host.

.DESCRIPTION
  Run it through INSTALL.bat (double-click). It:
    1. finds Baldur's Gate 3 by itself: every Steam library (Steam's registry
       keys + libraryfolders.vdf), Steam's uninstall entry, GOG, then the
       usual folders on every fixed drive (or -GameRoot; it asks if all of
       that fails), and %LOCALAPPDATA% for the Mods folder and load order,
    2. refuses while the game is running,
    3. backs up every file it will replace into
       %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\DarkAndGate-backup-<time>\
    4. copies DarkAndGate.pak into the Mods folder, DarkAndGate.dll and the
       host's .toml configs into <game>\bin\NativeMods, and the host's
       ScriptExtenderSettings.json (console + logging on) into <game>\bin,
    5. checks the other mods (Script Extender, Ch4nKyy's Mod Loader, WASD,
       Native Camera Tweaks, MCM, AnimationUnlocker, Party Limit Begone) and
       the game version (bg3_dx11.exe) against manifest.json,
    6. checks the load order (the host's: MCM > AnimationUnlocker >
       DarkAndGate) and offers to fix modsettings.lsx (backed up first),
    7. reminds that the game must run in DirectX 11, and ends with a green
       READY or a red list of what is still missing.
  It touches nothing else. RESTORE.txt in the backup folder says how to undo it.

.PARAMETER GameRoot
  The Baldur's Gate 3 folder (the one that contains "bin"), if it isn't found.

.PARAMETER WhatIf
  Dry run: show what would be copied, backed up and fixed; change nothing.

.PARAMETER NoPrompt
  Never ask: fail if the game isn't found, fix the load order without asking.

.PARAMETER FindOnly
  Print the game folder and the %LOCALAPPDATA% paths it finds, then stop.

.PARAMETER TargetRoot
  Testing only: treat <TargetRoot>\Baldurs Gate 3 as the game folder and
  <TargetRoot>\LocalAppData as %LOCALAPPDATA%. Nothing outside it is touched.

.EXAMPLE
  INSTALL.bat
  INSTALL.bat -GameRoot "D:\SteamLibrary\steamapps\common\Baldurs Gate 3"
  INSTALL.bat -FindOnly
  powershell -ExecutionPolicy Bypass -File install.ps1 -WhatIf
#>
param(
  [string]$GameRoot,
  [string]$TargetRoot,
  [switch]$WhatIf,
  [switch]$NoPrompt,
  [switch]$FindOnly
)

$ErrorActionPreference = 'Stop'
$pkg = $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# The host's game build (bg3_dx11.exe ProductVersion). manifest.json's
# host_game_exe.product_version overrides it.
$defaultGameVersion = '4.1.1.7631656'

# The host's load order when manifest.json has none.
$defaultOrder = @(
  [pscustomobject]@{ order = 1; name = 'Mod Configuration Menu'; uuid = '755a8a72-407f-4f0d-9a33-274ac0f0b53d'; version = '1.41.0.0' },
  [pscustomobject]@{ order = 2; name = 'AnimationUnlocker'; uuid = '7131033f-821a-3993-dad4-5bc235cbeb3b'; version = '1.0.5.5' },
  [pscustomobject]@{ order = 3; name = 'DarkAndGate'; uuid = 'd5d298fd-ba29-4dc1-8346-6ac96b8c2cd7'; version = '1.0.0.0' })

$nexus = 'https://www.nexusmods.com/baldursgate3/mods/'
$links = @{
  se = 'https://github.com/Norbyte/bg3se/releases'; loader = $nexus + '25474'; wasd = $nexus + '781'
  nct = $nexus + '945'; mcm = $nexus + '9162'; animunlock = $nexus + '16058'; plb = $nexus + '327'
  bg3mm = 'https://github.com/LaughingLeader/BG3ModManager/releases'
}

# ---------------------------------------------------------------- helpers

function Get-Sha([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }

function Get-Ver3([string]$v) {
  if (-not $v) { return $null }
  $parts = @(($v -replace '[^\d\.]', '').Split('.') | Where-Object { $_ -ne '' })
  if ($parts.Count -eq 0) { return $null }
  return (($parts | Select-Object -First 3) -join '.')
}

function Get-LocalAppData {
  foreach ($p in @($env:LOCALAPPDATA, [Environment]::GetFolderPath('LocalApplicationData'))) {
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
  }
  if ($env:USERPROFILE) { return (Join-Path $env:USERPROFILE 'AppData\Local') }
  return $null
}

function Test-GameRoot([string]$p) {
  if (-not $p) { return $false }
  return ((Test-Path -LiteralPath (Join-Path $p 'bin\bg3_dx11.exe')) -or (Test-Path -LiteralPath (Join-Path $p 'bin\bg3.exe')))
}

# Every place Baldur's Gate 3 can be, in order: each Steam library (Steam's
# registry keys + libraryfolders.vdf + the game's appmanifest), Steam's
# uninstall entry, GOG, then the usual folders on every fixed drive.
function Find-GameRoot {
  $cands = New-Object System.Collections.Generic.List[object]
  $steamRoots = New-Object System.Collections.Generic.List[string]
  foreach ($k in @(@('HKCU:\Software\Valve\Steam', 'SteamPath'),
                   @('HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'InstallPath'),
                   @('HKLM:\SOFTWARE\Valve\Steam', 'InstallPath'))) {
    try {
      $v = (Get-ItemProperty -Path $k[0] -Name $k[1] -ErrorAction Stop).($k[1])
      if ($v) { $steamRoots.Add(($v -replace '/', '\').TrimEnd('\')) }
    } catch { }
  }
  $steamRoots.Add('C:\Program Files (x86)\Steam')
  $steamRoots.Add('C:\Program Files\Steam')
  $libs = New-Object System.Collections.Generic.List[string]
  foreach ($s in $steamRoots) {
    if ($libs -notcontains $s) { $libs.Add($s) }
    foreach ($vdf in @((Join-Path $s 'steamapps\libraryfolders.vdf'), (Join-Path $s 'config\libraryfolders.vdf'))) {
      if (-not (Test-Path -LiteralPath $vdf)) { continue }
      try { $text = Get-Content -LiteralPath $vdf -Raw } catch { continue }
      foreach ($m in [regex]::Matches($text, '"(?:path|\d+)"\s+"([A-Za-z]:[^"]*)"')) {
        $l = ($m.Groups[1].Value -replace '\\\\', '\').TrimEnd('\')
        if ($libs -notcontains $l) { $libs.Add($l) }
      }
    }
  }
  foreach ($lib in $libs) {
    $acf = Join-Path $lib 'steamapps\appmanifest_1086940.acf'
    if (Test-Path -LiteralPath $acf) {
      try {
        $m = [regex]::Match((Get-Content -LiteralPath $acf -Raw), '"installdir"\s+"([^"]+)"')
        if ($m.Success) { $cands.Add([pscustomobject]@{ Path = (Join-Path $lib ('steamapps\common\' + $m.Groups[1].Value)); How = "Steam library $lib" }) }
      } catch { }
    }
    $cands.Add([pscustomobject]@{ Path = (Join-Path $lib 'steamapps\common\Baldurs Gate 3'); How = "Steam library $lib" })
  }
  foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 1086940',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Steam App 1086940')) {
    try {
      $p = (Get-ItemProperty -Path $k -Name InstallLocation -ErrorAction Stop).InstallLocation
      if ($p) { $cands.Add([pscustomobject]@{ Path = $p.TrimEnd('\'); How = "Steam's uninstall entry" }) }
    } catch { }
  }
  foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games\1456460669', 'HKLM:\SOFTWARE\GOG.com\Games\1456460669')) {
    try {
      $p = (Get-ItemProperty -Path $k -Name path -ErrorAction Stop).path
      if ($p) { $cands.Add([pscustomobject]@{ Path = $p.TrimEnd('\'); How = 'GOG' }) }
    } catch { }
  }
  $drives = @()
  try { $drives = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed -and $_.IsReady }) } catch { }
  foreach ($d in $drives) {
    $r = $d.RootDirectory.FullName
    foreach ($sub in 'SteamLibrary', 'Steam', 'Games\SteamLibrary', 'Games\Steam', 'Program Files (x86)\Steam', 'Program Files\Steam') {
      $cands.Add([pscustomobject]@{ Path = (Join-Path $r "$sub\steamapps\common\Baldurs Gate 3"); How = "searched drive $r" })
    }
    foreach ($sub in "GOG Games\Baldur's Gate 3", "Games\Baldur's Gate 3", "Program Files (x86)\GOG Galaxy\Games\Baldur's Gate 3") {
      $cands.Add([pscustomobject]@{ Path = (Join-Path $r $sub); How = "searched drive $r" })
    }
  }
  foreach ($c in $cands) { if (Test-GameRoot $c.Path) { return $c } }
  return $null
}

# modsettings.lsx Version64 (or the old 32-bit Version) -> "major.minor.revision.build"
function Convert-ModVersion([string]$v64, [string]$v32) {
  if ($v64) { $v = [int64]$v64; return "{0}.{1}.{2}.{3}" -f ($v -shr 55), (($v -shr 47) -band 0xFF), (($v -shr 31) -band 0xFFFF), ($v -band 0x7FFFFFFF) }
  if ($v32) { $v = [int64]$v32; return "{0}.{1}.{2}.{3}" -f ($v -shr 28), (($v -shr 24) -band 0xF), (($v -shr 16) -band 0xFF), ($v -band 0xFFFF) }
  return $null
}

function Read-LoadOrder([string]$path) {
  $out = @()
  if (-not (Test-Path -LiteralPath $path)) { return $out }
  try { [xml]$x = Get-Content -LiteralPath $path -Raw } catch { return $out }
  $i = 0
  foreach ($n in $x.SelectNodes("//node[@id='Mods']/children/node[@id='ModuleShortDesc']")) {
    $a = @{}
    foreach ($att in $n.SelectNodes("attribute")) { $a[$att.GetAttribute('id')] = $att.GetAttribute('value') }
    if ($a['Folder'] -match '^Gustav(X|Dev)?$') { continue }
    $i++
    $out += [pscustomobject]@{ order = $i; name = $a['Name']; folder = $a['Folder']; uuid = $a['UUID']; version = (Convert-ModVersion $a['Version64'] $a['Version']) }
  }
  return $out
}

# Everything red ends up in $missing (the final list); yellow counts as a warning.
$missing = New-Object System.Collections.Generic.List[object]
$warnCount = 0
function Add-Missing([string]$name, [string]$detail, [string]$link) {
  $missing.Add([pscustomobject]@{ Name = $name; Detail = $detail; Link = $link })
}

$rows = New-Object System.Collections.Generic.List[object]
function Add-Row([string]$name, [string]$status, [string]$detail, [string]$link) {
  $rows.Add([pscustomobject]@{ Name = $name; Status = $status; Detail = $detail; Link = $link })
}
$problemStatus = @('MISSING', 'WRONG VERSION', 'MISMATCH', 'FAILED', 'NOT ACTIVE')
$goodStatus = @('OK', 'MATCH', 'INSTALLED', 'CREATED', 'UP TO DATE', 'WOULD INSTALL')
function Show-Rows([string]$title) {
  Write-Host ""
  Write-Host $title -ForegroundColor Cyan
  Write-Host ("  {0,-34} {1,-14} {2}" -f 'Item', 'Status', 'Details') -ForegroundColor DarkGray
  foreach ($r in $rows) {
    $color = 'White'
    switch ($r.Status) {
      'OK' { $color = 'Green' } 'MATCH' { $color = 'Green' } 'INSTALLED' { $color = 'Green' } 'CREATED' { $color = 'Green' }
      'UP TO DATE' { $color = 'Green' } 'WOULD INSTALL' { $color = 'Cyan' } 'OPTIONAL' { $color = 'DarkGray' }
      'WARN' { $color = 'Yellow' } default { $color = 'Red' }
    }
    Write-Host ("  {0,-34} " -f $r.Name) -NoNewline
    Write-Host ("{0,-14}" -f $r.Status) -ForegroundColor $color -NoNewline
    Write-Host (" " + $r.Detail)
    if ($r.Link -and $goodStatus -notcontains $r.Status) {
      Write-Host ("  {0,-34} {1,-14}  get it: {2}" -f '', '', $r.Link) -ForegroundColor Cyan
    }
    if ($problemStatus -contains $r.Status) { Add-Missing $r.Name $r.Detail $r.Link }
    if ($r.Status -eq 'WARN') { $script:warnCount++ }
  }
  $rows.Clear()
}

# ---------------------------------------------------------------- 1. paths + find the game

Write-Host "Dark and Gate - friend installer" -ForegroundColor Cyan
if ($WhatIf) { Write-Host "DRY RUN (-WhatIf): nothing will be changed." -ForegroundColor Magenta }

if ($TargetRoot) {
  $TargetRoot = [System.IO.Path]::GetFullPath($TargetRoot)
  $localAppData = Join-Path $TargetRoot 'LocalAppData'
  if (-not $GameRoot) { $GameRoot = Join-Path $TargetRoot 'Baldurs Gate 3' }
  Write-Host "TEST MODE: everything happens under $TargetRoot" -ForegroundColor Magenta
} else {
  $localAppData = Get-LocalAppData
  if (-not $localAppData) { throw "Could not find your %LOCALAPPDATA% folder (C:\Users\<you>\AppData\Local)." }
}
$larian     = Join-Path $localAppData "Larian Studios\Baldur's Gate 3"
$modsDir    = Join-Path $larian 'Mods'
$loadOrderF = Join-Path $larian 'PlayerProfiles\Public\modsettings.lsx'
$profileDir = Split-Path -Parent $loadOrderF
$backupDir  = Join-Path $larian "DarkAndGate-backup-$stamp"

$gameHow = 'given with -GameRoot'
if ($GameRoot) {
  $GameRoot = $GameRoot.Trim().Trim('"').TrimEnd('\')
  if ((Split-Path -Leaf $GameRoot) -eq 'bin') { $GameRoot = Split-Path -Parent $GameRoot }
  if ($TargetRoot) { $gameHow = 'test folder' }
  elseif (-not (Test-GameRoot $GameRoot)) { throw "No bin\bg3_dx11.exe or bin\bg3.exe under: $GameRoot" }
} else {
  $found = Find-GameRoot
  if ($found) {
    $GameRoot = $found.Path; $gameHow = $found.How
  } else {
    if ($NoPrompt -or $FindOnly) { throw "Baldur's Gate 3 not found. Run again with -GameRoot ""<the folder that contains bin>""." }
    Write-Host ""
    Write-Host "I couldn't find Baldur's Gate 3." -ForegroundColor Yellow
    Write-Host "In Steam: right-click Baldur's Gate 3 > Manage > Browse local files, then copy that folder's path from the address bar."
    $answer = Read-Host "Paste the Baldur's Gate 3 folder here and press Enter"
    $GameRoot = "$answer".Trim().Trim('"').TrimEnd('\')
    if ((Split-Path -Leaf $GameRoot) -eq 'bin') { $GameRoot = Split-Path -Parent $GameRoot }
    if (-not (Test-GameRoot $GameRoot)) { throw "That folder has no bin\bg3_dx11.exe or bin\bg3.exe: $GameRoot" }
    $gameHow = 'typed in'
  }
}
$bin = Join-Path $GameRoot 'bin'
$nativeDir = Join-Path $bin 'NativeMods'
Write-Host "Game folder: $GameRoot  ($gameHow)"
Write-Host "Mods folder: $modsDir"
Write-Host "Load order:  $loadOrderF"

if ($FindOnly) {
  foreach ($p in @($bin, $nativeDir, $larian, $modsDir, $loadOrderF)) {
    Write-Host ("  {0,-7} {1}" -f $(if (Test-Path -LiteralPath $p) { 'exists' } else { 'MISSING' }), $p)
  }
  exit 0
}

# ---------------------------------------------------------------- 2. package + manifest

$manifest = $null
$manifestPath = Join-Path $pkg 'manifest.json'
if (Test-Path -LiteralPath $manifestPath) {
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  Write-Host ("Package: {0}  (mod build {1}, DLL build {2})" -f $manifest.package, $manifest.mod_build, $manifest.dll_build)
} else {
  Write-Host "manifest.json is missing: the install still works, but nothing can be compared with the host." -ForegroundColor Yellow
}

$payload = @()
foreach ($p in @(Get-ChildItem -LiteralPath $pkg -Filter '*.pak' -File)) {
  $payload += [pscustomobject]@{ Rel = $p.Name; Leaf = $p.Name; Src = $p.FullName; Kind = 'mods' }
}
$nmSrc = Join-Path $pkg 'NativeMods'
if (Test-Path -LiteralPath $nmSrc) {
  foreach ($f in @(Get-ChildItem -LiteralPath $nmSrc -File)) {
    $payload += [pscustomobject]@{ Rel = "NativeMods\$($f.Name)"; Leaf = $f.Name; Src = $f.FullName; Kind = 'native' }
  }
}
$seSrc = Join-Path $pkg 'ScriptExtenderSettings.json'
if (Test-Path -LiteralPath $seSrc) {
  $payload += [pscustomobject]@{ Rel = 'ScriptExtenderSettings.json'; Leaf = 'ScriptExtenderSettings.json'; Src = $seSrc; Kind = 'bin' }
}
if (-not ($payload | Where-Object { $_.Rel -eq 'DarkAndGate.pak' }) -or -not ($payload | Where-Object { $_.Rel -eq 'NativeMods\DarkAndGate.dll' })) {
  throw "DarkAndGate.pak or NativeMods\DarkAndGate.dll is not next to this script ($pkg). Extract the WHOLE zip first (right-click > Extract All), then run INSTALL.bat from the extracted folder."
}

# ---------------------------------------------------------------- 3. game must be closed

$running = Get-Process -Name bg3, bg3_dx11 -ErrorAction SilentlyContinue
if ($running) {
  if ($TargetRoot -or $WhatIf) {
    Write-Host "Note: Baldur's Gate 3 is running (ignored in test / dry-run mode)." -ForegroundColor Yellow
  } else {
    throw "Baldur's Gate 3 is running. Close the game completely, then run INSTALL.bat again."
  }
}

# ---------------------------------------------------------------- 4. back up and install

$installed = New-Object System.Collections.Generic.List[object]   # Dest, Backup (null = new file)
$changed = $false

function Ensure-Dir([string]$d) {
  if (-not (Test-Path -LiteralPath $d)) {
    if ($WhatIf) { Write-Host "  [dry run] would create folder $d" -ForegroundColor DarkGray }
    else { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  }
}

if (-not $WhatIf) {
  New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
  try { Start-Transcript -LiteralPath (Join-Path $backupDir 'install.log') -Force | Out-Null; $transcript = $true } catch { $transcript = $false }
}

try {
  Write-Host ""
  Write-Host "Installing" -ForegroundColor Cyan
  Ensure-Dir $modsDir
  Ensure-Dir $nativeDir

  foreach ($p in $payload) {
    if ($p.Kind -eq 'mods') { $dest = Join-Path $modsDir $p.Leaf; $backRel = 'Mods\' + $p.Leaf }
    elseif ($p.Kind -eq 'native') { $dest = Join-Path $nativeDir $p.Leaf; $backRel = 'bin\NativeMods\' + $p.Leaf }
    else { $dest = Join-Path $bin $p.Leaf; $backRel = 'bin\' + $p.Leaf }
    $srcSha = Get-Sha $p.Src
    $backup = $null
    if (Test-Path -LiteralPath $dest) {
      if ((Get-Sha $dest) -eq $srcSha) {
        Add-Row $p.Leaf 'UP TO DATE' "already installed: $dest" $null
        continue
      }
      $backup = Join-Path $backupDir $backRel
      if ($WhatIf) {
        Write-Host "  [dry run] would back up $dest -> $backup" -ForegroundColor DarkGray
      } else {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
        Copy-Item -LiteralPath $dest -Destination $backup -Force
        Write-Host "  backed up $dest" -ForegroundColor DarkGray
      }
    }
    if ($WhatIf) {
      Write-Host "  [dry run] would copy $($p.Rel) -> $dest" -ForegroundColor DarkGray
      Add-Row $p.Leaf 'WOULD INSTALL' $(if ($backup) { "replaces your copy (backed up first)" } else { "new file" }) $null
      continue
    }
    Copy-Item -LiteralPath $p.Src -Destination $dest -Force
    try { Unblock-File -LiteralPath $dest -ErrorAction Stop } catch { }
    if ((Get-Sha $dest) -ne $srcSha) {
      Add-Row $p.Leaf 'FAILED' "copy does not match the package: $dest" $null
    } else {
      Add-Row $p.Leaf 'INSTALLED' $(if ($backup) { "replaced (old copy backed up): $dest" } else { $dest }) $null
    }
    $installed.Add([pscustomobject]@{ Dest = $dest; Backup = $backup })
    $changed = $true
  }

  # Older packages had no ScriptExtenderSettings.json: create one only if missing.
  $seSettings = Join-Path $bin 'ScriptExtenderSettings.json'
  if (-not (Test-Path -LiteralPath $seSrc) -and -not (Test-Path -LiteralPath $seSettings)) {
    $json = "{`r`n    ""CreateConsole"": true,`r`n    ""EnableLogging"": true,`r`n    ""LogRuntime"": true`r`n}`r`n"
    if ($WhatIf) {
      Add-Row 'ScriptExtenderSettings.json' 'WOULD INSTALL' 'new file: turns the Script Extender console and its log on' $null
    } else {
      [System.IO.File]::WriteAllText($seSettings, $json, (New-Object System.Text.UTF8Encoding $false))
      $installed.Add([pscustomobject]@{ Dest = $seSettings; Backup = $null })
      $changed = $true
      Add-Row 'ScriptExtenderSettings.json' 'CREATED' 'console + logging on' $null
    }
  }
} catch [System.UnauthorizedAccessException] {
  Write-Host ""
  Write-Host "Windows refused to write a file: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "Close the game, then right-click INSTALL.bat > Run as administrator." -ForegroundColor Red
  throw
} catch [System.IO.IOException] {
  Write-Host ""
  Write-Host "A file could not be copied (in use or locked?): $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "Close Baldur's Gate 3 and BG3 Mod Manager, then run INSTALL.bat again." -ForegroundColor Red
  throw
}
Show-Rows 'Dark and Gate files'

# ---------------------------------------------------------------- 5. other mods + the game

function Get-Expected([string]$key) {
  if ($manifest -and $manifest.third_party) { foreach ($t in $manifest.third_party) { if ($t.key -eq $key) { return $t } } }
  return $null
}
$defaults = @{ loader = '1.0.0'; wasd = '1.9.9'; nct = '2.4.5'; mcm = '1.41.0.0'; animunlock = '1.0.5.5' }
function Expected-Version([string]$key) {
  $t = Get-Expected $key
  if ($t -and $t.expected_version) { return [string]$t.expected_version }
  return $defaults[$key]
}

# Script Extender
$dw = Join-Path $bin 'DWrite.dll'
$hostSe = $(if ((Get-Expected 'se') -and (Get-Expected 'se').host_se_version) { " (the host runs SE $((Get-Expected 'se').host_se_version))" } else { '' })
if (Test-Path -LiteralPath $dw) {
  $pn = "$((Get-Item -LiteralPath $dw).VersionInfo.ProductName)"
  if ($pn -match 'Script Extender') { Add-Row 'Script Extender' 'OK' "bin\DWrite.dll present; it updates itself when the game starts$hostSe" $links.se }
  else { Add-Row 'Script Extender' 'WARN' "bin\DWrite.dll is not the Script Extender ('$pn'); another mod uses that name" $links.se }
} else { Add-Row 'Script Extender' 'MISSING' "put DWrite.dll from the BG3SE-Updater zip into $bin" $links.se }

# SE console + logging (ScriptExtenderSettings.json, installed above)
$seSettings = Join-Path $bin 'ScriptExtenderSettings.json'
if ($WhatIf -and (Test-Path -LiteralPath $seSrc)) { $seSettings = $seSrc }   # dry run: judge the copy that would be installed
if (Test-Path -LiteralPath $seSettings) {
  $cc = $null; $el = $null
  try { $sj = Get-Content -LiteralPath $seSettings -Raw | ConvertFrom-Json; $cc = $sj.CreateConsole; $el = $sj.EnableLogging } catch { }
  if ($cc -eq $true) {
    $d = 'console on: a console window opens with the game'
    if ($el -ne $true) { $d += ' (EnableLogging is off, so there is less to send back)' }
    Add-Row 'Script Extender console' 'OK' $d $null
  } else {
    Add-Row 'Script Extender console' 'WARN' "CreateConsole is off in $seSettings. Hold SHIFT while the game starts to get the console, or set ""CreateConsole"": true in that file" $null
  }
} elseif ($WhatIf) {
  Add-Row 'Script Extender console' 'WOULD INSTALL' 'ScriptExtenderSettings.json will turn the console and logging on' $null
}

# Ch4nKyy's Mod Loader. Only stat'ed, never opened: Windows Defender's cloud
# check has flagged this DLL ("Trojan:Win32/Posilod.CA!cl") the moment a
# script read it, so the size is the fingerprint.
$vd = Join-Path $bin 'version.dll'
$lt = Get-Expected 'loader'
if (Test-Path -LiteralPath $vd) {
  $len = (Get-Item -LiteralPath $vd).Length
  if ($lt -and $lt.host -and $lt.host.size) {
    if ($len -eq $lt.host.size) { Add-Row "Ch4nKyy's Mod Loader" 'OK' "bin\version.dll, same size as the host's ($(Expected-Version 'loader'))" $links.loader }
    else { Add-Row "Ch4nKyy's Mod Loader" 'WARN' "bin\version.dll is $len bytes, the host's is $($lt.host.size): another version, or another mod's version.dll? The host has $(Expected-Version 'loader')" $links.loader }
  } else { Add-Row "Ch4nKyy's Mod Loader" 'OK' 'bin\version.dll present' $links.loader }
} else {
  Add-Row "Ch4nKyy's Mod Loader" 'MISSING' "put version.dll ($(Expected-Version 'loader')) into $bin. If it vanished, Windows Security may have removed it: see Protection history" $links.loader
}

# Windows Security detections on the game's mod files (read-only).
try {
  $threats = @{}
  foreach ($t in @(Get-MpThreat -ErrorAction Stop)) { $threats[[string]$t.ThreatID] = $t.ThreatName }
  $hits = @(Get-MpThreatDetection -ErrorAction Stop | Where-Object {
      ($_.Resources -join ';') -match '(?i)Baldurs Gate 3\\bin|Larian Studios\\Baldur''s Gate 3\\Mods|DarkAndGate' })
  if ($hits.Count -gt 0) {
    $files = @($hits | ForEach-Object { $_.Resources } | ForEach-Object { ($_ -replace '^[a-z]+:_', '') } | Select-Object -Unique)
    $names = @($hits | ForEach-Object { $threats[[string]$_.ThreatID] } | Where-Object { $_ } | Select-Object -Unique)
    Add-Row 'Windows Security' 'WARN' ("flagged {0} ({1}). A blocked loader means no native mods load. Windows Security > Virus & threat protection > Protection history: only restore/allow files you downloaded from the links in FRIEND-README" -f ($files -join ', '), ($names -join ', ')) $null
  }
} catch { }

# A second loader?
$nml = @()
foreach ($n in 'bink2w64_original.dll', 'NativeModLoader.log') { if (Test-Path -LiteralPath (Join-Path $bin $n)) { $nml += $n } }
if ($nml.Count -gt 0) {
  Add-Row 'Only one mod loader' 'WARN' ("Native Mod Loader looks installed too (bin\{0}): two loaders load every DLL twice. Remove it: Steam > Verify integrity of game files, then delete bin\bink2w64_original.dll" -f ($nml -join ', bin\')) $null
} else {
  Add-Row 'Only one mod loader' 'OK' 'no Native Mod Loader found' $null
}

# Native mods with a version number in the DLL
foreach ($d in @(@{ key = 'wasd'; name = 'WASD Character Movement'; file = 'BG3WASD.dll' },
                 @{ key = 'nct'; name = 'Native Camera Tweaks'; file = 'BG3NativeCameraTweaks.dll' })) {
  $f = Join-Path $nativeDir $d.file
  $t = Get-Expected $d.key
  $ev = Expected-Version $d.key
  if (-not (Test-Path -LiteralPath $f)) { Add-Row $d.name 'MISSING' "need $ev in $nativeDir (bin\NativeMods)" $links[$d.key]; continue }
  $fv = Get-Ver3 (Get-Item -LiteralPath $f).VersionInfo.FileVersion
  if ($ev -and $fv) {
    if ($fv -eq $ev) { Add-Row $d.name 'OK' "version $fv" $links[$d.key] }
    else { Add-Row $d.name 'WRONG VERSION' "you have $fv, the host has $ev (Nexus: Files > Old files if $ev is not the main file)" $links[$d.key] }
  } elseif ($t -and $t.host -and $t.host.sha256) {
    if ((Get-Sha $f) -eq $t.host.sha256) { Add-Row $d.name 'OK' 'same file as the host (no version info, compared by SHA256)' $links[$d.key] }
    else { Add-Row $d.name 'WRONG VERSION' 'not the same file as the host (compared by SHA256)' $links[$d.key] }
  } else { Add-Row $d.name 'WARN' 'installed, version unknown' $links[$d.key] }
}

# Pak mods: same file as the host (SHA256), else the version in the load order.
# $pakOk[key] = the friend has the host's version (the load-order fix needs it).
$myOrder = @(Read-LoadOrder $loadOrderF)
$myPaks = @()
if (Test-Path -LiteralPath $modsDir) { $myPaks = @(Get-ChildItem -LiteralPath $modsDir -Filter '*.pak' -File) }
$pakOk = @{}
function Check-Pak([string]$key, [string]$name, [string]$uuid, [string[]]$patterns, [bool]$optional) {
  $t = Get-Expected $key
  if ($t -and $t.patterns) { $patterns = @($t.patterns) }
  if ($t -and $t.uuid) { $uuid = $t.uuid }
  $ev = Expected-Version $key
  if ($t -and $t.host -and $t.host.sha256) {
    foreach ($p in ($myPaks | Where-Object { $_.Length -eq $t.host.size })) {
      if ((Get-Sha $p.FullName) -eq $t.host.sha256) {
        Add-Row $name 'OK' ("same file as the host ({0}{1})" -f $p.Name, $(if ($ev) { ", $ev" } else { '' })) $links[$key]
        $script:pakOk[$key] = $true
        return
      }
    }
  }
  $found = $null
  foreach ($pat in $patterns) { $found = $myPaks | Where-Object { $_.Name -like $pat } | Select-Object -First 1; if ($found) { break } }
  $mine = $null
  if ($uuid) { $mine = $myOrder | Where-Object { $_.uuid -eq $uuid } | Select-Object -First 1 }
  if (-not $found -and -not $mine) {
    if ($optional) { Add-Row $name 'OPTIONAL' 'not installed (only needed for 5+ players; then everyone needs it)' $links[$key] }
    else { Add-Row $name 'MISSING' $(if ($ev) { "need version $ev in $modsDir" } else { "need it in $modsDir" }) $links[$key] }
    return
  }
  if (-not $found) {
    Add-Row $name 'WARN' "active in your load order, but no matching .pak in $modsDir (renamed, or deleted?)" $links[$key]
    return
  }
  if ($mine -and $mine.version -and $ev) {
    if ($mine.version -eq $ev) { Add-Row $name 'OK' "version $ev (from your load order)" $links[$key]; $script:pakOk[$key] = $true }
    else { Add-Row $name 'WRONG VERSION' "you have $($mine.version), the host has $ev" $links[$key] }
    return
  }
  if ($t -and $t.host) { Add-Row $name 'WRONG VERSION' ("found {0}, but it is not the host's file{1}" -f $found.Name, $(if ($ev) { " (host: $ev)" } else { '' })) $links[$key] }
  else { Add-Row $name 'OK' "found $($found.Name)" $links[$key]; $script:pakOk[$key] = $true }
}
Check-Pak 'mcm' 'Mod Configuration Menu' '755a8a72-407f-4f0d-9a33-274ac0f0b53d' @('Mod Configuration Menu*.pak', '*MCM*.pak') $false
Check-Pak 'animunlock' 'AnimationUnlocker' '7131033f-821a-3993-dad4-5bc235cbeb3b' @('AnimationUnlocker*.pak') $false
$plb = Get-Expected 'plb'
Check-Pak 'plb' 'Party Limit Begone (SE pak)' $null @('*PartyLimitBegone*.pak', '*Party Limit Begone*.pak', '*PartyLimit*.pak') (-not ($plb -and $plb.required))

# Game version: bg3_dx11.exe's ProductVersion must be the host's.
$exe = Join-Path $bin 'bg3_dx11.exe'
$he = $null; if ($manifest) { $he = $manifest.host_game_exe }
$wantVer = $defaultGameVersion
if ($he -and $he.product_version) { $wantVer = [string]$he.product_version }
$gameOk = $false
if (-not (Test-Path -LiteralPath $exe)) {
  Add-Row 'Game version (bg3_dx11.exe)' 'MISSING' "no bin\bg3_dx11.exe in $bin (the DirectX 11 game). Steam > Baldur's Gate 3 > Properties > Installed Files > Verify integrity" $null
} else {
  $pv = "$((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion)".Trim()
  if ($pv -eq $wantVer) {
    $gameOk = $true
    if ($he -and $he.sha256 -and (Get-Sha $exe) -ne $he.sha256) {
      Add-Row 'Game version (bg3_dx11.exe)' 'WARN' "version $pv like the host's, but the exe differs from the host's (patched by a tool?). Steam > Verify integrity of game files restores it" $null
    } else {
      Add-Row 'Game version (bg3_dx11.exe)' 'MATCH' "version $pv, same as the host" $null
    }
  } else {
    $older = $null
    try { $older = ([version]$pv) -lt ([version]$wantVer) } catch { }
    if ($older -eq $true) { $how = "update the game: Steam > Library > Baldur's Gate 3 > Update (restart Steam if no update shows)" }
    elseif ($older -eq $false) { $how = "your game is newer than the host's: tell the host (the host must update too and send a new package)" }
    else { $how = 'both must run the same game version' }
    Add-Row 'Game version (bg3_dx11.exe)' 'WRONG VERSION' ("you have {0}, the host has {1}: {2}" -f $(if ($pv) { $pv } else { 'an unknown version' }), $wantVer, $how) $null
  }
}
Show-Rows 'Other mods and the game (must match the host)'

# ---------------------------------------------------------------- 6. installed files vs manifest

function Get-InstallDest([string]$rel) {
  $leaf = Split-Path -Leaf $rel
  if ($rel -like '*.pak') { return (Join-Path $modsDir $leaf) }
  if ($rel -notlike 'NativeMods\*') { return (Join-Path $bin $leaf) }
  return (Join-Path $nativeDir $leaf)
}
$dagPakOk = $false
if ($manifest -and $manifest.files) {
  foreach ($prop in $manifest.files.PSObject.Properties) {
    $rel = $prop.Name; $want = $prop.Value
    $leaf = Split-Path -Leaf $rel
    $dest = Get-InstallDest $rel
    if ($WhatIf) {
      $src = Join-Path $pkg $rel
      if ((Test-Path -LiteralPath $src) -and (Get-Sha $src) -eq $want.sha256) {
        Add-Row $leaf 'MATCH' "package copy OK, SHA256 $($want.sha256) (dry run: not installed)" $null
        if ($leaf -eq 'DarkAndGate.pak') { $dagPakOk = $true }
      } else { Add-Row $leaf 'MISMATCH' 'the package file is damaged or was changed: download the zip again' $null }
      continue
    }
    if (-not (Test-Path -LiteralPath $dest)) { Add-Row $leaf 'MISSING' "not at $dest" $null; continue }
    $have = Get-Sha $dest
    if ($have -eq $want.sha256) {
      Add-Row $leaf 'MATCH' "SHA256 $have" $null
      if ($leaf -eq 'DarkAndGate.pak') { $dagPakOk = $true }
    } else { Add-Row $leaf 'MISMATCH' "SHA256 $have, the host's is $($want.sha256)" $null }
  }
  Show-Rows 'Installed files vs the host''s build (manifest.json)'
} else {
  $dagPakOk = Test-Path -LiteralPath (Join-Path $(if ($WhatIf) { $pkg } else { $modsDir }) 'DarkAndGate.pak')
}

# ---------------------------------------------------------------- 7. load order

Write-Host ""
Write-Host "Load order (modsettings.lsx)" -ForegroundColor Cyan
$hostOrder = @()
if ($manifest -and $manifest.host_load_order) { $hostOrder = @($manifest.host_load_order) }
if ($hostOrder.Count -eq 0) { $hostOrder = $defaultOrder }
$hostIds = @($hostOrder | ForEach-Object { $_.uuid })
$hostNames = (@($hostOrder | ForEach-Object { $_.name }) -join ' > ')
$howTo = "by hand: open BG3 Mod Manager ($($links.bg3mm)), click Refresh, drag $hostNames from Inactive to Active in that order (everything else Inactive), then File > Export Order to Game (Ctrl+E)"

function Show-LoadOrder($mineList) {
  Write-Host ("  {0,-3} {1,-28} {2,-12} {3}" -f '#', 'Host mod', 'Host ver.', 'Yours') -ForegroundColor DarkGray
  foreach ($h in $hostOrder) {
    $mine = $mineList | Where-Object { $_.uuid -eq $h.uuid } | Select-Object -First 1
    if (-not $mine) { $txt = 'NOT ACTIVE'; $col = 'Red' }
    elseif ($mine.version -ne $h.version) { $txt = "active (#$($mine.order)), version $($mine.version) (different)"; $col = 'Yellow' }
    elseif ($mine.order -ne $h.order) { $txt = "active, but #$($mine.order) (wrong place)"; $col = 'Red' }
    else { $txt = "active (#$($mine.order))"; $col = 'Green' }
    Write-Host ("  {0,-3} {1,-28} {2,-12} " -f $h.order, $h.name, $h.version) -NoNewline
    Write-Host $txt -ForegroundColor $col
  }
  foreach ($m in $mineList) {
    if ($hostIds -notcontains $m.uuid) { Write-Host "  extra: $($m.name) is active for you but not for the host" -ForegroundColor Yellow }
  }
}
function Test-SameOrder($mineList) { return ((@($mineList | ForEach-Object { $_.uuid }) -join ',') -eq ($hostIds -join ',')) }

Show-LoadOrder $myOrder
$orderOk = Test-SameOrder $myOrder
if ($orderOk) {
  Write-Host "  Same mods in the same order as the host." -ForegroundColor Green
} else {
  $extras = @($myOrder | Where-Object { $hostIds -notcontains $_.uuid } | ForEach-Object { $_.name })
  if (-not (Test-Path -LiteralPath $loadOrderF)) { Write-Host "  You have no modsettings.lsx yet." -ForegroundColor Yellow }
  else { Write-Host "  Your load order differs from the host's." -ForegroundColor Yellow }

  # The fix copies the host's own modsettings.lsx (shipped in the package):
  # the same game module, the same mods, the same order. Only safe when the
  # game and the three paks are the host's versions.
  $hostLsx = Join-Path $pkg 'host-modsettings.lsx'
  $blockers = @()
  if (-not (Test-Path -LiteralPath $hostLsx)) { $blockers += 'the package has no host-modsettings.lsx' }
  elseif (-not (Test-SameOrder @(Read-LoadOrder $hostLsx))) { $blockers += 'host-modsettings.lsx in the package does not match manifest.json' }
  if (-not $gameOk) { $blockers += 'the game version must match the host''s first' }
  if (-not (Test-Path -LiteralPath $profileDir)) { $blockers += 'start the game once to the main menu and quit (there is no player profile yet)' }
  if (-not $pakOk['mcm']) { $blockers += 'Mod Configuration Menu must be the host''s version' }
  if (-not $pakOk['animunlock']) { $blockers += 'AnimationUnlocker must be the host''s version' }
  if (-not $dagPakOk) { $blockers += 'DarkAndGate.pak must be installed and match the host''s' }

  if ($blockers.Count -gt 0) {
    Write-Host "  INSTALL.bat can fix it once these are done: $($blockers -join '; ')." -ForegroundColor Yellow
    Write-Host "  Or fix it $howTo." -ForegroundColor White
    Add-Missing 'Load order' ("must be exactly $hostNames. INSTALL.bat fixes it once: $($blockers -join '; '). Or $howTo") $null
  } else {
    $doFix = $true
    if ($WhatIf) {
      Write-Host "  [dry run] would back up $loadOrderF and replace it with the host's load order ($hostNames)" -ForegroundColor Cyan
      if ($extras.Count -gt 0) { Write-Host "  [dry run] that would deactivate: $($extras -join ', ')" -ForegroundColor Cyan }
      $doFix = $false
    } elseif (-not $NoPrompt) {
      Write-Host "  Fix: replace your load order with the host's ($hostNames)." -ForegroundColor White
      if ($extras.Count -gt 0) { Write-Host "  That deactivates: $($extras -join ', '). The backup keeps your old list." -ForegroundColor White }
      $answer = Read-Host "  Fix it now? Your current modsettings.lsx is backed up first [Y/n]"
      if ("$answer".Trim() -match '^[nN]') { $doFix = $false }
    }
    if ($doFix) {
      try {
        $backup = $null
        $ro = $false
        if (Test-Path -LiteralPath $loadOrderF) {
          $backup = Join-Path $backupDir 'PlayerProfiles\Public\modsettings.lsx'
          New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
          Copy-Item -LiteralPath $loadOrderF -Destination $backup -Force
          $item = Get-Item -LiteralPath $loadOrderF
          if ($item.IsReadOnly) { $ro = $true; $item.IsReadOnly = $false }
        }
        Copy-Item -LiteralPath $hostLsx -Destination $loadOrderF -Force
        if ($ro) { (Get-Item -LiteralPath $loadOrderF).IsReadOnly = $true }   # it was read-only on purpose: keep it so
        $installed.Add([pscustomobject]@{ Dest = $loadOrderF; Backup = $backup })
        $changed = $true
        $myOrder = @(Read-LoadOrder $loadOrderF)
        $orderOk = Test-SameOrder $myOrder
        if ($orderOk) {
          Write-Host "  FIXED: your load order is now the host's ($hostNames)$(if ($backup) { '; the old one is in the backup folder' })." -ForegroundColor Green
          if ($extras.Count -gt 0) { Write-Host "  Deactivated: $($extras -join ', ')." -ForegroundColor Yellow }
        } else {
          Write-Host "  The new modsettings.lsx does not read back as the host's order." -ForegroundColor Red
          Add-Missing 'Load order' "the fix did not take; fix it $howTo" $null
        }
      } catch {
        Write-Host "  Could not write $loadOrderF ($($_.Exception.Message))." -ForegroundColor Red
        Add-Missing 'Load order' "could not write modsettings.lsx ($($_.Exception.Message)). Fix it $howTo" $null
      }
    } elseif (-not $WhatIf) {
      Write-Host "  Not changed. Fix it $howTo." -ForegroundColor White
      Add-Missing 'Load order' "must be exactly $hostNames. Run INSTALL.bat again and answer Y, or $howTo" $null
    }
  }
}
if ($myOrder.Count -gt 0 -and @($myOrder | Where-Object { $hostIds -notcontains $_.uuid }).Count -gt 0) { $warnCount++ }

# RESTORE.txt: how to undo exactly this install.
if (-not $WhatIf) {
  $lines = @("Dark and Gate install of $(Get-Date -Format 'yyyy-MM-dd HH:mm')", "Package: $(if ($manifest) { $manifest.package } else { '?' })", "",
             "To uninstall: close the game, then for each line below either copy the backup back or delete the new file.", "")
  foreach ($i in $installed) {
    if ($i.Backup) { $lines += "REPLACED  $($i.Dest)`r`n          restore it by copying back: $($i.Backup)" }
    else { $lines += "NEW       $($i.Dest)`r`n          (did not exist before: delete it)" }
  }
  if ($installed.Count -eq 0) { $lines += "(nothing was changed: everything was already up to date)" }
  $lines += @("", "If you did not restore modsettings.lsx above: untick DarkAndGate in BG3 Mod Manager and export the load order again.")
  [System.IO.File]::WriteAllText((Join-Path $backupDir 'RESTORE.txt'), ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding $false))
}

# ---------------------------------------------------------------- 8. DirectX 11 + verdict

Write-Host ""
Write-Host " DIRECTX 11 ONLY " -ForegroundColor Black -BackgroundColor Yellow
Write-Host "  Start the game in DirectX 11: in the Larian launcher, the box next to PLAY must say DirectX 11, not Vulkan." -ForegroundColor Yellow
Write-Host "  The host plays DX11, and Dark and Gate's native part only works in bin\bg3_dx11.exe." -ForegroundColor Yellow

Write-Host ""
if ($changed -and -not $WhatIf) { Write-Host "Backup of everything replaced + how to undo: $backupDir" -ForegroundColor DarkGray }
if ($WhatIf) {
  Write-Host "Dry run finished: nothing was changed." -ForegroundColor Magenta
  if ($missing.Count -gt 0) {
    Write-Host "A real run would still leave $($missing.Count) thing(s) missing:" -ForegroundColor Red
  } else {
    Write-Host "A real run would leave nothing missing." -ForegroundColor Green
  }
} elseif ($missing.Count -eq 0) {
  Write-Host ""
  Write-Host "   ===========   " -ForegroundColor Black -BackgroundColor Green
  Write-Host "      READY      " -ForegroundColor Black -BackgroundColor Green
  Write-Host "   ===========   " -ForegroundColor Black -BackgroundColor Green
  Write-Host ""
  Write-Host "Launch the game (DirectX 11) and join the host." -ForegroundColor Green
} else {
  Write-Host " NOT READY: $($missing.Count) thing(s) missing " -ForegroundColor White -BackgroundColor DarkRed
}
$n = 0
foreach ($m in $missing) {
  $n++
  Write-Host ("  {0}. {1}: {2}" -f $n, $m.Name, $m.Detail) -ForegroundColor Red
  if ($m.Link) { Write-Host "     get it: $($m.Link)" -ForegroundColor Cyan }
}
if ($missing.Count -gt 0 -and -not $WhatIf) { Write-Host "Fix them, then run INSTALL.bat again." -ForegroundColor Red }
if ($warnCount -gt 0) { Write-Host "$warnCount warning(s) above (yellow): read them; they don't block you." -ForegroundColor Yellow }

if (-not $WhatIf -and $transcript) { try { Stop-Transcript | Out-Null } catch { } }
# Nothing replaced or created: drop the empty backup folder so "the newest
# DarkAndGate-backup-*" is always the one that can undo the install.
if (-not $WhatIf -and -not $changed) { Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue }
