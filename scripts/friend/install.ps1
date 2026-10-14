<#
.SYNOPSIS
  Install the Dark and Gate playtest build on a friend's PC and check that
  everything else matches the host.

.DESCRIPTION
  Run it through INSTALL.bat (double-click). It:
    1. finds Baldur's Gate 3 (Steam library folders, GOG, the default path;
       or -GameRoot; asks if it can't find it),
    2. refuses while the game is running,
    3. backs up every file it will replace into
       %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\DarkAndGate-backup-<time>\
    4. copies DarkAndGate.pak into the Mods folder and DarkAndGate.dll + our
       .toml configs into <game>\bin\NativeMods,
    5. creates bin\ScriptExtenderSettings.json ONLY if it doesn't exist
       (turns the Script Extender console and its log on),
    6. checks the other mods (Script Extender, Ch4nKyy's Mod Loader, WASD,
       Native Camera Tweaks, MCM, AnimationUnlocker, Party Limit Begone),
       the game version and the load order against manifest.json,
       and prints what to fix.
  It touches nothing else.

.PARAMETER GameRoot
  The Baldur's Gate 3 folder (the one that contains "bin"), if it isn't found.

.PARAMETER WhatIf
  Dry run: show what would be copied and backed up, change nothing.

.PARAMETER TargetRoot
  Testing only: treat <TargetRoot>\Baldurs Gate 3 as the game folder and
  <TargetRoot>\LocalAppData as %LOCALAPPDATA%. Nothing outside it is touched.

.EXAMPLE
  INSTALL.bat
  INSTALL.bat -GameRoot "D:\SteamLibrary\steamapps\common\Baldurs Gate 3"
  powershell -ExecutionPolicy Bypass -File install.ps1 -WhatIf
#>
param(
  [string]$GameRoot,
  [string]$TargetRoot,
  [switch]$WhatIf,
  [switch]$NoPrompt
)

$ErrorActionPreference = 'Stop'
$pkg = $PSScriptRoot
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# ---------------------------------------------------------------- paths

if ($TargetRoot) {
  $TargetRoot = [System.IO.Path]::GetFullPath($TargetRoot)
  $localAppData = Join-Path $TargetRoot 'LocalAppData'
  if (-not $GameRoot) { $GameRoot = Join-Path $TargetRoot 'Baldurs Gate 3' }
  Write-Host "TEST MODE: everything happens under $TargetRoot" -ForegroundColor Magenta
} else {
  $localAppData = $env:LOCALAPPDATA
}
$larian     = Join-Path $localAppData "Larian Studios\Baldur's Gate 3"
$modsDir    = Join-Path $larian 'Mods'
$loadOrderF = Join-Path $larian 'PlayerProfiles\Public\modsettings.lsx'
$backupDir  = Join-Path $larian "DarkAndGate-backup-$stamp"

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

function Test-GameRoot([string]$p) {
  if (-not $p) { return $false }
  return ((Test-Path -LiteralPath (Join-Path $p 'bin\bg3_dx11.exe')) -or (Test-Path -LiteralPath (Join-Path $p 'bin\bg3.exe')))
}

function Find-GameRoot {
  $cands = New-Object System.Collections.Generic.List[string]
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
    $libs.Add($s)
    foreach ($vdf in @((Join-Path $s 'steamapps\libraryfolders.vdf'), (Join-Path $s 'config\libraryfolders.vdf'))) {
      if (-not (Test-Path -LiteralPath $vdf)) { continue }
      $text = Get-Content -LiteralPath $vdf -Raw
      foreach ($m in [regex]::Matches($text, '"(?:path|\d+)"\s+"([A-Za-z]:[^"]*)"')) {
        $libs.Add(($m.Groups[1].Value -replace '\\\\', '\').TrimEnd('\'))
      }
    }
  }
  foreach ($lib in $libs) {
    $acf = Join-Path $lib 'steamapps\appmanifest_1086940.acf'
    if (Test-Path -LiteralPath $acf) {
      $m = [regex]::Match((Get-Content -LiteralPath $acf -Raw), '"installdir"\s+"([^"]+)"')
      if ($m.Success) { $cands.Add((Join-Path $lib ('steamapps\common\' + $m.Groups[1].Value))) }
    }
    $cands.Add((Join-Path $lib 'steamapps\common\Baldurs Gate 3'))
  }
  foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games\1456460669', 'HKLM:\SOFTWARE\GOG.com\Games\1456460669')) {
    try { $p = (Get-ItemProperty -Path $k -Name path -ErrorAction Stop).path; if ($p) { $cands.Add($p) } } catch { }
  }
  $cands.Add("C:\GOG Games\Baldur's Gate 3")
  $cands.Add("C:\Program Files (x86)\GOG Galaxy\Games\Baldur's Gate 3")
  foreach ($c in $cands) { if (Test-GameRoot $c) { return $c } }
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

$rows = New-Object System.Collections.Generic.List[object]
function Add-Row([string]$name, [string]$status, [string]$detail, [string]$link) {
  $rows.Add([pscustomobject]@{ Name = $name; Status = $status; Detail = $detail; Link = $link })
}
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
    if ($r.Link -and @('OK', 'MATCH', 'INSTALLED', 'CREATED', 'UP TO DATE', 'WOULD INSTALL') -notcontains $r.Status) {
      Write-Host ("  {0,-34} {1,-14}  get it: {2}" -f '', '', $r.Link) -ForegroundColor Cyan
    }
  }
  $script:problems += @($rows | Where-Object { @('MISSING', 'WRONG VERSION', 'MISMATCH', 'FAILED', 'NOT ACTIVE') -contains $_.Status }).Count
  $script:warnCount += @($rows | Where-Object { $_.Status -eq 'WARN' }).Count
  $rows.Clear()
}
$problems = 0
$warnCount = 0

# ---------------------------------------------------------------- 0. package + manifest

Write-Host "Dark and Gate - friend installer" -ForegroundColor Cyan
if ($WhatIf) { Write-Host "DRY RUN (-WhatIf): nothing will be changed." -ForegroundColor Magenta }

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
  $payload += [pscustomobject]@{ Rel = $p.Name; Src = $p.FullName; Kind = 'mods' }
}
$nmSrc = Join-Path $pkg 'NativeMods'
if (Test-Path -LiteralPath $nmSrc) {
  foreach ($f in @(Get-ChildItem -LiteralPath $nmSrc -File)) {
    $payload += [pscustomobject]@{ Rel = "NativeMods\$($f.Name)"; Src = $f.FullName; Kind = 'native' }
  }
}
if (-not ($payload | Where-Object { $_.Rel -eq 'DarkAndGate.pak' }) -or -not ($payload | Where-Object { $_.Rel -eq 'NativeMods\DarkAndGate.dll' })) {
  throw "DarkAndGate.pak or NativeMods\DarkAndGate.dll is not next to this script ($pkg). Extract the WHOLE zip first (right-click > Extract All), then run INSTALL.bat from the extracted folder."
}

# ---------------------------------------------------------------- 1. find the game

if ($GameRoot) {
  $GameRoot = $GameRoot.Trim().Trim('"').TrimEnd('\')
  if ((Split-Path -Leaf $GameRoot) -eq 'bin') { $GameRoot = Split-Path -Parent $GameRoot }
  if (-not $TargetRoot -and -not (Test-GameRoot $GameRoot)) { throw "No bin\bg3_dx11.exe or bin\bg3.exe under: $GameRoot" }
} else {
  $GameRoot = Find-GameRoot
  if (-not $GameRoot) {
    if ($NoPrompt) { throw "Baldur's Gate 3 not found. Run again with -GameRoot ""<the folder that contains bin>""." }
    Write-Host ""
    Write-Host "I couldn't find Baldur's Gate 3." -ForegroundColor Yellow
    Write-Host "In Steam: right-click Baldur's Gate 3 > Manage > Browse local files, then copy that folder's path from the address bar."
    $answer = Read-Host "Paste the Baldur's Gate 3 folder here and press Enter"
    $GameRoot = "$answer".Trim().Trim('"').TrimEnd('\')
    if ((Split-Path -Leaf $GameRoot) -eq 'bin') { $GameRoot = Split-Path -Parent $GameRoot }
    if (-not (Test-GameRoot $GameRoot)) { throw "That folder has no bin\bg3_dx11.exe or bin\bg3.exe: $GameRoot" }
  }
}
$bin = Join-Path $GameRoot 'bin'
$nativeDir = Join-Path $bin 'NativeMods'
Write-Host "Game folder: $GameRoot"
Write-Host "Mods folder: $modsDir"

# ---------------------------------------------------------------- 2. game must be closed

$running = Get-Process -Name bg3, bg3_dx11 -ErrorAction SilentlyContinue
if ($running) {
  if ($TargetRoot -or $WhatIf) {
    Write-Host "Note: Baldur's Gate 3 is running (ignored in test / dry-run mode)." -ForegroundColor Yellow
  } else {
    throw "Baldur's Gate 3 is running. Close the game completely, then run INSTALL.bat again."
  }
}

# ---------------------------------------------------------------- 3 + 4. back up and install

$installed = New-Object System.Collections.Generic.List[object]   # Dest, Src, Backup (null = new file)
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
    if ($p.Kind -eq 'mods') { $dest = Join-Path $modsDir (Split-Path -Leaf $p.Rel); $backRel = 'Mods\' + (Split-Path -Leaf $p.Rel) }
    else { $dest = Join-Path $nativeDir (Split-Path -Leaf $p.Rel); $backRel = 'bin\NativeMods\' + (Split-Path -Leaf $p.Rel) }
    $srcSha = Get-Sha $p.Src
    $backup = $null
    if (Test-Path -LiteralPath $dest) {
      if ((Get-Sha $dest) -eq $srcSha) {
        Add-Row (Split-Path -Leaf $p.Rel) 'UP TO DATE' "already installed: $dest" $null
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
      Add-Row (Split-Path -Leaf $p.Rel) 'WOULD INSTALL' $(if ($backup) { "replaces your copy (backed up first)" } else { "new file" }) $null
      continue
    }
    Copy-Item -LiteralPath $p.Src -Destination $dest -Force
    try { Unblock-File -LiteralPath $dest -ErrorAction Stop } catch { }
    if ((Get-Sha $dest) -ne $srcSha) {
      Add-Row (Split-Path -Leaf $p.Rel) 'FAILED' "copy does not match the package: $dest" $null
    } else {
      Add-Row (Split-Path -Leaf $p.Rel) 'INSTALLED' $(if ($backup) { "replaced (old copy backed up): $dest" } else { $dest }) $null
    }
    $installed.Add([pscustomobject]@{ Dest = $dest; Backup = $backup })
    $changed = $true
  }

  # Script Extender settings: create ONLY if missing (the one bin file we may write).
  $seSettings = Join-Path $bin 'ScriptExtenderSettings.json'
  $seCreated = $false
  if (-not (Test-Path -LiteralPath $seSettings)) {
    $json = "{`r`n    ""CreateConsole"": true,`r`n    ""LogRuntime"": true`r`n}`r`n"
    if ($WhatIf) {
      Write-Host "  [dry run] would create $seSettings (console + runtime log on)" -ForegroundColor DarkGray
      Add-Row 'ScriptExtenderSettings.json' 'WOULD INSTALL' 'new file: turns the Script Extender console and its log on' $null
    } else {
      [System.IO.File]::WriteAllText($seSettings, $json, (New-Object System.Text.UTF8Encoding $false))
      $installed.Add([pscustomobject]@{ Dest = $seSettings; Backup = $null })
      $seCreated = $true; $changed = $true
      Add-Row 'ScriptExtenderSettings.json' 'CREATED' 'console + runtime log on' $null
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

# RESTORE.txt: how to undo exactly this install.
if (-not $WhatIf) {
  $lines = @("Dark and Gate install of $(Get-Date -Format 'yyyy-MM-dd HH:mm')", "Package: $(if ($manifest) { $manifest.package } else { '?' })", "",
             "To uninstall: close the game, then for each line below either copy the backup back or delete the new file.", "")
  foreach ($i in $installed) {
    if ($i.Backup) { $lines += "REPLACED  $($i.Dest)`r`n          restore it by copying back: $($i.Backup)" }
    else { $lines += "NEW       $($i.Dest)`r`n          (did not exist before: delete it)" }
  }
  if ($installed.Count -eq 0) { $lines += "(nothing was changed: everything was already up to date)" }
  $lines += @("", "Also untick DarkAndGate in BG3 Mod Manager and export the load order again.")
  [System.IO.File]::WriteAllText((Join-Path $backupDir 'RESTORE.txt'), ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding $false))
}

# ---------------------------------------------------------------- 5. checks

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

# SE console
$seSettings = Join-Path $bin 'ScriptExtenderSettings.json'
if (Test-Path -LiteralPath $seSettings) {
  $cc = $null; $lr = $null
  try { $sj = Get-Content -LiteralPath $seSettings -Raw | ConvertFrom-Json; $cc = $sj.CreateConsole; $lr = $sj.LogRuntime } catch { }
  if ($cc -eq $true) {
    $d = 'CreateConsole is on: a console window opens with the game'
    if ($lr -ne $true) { $d += ' (LogRuntime is off, so there is less to send back)' }
    Add-Row 'Script Extender console' 'OK' $d $null
  } else {
    Add-Row 'Script Extender console' 'WARN' "CreateConsole is off in $seSettings. Hold SHIFT while the game starts to get the console, or set ""CreateConsole"": true in that file" $null
  }
} elseif ($WhatIf) {
  Add-Row 'Script Extender console' 'WOULD INSTALL' 'ScriptExtenderSettings.json will be created with the console on' $null
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

# Pak mods: same file as the host (SHA256), else the version in the load order
$myOrder = @(Read-LoadOrder $loadOrderF)
$myPaks = @()
if (Test-Path -LiteralPath $modsDir) { $myPaks = @(Get-ChildItem -LiteralPath $modsDir -Filter '*.pak' -File) }
function Check-Pak([string]$key, [string]$name, [string]$uuid, [string[]]$patterns, [bool]$optional) {
  $t = Get-Expected $key
  if ($t -and $t.patterns) { $patterns = @($t.patterns) }
  if ($t -and $t.uuid) { $uuid = $t.uuid }
  $ev = Expected-Version $key
  if ($t -and $t.host -and $t.host.sha256) {
    foreach ($p in ($myPaks | Where-Object { $_.Length -eq $t.host.size })) {
      if ((Get-Sha $p.FullName) -eq $t.host.sha256) { Add-Row $name 'OK' ("same file as the host ({0}{1})" -f $p.Name, $(if ($ev) { ", $ev" } else { '' })) $links[$key]; return }
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
    if ($mine.version -eq $ev) { Add-Row $name 'OK' "version $ev (from your load order)" $links[$key] }
    else { Add-Row $name 'WRONG VERSION' "you have $($mine.version), the host has $ev" $links[$key] }
    return
  }
  if ($t -and $t.host) { Add-Row $name 'WRONG VERSION' ("found {0}, but it is not the host's file{1}" -f $(if ($found) { $found.Name } else { 'it in your load order' }), $(if ($ev) { " (host: $ev)" } else { '' })) $links[$key] }
  else { Add-Row $name 'OK' "found $(if ($found) { $found.Name } else { 'it in your load order' })" $links[$key] }
}
Check-Pak 'mcm' 'Mod Configuration Menu' '755a8a72-407f-4f0d-9a33-274ac0f0b53d' @('Mod Configuration Menu*.pak', '*MCM*.pak') $false
Check-Pak 'animunlock' 'AnimationUnlocker' '7131033f-821a-3993-dad4-5bc235cbeb3b' @('AnimationUnlocker*.pak') $false
$plb = Get-Expected 'plb'
Check-Pak 'plb' 'Party Limit Begone (SE pak)' $null @('*PartyLimitBegone*.pak', '*Party Limit Begone*.pak', '*PartyLimit*.pak') (-not ($plb -and $plb.required))

# Game version
$exe = Join-Path $bin 'bg3_dx11.exe'
$he = $null; if ($manifest) { $he = $manifest.host_game_exe }
if ($he -and $he.sha256 -and (Test-Path -LiteralPath $exe)) {
  if ((Get-Sha $exe) -eq $he.sha256) { Add-Row 'Game version (bg3_dx11.exe)' 'MATCH' 'same game build as the host' $null }
  else { Add-Row 'Game version (bg3_dx11.exe)' 'WARN' 'your game build differs from the host''s: update the game in Steam (both of you), or the native part may not work' $null }
} elseif (-not (Test-Path -LiteralPath $exe)) {
  Add-Row 'Game version (bg3_dx11.exe)' 'WARN' 'bin\bg3_dx11.exe not found: the host plays the DirectX 11 version' $null
}
Show-Rows 'Other mods and the game (must match the host)'

# ---------------------------------------------------------------- 6. installed files vs manifest

if ($manifest -and $manifest.files) {
  foreach ($prop in $manifest.files.PSObject.Properties) {
    $rel = $prop.Name; $want = $prop.Value
    $leaf = Split-Path -Leaf $rel
    if ($rel -like '*.pak') { $dest = Join-Path $modsDir $leaf } else { $dest = Join-Path $nativeDir $leaf }
    if ($WhatIf) {
      $src = Join-Path $pkg $rel
      if ((Test-Path -LiteralPath $src) -and (Get-Sha $src) -eq $want.sha256) { Add-Row $leaf 'MATCH' "package copy OK, SHA256 $($want.sha256) (dry run: not installed)" $null }
      else { Add-Row $leaf 'MISMATCH' 'the package file is damaged or was changed: download the zip again' $null }
      continue
    }
    if (-not (Test-Path -LiteralPath $dest)) { Add-Row $leaf 'MISSING' "not at $dest" $null; continue }
    $have = Get-Sha $dest
    if ($have -eq $want.sha256) { Add-Row $leaf 'MATCH' "SHA256 $have" $null }
    else { Add-Row $leaf 'MISMATCH' "SHA256 $have, the host's is $($want.sha256)" $null }
  }
  Show-Rows 'Installed files vs the host''s build (manifest.json)'
}

# ---------------------------------------------------------------- 7. load order

Write-Host ""
Write-Host "Load order (BG3 Mod Manager)" -ForegroundColor Cyan
$hostOrder = @()
if ($manifest -and $manifest.host_load_order) { $hostOrder = @($manifest.host_load_order) }
if ($hostOrder.Count -gt 0) {
  Write-Host ("  {0,-3} {1,-28} {2,-12} {3}" -f '#', 'Host mod', 'Host ver.', 'Yours') -ForegroundColor DarkGray
  foreach ($h in $hostOrder) {
    $mine = $myOrder | Where-Object { $_.uuid -eq $h.uuid } | Select-Object -First 1
    if (-not $mine) { $txt = 'NOT ACTIVE'; $col = 'Red'; $script:problems++ }
    elseif ($mine.version -ne $h.version) { $txt = "active, version $($mine.version) (different)"; $col = 'Yellow'; $script:warnCount++ }
    else { $txt = "active (#$($mine.order))"; $col = 'Green' }
    Write-Host ("  {0,-3} {1,-28} {2,-12} " -f $h.order, $h.name, $h.version) -NoNewline
    Write-Host $txt -ForegroundColor $col
  }
  $hostIds = @($hostOrder | ForEach-Object { $_.uuid })
  foreach ($m in $myOrder) {
    if ($hostIds -notcontains $m.uuid) { Write-Host "  extra: $($m.name) is active for you but not for the host: deactivate it for co-op" -ForegroundColor Yellow; $script:warnCount++ }
  }
  $mineShared = @($myOrder | Where-Object { $hostIds -contains $_.uuid } | ForEach-Object { $_.uuid })
  $hostShared = @($hostOrder | Where-Object { $mineShared -contains $_.uuid } | ForEach-Object { $_.uuid })
  if (($mineShared -join ',') -ne ($hostShared -join ',')) { Write-Host "  order: your mods are in a different order from the host's; drag them into the order above" -ForegroundColor Yellow; $script:warnCount++ }
  if ($myOrder.Count -eq 0 -and -not (Test-Path -LiteralPath $loadOrderF)) {
    Write-Host "  (no load order file yet: start the game once to the main menu, close it, then use BG3 Mod Manager)" -ForegroundColor Yellow
  }
} else {
  Write-Host "  manifest.json has no host load order; ask the host for the list." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  To turn the mods on: open BG3 Mod Manager ($($links.bg3mm)), click Refresh," -ForegroundColor White
Write-Host "  drag the mods above from Inactive to Active in that order, then File > Export Order to Game (Ctrl+E)." -ForegroundColor White

# ---------------------------------------------------------------- done

Write-Host ""
if ($WhatIf) {
  Write-Host "Dry run finished: nothing was changed." -ForegroundColor Magenta
} elseif ($changed) {
  Write-Host "Backup of everything replaced + how to undo: $backupDir" -ForegroundColor DarkGray
}
if ($problems -gt 0) {
  Write-Host "$problems thing(s) to fix above (red). Fix them, then run INSTALL.bat again." -ForegroundColor Red
} elseif ($warnCount -gt 0) {
  Write-Host "Installed. $warnCount warning(s) above (yellow): read them before you join." -ForegroundColor Yellow
} else {
  Write-Host "All set. Launch the game (DirectX 11) and join the host." -ForegroundColor Green
}

if (-not $WhatIf -and $transcript) { try { Stop-Transcript | Out-Null } catch { } }
# Nothing replaced or created: drop the empty backup folder so "the newest
# DarkAndGate-backup-*" is always the one that can undo the install.
if (-not $WhatIf -and -not $changed) { Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue }
