<#
.SYNOPSIS
  Install Dark and Gate and everything it needs from a folder of downloads.

.DESCRIPTION
  Put INSTALL.bat and this script into the folder where you downloaded the
  mods (zip / 7z / rar files as they come from Nexus Mods and GitHub, or
  already-extracted folders), close the game, double-click INSTALL.bat.

  It:
    1. finds Baldur's Gate 3 by itself (every Steam library, or -GameRoot),
       and refuses while the game is running;
    2. unpacks every archive in the folder into a temporary folder (Windows'
       own tar, else 7-Zip) and recognises each mod by the files inside, not
       by the download's name:
         Script Extender           DWrite.dll                 -> <game>\bin
         Ch4nKyy's Mod Loader      version.dll                -> <game>\bin
         WASD Character Movement   BG3WASD.dll (+ .toml)      -> <game>\bin\NativeMods
         Native Camera Tweaks      BG3NativeCameraTweaks.dll  -> <game>\bin\NativeMods
         Mod Configuration Menu    its .pak                   -> Mods folder
         AnimationUnlocker         AnimationUnlocker_*.pak    -> Mods folder
         Dark and Gate             DarkAndGate.pak            -> Mods folder
                                   DarkAndGate.dll            -> <game>\bin\NativeMods
         Dark and Gate's recommended settings (the -recommended-settings
         download): its two .toml files replace Native Camera Tweaks' and
         WASD's (skip with -KeepMySettings)
       Native Mod Loader is never installed (two loaders load every native
       mod twice);
    3. backs up every file it replaces into
       %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\DarkAndGate-backup-<time>\
       (RESTORE.txt there says how to undo it);
    4. puts Mod Configuration Menu > AnimationUnlocker > DarkAndGate at the
       end of the load order (modsettings.lsx; your other mods stay as they
       are), turns the Script Extender console on (ScriptExtenderSettings.json)
       and Dark and Gate's play mode on (no !dag_play needed);
    5. prints what is installed, what was already there and what is still
       missing, with the download link for each.
  Plain on purpose (docs/release.md, antivirus): no downloads, no hidden
  windows, no encoded commands, no Windows Security commands; version.dll is
  only copied, never read for a hash.

.PARAMETER Source
  The folder with the downloads (default: the folder this script is in).

.PARAMETER GameRoot
  The Baldur's Gate 3 folder (the one that contains "bin"), if it isn't found.

.PARAMETER KeepMySettings
  Don't replace Native Camera Tweaks' and WASD's .toml files with Dark and
  Gate's recommended settings.

.PARAMETER WhatIf
  Dry run: unpack and show what would be installed; change nothing in the game.

.PARAMETER NoPrompt
  Never ask anything (fail if the game isn't found).

.PARAMETER TargetRoot
  Testing only: <TargetRoot>\Baldurs Gate 3 is the game folder and
  <TargetRoot>\LocalAppData is %LOCALAPPDATA%. Nothing outside it is touched.

.EXAMPLE
  INSTALL.bat
  INSTALL.bat -WhatIf
  INSTALL.bat -GameRoot "D:\SteamLibrary\steamapps\common\Baldurs Gate 3"
#>
param(
  [string]$Source,
  [string]$GameRoot,
  [string]$TargetRoot,
  [switch]$KeepMySettings,
  [switch]$WhatIf,
  [switch]$NoPrompt
)

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $Source) { $Source = $PSScriptRoot }
$Source = [System.IO.Path]::GetFullPath($Source.Trim().Trim('"'))

$nexus = 'https://www.nexusmods.com/baldursgate3/mods/'
$links = @{
  se = 'https://github.com/Norbyte/bg3se/releases'; loader = $nexus + '25474'; wasd = $nexus + '781'
  nct = $nexus + '945'; mcm = $nexus + '9162'; animunlock = $nexus + '16058'
  dag = 'https://github.com/nmello3301/dark-and-gate/releases'
}

# Load-order entries (modsettings.lsx) for the three paks. An info.json next
# to a pak (Mod Configuration Menu's and Dark and Gate's downloads have one)
# wins over these. The game loads a mod whose listed version differs from
# its pak, so an older number here only shows up in BG3 Mod Manager.
$known = @{
  mcm        = @{ Name = 'Mod Configuration Menu'; UUID = '755a8a72-407f-4f0d-9a33-274ac0f0b53d'; Folder = 'BG3MCM'; Version64 = '41799034041532416' }
  animunlock = @{ Name = 'AnimationUnlocker'; UUID = '7131033f-821a-3993-dad4-5bc235cbeb3b'; Folder = 'AnimationUnlocker_7131033f-821a-3993-dad4-5bc235cbeb3b'; Version64 = '36028807756382213' }
  dag        = @{ Name = 'DarkAndGate'; UUID = 'd5d298fd-ba29-4dc1-8346-6ac96b8c2cd7'; Folder = 'DarkAndGate'; Version64 = '562949953421312' }
}
$orderKeys = @('mcm', 'animunlock', 'dag')   # load order, top to bottom

# ---------------------------------------------------------------- helpers

function Get-LocalAppData {
  foreach ($p in @($env:LOCALAPPDATA, [Environment]::GetFolderPath('LocalApplicationData'))) {
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
  }
  if ($env:USERPROFILE) { return (Join-Path $env:USERPROFILE 'AppData\Local') }
  return $null
}

function Test-GameRoot([string]$p) {
  if (-not $p) { return $false }
  # Join-Path throws for a drive that doesn't exist (a mistyped -GameRoot).
  try { return ((Test-Path -LiteralPath (Join-Path $p 'bin\bg3_dx11.exe')) -or (Test-Path -LiteralPath (Join-Path $p 'bin\bg3.exe'))) } catch { return $false }
}

# Every Steam library (Steam's registry keys + libraryfolders.vdf + the
# game's appmanifest), Steam's uninstall entry, then the usual folders on
# every fixed drive.
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
  $drives = @()
  try { $drives = @([System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed -and $_.IsReady }) } catch { }
  foreach ($d in $drives) {
    $r = $d.RootDirectory.FullName
    foreach ($sub in 'SteamLibrary', 'Steam', 'Games\SteamLibrary', 'Games\Steam', 'Program Files (x86)\Steam', 'Program Files\Steam') {
      $cands.Add([pscustomobject]@{ Path = (Join-Path $r "$sub\steamapps\common\Baldurs Gate 3"); How = "searched drive $r" })
    }
  }
  foreach ($c in $cands) { if (Test-GameRoot $c.Path) { return $c } }
  return $null
}

function Convert-ModVersion([string]$v64) {
  if (-not $v64) { return '?' }
  $v = [int64]$v64
  return "{0}.{1}.{2}.{3}" -f ($v -shr 55), (($v -shr 47) -band 0xFF), (($v -shr 31) -band 0xFFFF), ($v -band 0x7FFFFFFF)
}

function Write-Utf8([string]$path, [string]$text) {
  [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
}

# Result table: every line is one item; red ones are listed again at the end.
$rows = New-Object System.Collections.Generic.List[object]
function Add-Row([string]$name, [string]$status, [string]$detail, [string]$link) {
  $rows.Add([pscustomobject]@{ Name = $name; Status = $status; Detail = $detail; Link = $link })
}
$goodStatus = @('INSTALLED', 'UP TO DATE', 'ALREADY THERE', 'SET', 'WOULD INSTALL', 'WOULD SET')
$infoStatus = @('SKIPPED', 'KEPT')

# ---------------------------------------------------------------- 1. paths + find the game

Write-Host "Dark and Gate - installer (prerequisites + the mod)" -ForegroundColor Cyan
if ($WhatIf) { Write-Host "DRY RUN (-WhatIf): the game and your settings are not changed." -ForegroundColor Magenta }

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
$playModeF  = Join-Path $larian 'Script Extender\DarkAndGate\play-mode.json'
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
    if ($NoPrompt) { throw "Baldur's Gate 3 not found. Run again with -GameRoot ""<the folder that contains bin>""." }
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
Write-Host "Downloads:   $Source"
Write-Host "Game folder: $GameRoot  ($gameHow)"
Write-Host "Mods folder: $modsDir"

$running = Get-Process -Name bg3, bg3_dx11 -ErrorAction SilentlyContinue
if ($running) {
  if ($TargetRoot -or $WhatIf) { Write-Host "Note: Baldur's Gate 3 is running (ignored in test / dry-run mode)." -ForegroundColor Yellow }
  else { throw "Baldur's Gate 3 is running. Close the game completely, then run INSTALL.bat again." }
}

# ---------------------------------------------------------------- 2. unpack the downloads

if ($TargetRoot) { $staging = Join-Path $TargetRoot "staging-$stamp" } else { $staging = Join-Path ([System.IO.Path]::GetTempPath()) "DarkAndGate-install-$stamp" }
New-Item -ItemType Directory -Force -Path $staging | Out-Null

$tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
$sevenZip = $null
foreach ($p in @((Join-Path $env:ProgramFiles '7-Zip\7z.exe'), (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe'))) {
  if ($p -and (Test-Path -LiteralPath $p)) { $sevenZip = $p; break }
}

# Windows' own tar (libarchive: zip, 7z, rar on Windows 11), then Expand-Archive
# for zips, then 7-Zip if it is installed. -> $true when something came out.
function Expand-Download([System.IO.FileInfo]$archive, [string]$dest) {
  # A native tool's error text must not stop the script (Windows PowerShell
  # turns it into a terminating error under 'Stop'): the next tool is tried.
  $ErrorActionPreference = 'Continue'
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  $hasFiles = { @(Get-ChildItem -LiteralPath $dest -Recurse -File -ErrorAction SilentlyContinue).Count -gt 0 }
  if (Test-Path -LiteralPath $tarExe) {
    try { & $tarExe -xf $archive.FullName -C $dest 2>$null | Out-Null; if ($LASTEXITCODE -eq 0 -and (& $hasFiles)) { return $true } } catch { }
  }
  if ($archive.Extension -ieq '.zip') {
    try { Expand-Archive -LiteralPath $archive.FullName -DestinationPath $dest -Force; if (& $hasFiles) { return $true } } catch { }
  }
  if ($sevenZip) {
    try { & $sevenZip x -y ("-o" + $dest) $archive.FullName 2>$null | Out-Null; if ($LASTEXITCODE -eq 0 -and (& $hasFiles)) { return $true } } catch { }
  }
  return $false
}

Write-Host ""
Write-Host "Unpacking the downloads..." -ForegroundColor Cyan
$failedArchives = New-Object System.Collections.Generic.List[string]
$archives = @(Get-ChildItem -LiteralPath $Source -Recurse -File -ErrorAction SilentlyContinue |
              Where-Object { @('.zip', '.7z', '.rar') -contains $_.Extension.ToLowerInvariant() })
$i = 0
foreach ($a in $archives) {
  $i++
  if ($a.Length -gt 1GB) { Write-Host "  skipped (over 1 GB, not a mod download?): $($a.Name)" -ForegroundColor DarkGray; continue }
  $dest = Join-Path $staging ("{0:D2}-{1}" -f $i, [System.IO.Path]::GetFileNameWithoutExtension($a.Name))
  if (Expand-Download $a $dest) { Write-Host "  unpacked $($a.Name)" -ForegroundColor DarkGray }
  else { $failedArchives.Add($a.Name); Write-Host "  COULD NOT UNPACK $($a.Name)" -ForegroundColor Red }
}
if ($archives.Count -eq 0) { Write-Host "  no zip / 7z / rar files; looking at the folders only" -ForegroundColor DarkGray }

# ---------------------------------------------------------------- 3. recognise the mods

$files = @()
foreach ($root in @($Source, $staging)) {
  $files += @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue)
}
function Find-Named([string]$name) { @($files | Where-Object { $_.Name -ieq $name }) }
function Test-Recommended([System.IO.FileInfo]$f) { return ($f.FullName -match 'recommended-settings') }

# The mod an info.json next to a pak describes, or $null.
function Read-InfoJson([string]$dir) {
  $p = Join-Path $dir 'info.json'
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  try {
    $j = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
    $m = @($j.Mods)[0]
    if ($m -and $m.UUID) { return @{ Name = [string]$m.Name; UUID = [string]$m.UUID; Folder = [string]$m.Folder; Version64 = [string]$m.Version } }
  } catch { }
  return $null
}

# Of several copies, the highest version (info.json), then the newest file.
function Select-Best($cands) {
  return @($cands | Sort-Object -Property @{ Expression = { [int64]$_.Ver }; Descending = $true }, @{ Expression = { $_.File.LastWriteTime }; Descending = $true } | Select-Object -First 1)[0]
}
function New-Cand([System.IO.FileInfo]$f, $meta) {
  # info.json's version, else a DLL's version resource (Dark and Gate's says
  # 0.4.0) packed like Version64. Never for version.dll, which is not opened
  # (see Test-Same).
  $v = 0
  if ($meta -and $meta.Version64) { try { $v = [int64]$meta.Version64 } catch { $v = 0 } }
  elseif ($f.Extension -ieq '.dll' -and $f.Name -ine 'version.dll') {
    try {
      $fv = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($f.FullName)
      $v = ([int64]$fv.FileMajorPart -shl 55) -bor ([int64]$fv.FileMinorPart -shl 47) -bor ([int64]$fv.FileBuildPart -shl 31) -bor [int64]$fv.FilePrivatePart
    } catch { $v = 0 }
  }
  return [pscustomobject]@{ File = $f; Meta = $meta; Ver = $v }
}

$pick = @{}
$counts = @{}
function Add-Pick([string]$key, $cands) {
  $cands = @($cands | Where-Object { $_ })
  $counts[$key] = $cands.Count
  if ($cands.Count -gt 0) { $pick[$key] = Select-Best $cands }
}

Add-Pick 'se'     @(Find-Named 'DWrite.dll' | ForEach-Object { New-Cand $_ $null })
Add-Pick 'loader' @(Find-Named 'version.dll' | ForEach-Object { New-Cand $_ $null })
Add-Pick 'wasd'   @(Find-Named 'BG3WASD.dll' | ForEach-Object { New-Cand $_ $null })
Add-Pick 'nct'    @(Find-Named 'BG3NativeCameraTweaks.dll' | ForEach-Object { New-Cand $_ $null })
Add-Pick 'dagdll' @(Find-Named 'DarkAndGate.dll' | ForEach-Object { New-Cand $_ $null })
Add-Pick 'recwasd' @(Find-Named 'BG3WASD.toml' | Where-Object { Test-Recommended $_ } | ForEach-Object { New-Cand $_ $null })
Add-Pick 'recnct'  @(Find-Named 'BG3NativeCameraTweaks.toml' | Where-Object { Test-Recommended $_ } | ForEach-Object { New-Cand $_ $null })

$paks = @($files | Where-Object { $_.Extension -ieq '.pak' })
$mcmC = @(); $auC = @(); $dagC = @(); $otherPaks = @()
foreach ($p in $paks) {
  $info = Read-InfoJson $p.DirectoryName
  if (($info -and $info.UUID -eq $known.mcm.UUID) -or $p.BaseName -match '^(Mod Configuration Menu|BG3MCM)') { $mcmC += (New-Cand $p $(if ($info -and $info.UUID -eq $known.mcm.UUID) { $info } else { $null })) }
  elseif ($p.BaseName -like 'AnimationUnlocker*') { $auC += (New-Cand $p $null) }
  elseif ($p.Name -ieq 'DarkAndGate.pak') { $dagC += (New-Cand $p $(if ($info -and $info.UUID -eq $known.dag.UUID) { $info } else { $null })) }
  else { $otherPaks += $p.Name }
}
Add-Pick 'mcm' $mcmC
Add-Pick 'animunlock' $auC
Add-Pick 'dag' $dagC
$nmlInDownloads = (Find-Named 'bink2w64_original.dll').Count -gt 0

# The mod's own .toml next to its .dll (for a first install only).
function Get-SiblingToml($cand, [string]$tomlName) {
  if (-not $cand) { return $null }
  $p = Join-Path $cand.File.DirectoryName $tomlName
  if (Test-Path -LiteralPath $p) { return (Get-Item -LiteralPath $p) }
  return $null
}

# ---------------------------------------------------------------- 4. back up and install

$installed = New-Object System.Collections.Generic.List[object]   # Dest, Backup (null = new file)
$loaderBlocked = $null   # the downloaded version.dll Windows Security wouldn't let us read

function Backup-File([string]$dest) {
  $rel = $dest
  foreach ($root in @($GameRoot, $larian)) {
    if ($dest.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
      $tag = $(if ($root -eq $GameRoot) { 'game' } else { 'appdata' })
      $rel = Join-Path $tag $dest.Substring($root.Length).TrimStart('\')
      break
    }
  }
  $b = Join-Path $backupDir $rel
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $b) | Out-Null
  Copy-Item -LiteralPath $dest -Destination $b -Force
  return $b
}

# Same file already there? version.dll is compared by size and time only:
# reading it for a hash is what made Windows Security flag it (docs/release.md).
function Test-Same([string]$src, [string]$dest) {
  if (-not (Test-Path -LiteralPath $dest)) { return $false }
  $a = Get-Item -LiteralPath $src; $b = Get-Item -LiteralPath $dest
  if ($a.Length -ne $b.Length) { return $false }
  if ($a.Name -ieq 'version.dll') { return ($a.LastWriteTimeUtc -eq $b.LastWriteTimeUtc) }
  return ((Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash)
}

# Copy src -> dest (backing up what it replaces). Returns the row status.
function Install-File([string]$src, [string]$dest) {
  if (Test-Same $src $dest) { return 'UP TO DATE' }
  if ($WhatIf) { return 'WOULD INSTALL' }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
  $backup = $null
  if (Test-Path -LiteralPath $dest) { $backup = Backup-File $dest }
  Copy-Item -LiteralPath $src -Destination $dest -Force
  $installed.Add([pscustomobject]@{ Dest = $dest; Backup = $backup })
  return 'INSTALLED'
}

# Another copy of the same mod under a different file name in the Mods folder
# (e.g. an older download) would load twice: moved into the backup.
function Remove-OtherCopies([string]$pattern, [string]$keepName) {
  if (-not (Test-Path -LiteralPath $modsDir)) { return @() }
  $moved = @()
  foreach ($f in @(Get-ChildItem -LiteralPath $modsDir -Filter '*.pak' -File | Where-Object { $_.BaseName -match $pattern -and $_.Name -ine $keepName })) {
    if ($WhatIf) { $moved += "$($f.Name) (would be moved to the backup)"; continue }
    $b = Backup-File $f.FullName
    Remove-Item -LiteralPath $f.FullName -Force
    $installed.Add([pscustomobject]@{ Dest = $f.FullName; Backup = $b; Removed = $true })
    $moved += $f.Name
  }
  return $moved
}

Write-Host ""
Write-Host "Installing..." -ForegroundColor Cyan
if (-not $WhatIf) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }

function Install-Item([string]$key, [string]$label, [string]$dest, [string]$link) {
  $c = $pick[$key]
  if ($c) {
    # Windows Security can refuse to let anyone read a flagged file (Ch4nKyy's
    # version.dll, a known false positive): reported, not a crash.
    try { $st = Install-File $c.File.FullName $dest }
    catch {
      if ($key -eq 'loader') { $script:loaderBlocked = $c.File.FullName }
      Add-Row $label 'BLOCKED' ("could not copy " + $c.File.Name + ": " + $_.Exception.Message + $(if ($key -eq 'loader') { ' (Windows Security, see below)' } else { '' })) $link
      return $false
    }
    $more = $(if ($counts[$key] -gt 1) { " ($($counts[$key]) copies in the downloads; this one is the newest)" } else { '' })
    Add-Row $label $st ("from " + $c.File.FullName.Replace($staging, '<unpacked>').Replace($Source, '<downloads>') + $more) $link
    return $true
  }
  if (Test-Path -LiteralPath $dest) { Add-Row $label 'ALREADY THERE' "not in the downloads; $dest is already installed" $link; return $true }
  Add-Row $label 'MISSING' "not in the downloads and not installed" $link
  return $false
}

# Script Extender (the updater DLL fetches the extender itself at game start).
[void](Install-Item 'se' 'Script Extender' (Join-Path $bin 'DWrite.dll') $links.se)

# Ch4nKyy's Mod Loader; Native Mod Loader must not be there as well.
$loaderDest = Join-Path $bin 'version.dll'
$loaderWasThere = Test-Path -LiteralPath $loaderDest
[void](Install-Item 'loader' "Ch4nKyy's Mod Loader" $loaderDest $links.loader)
if ($nmlInDownloads) { Add-Row 'Native Mod Loader' 'SKIPPED' "in the downloads but not installed: Dark and Gate uses Ch4nKyy's Mod Loader, and two loaders load every native mod twice" $null }
if (Test-Path -LiteralPath (Join-Path $bin 'bink2w64_original.dll')) {
  Add-Row 'Native Mod Loader' 'CONFLICT' "is installed in $bin (bink2w64_original.dll): uninstall it (delete bin\bink2w64.dll, then rename bin\bink2w64_original.dll to bink2w64.dll); keep only Ch4nKyy's Mod Loader" $null
}

# WASD Character Movement + Native Camera Tweaks: the DLL, and the mod's own
# .toml only when there is none yet (Dark and Gate's recommended one below).
foreach ($m in @(@('wasd', 'WASD Character Movement', 'BG3WASD', $links.wasd), @('nct', 'Native Camera Tweaks', 'BG3NativeCameraTweaks', $links.nct))) {
  $ok = Install-Item $m[0] $m[1] (Join-Path $nativeDir ($m[2] + '.dll')) $m[3]
  $tomlDest = Join-Path $nativeDir ($m[2] + '.toml')
  $own = Get-SiblingToml $pick[$m[0]] ($m[2] + '.toml')
  if ($own -and -not (Test-Path -LiteralPath $tomlDest)) {
    $st = Install-File $own.FullName $tomlDest
    Add-Row ("  " + $m[2] + '.toml') $st "the mod's default settings (no settings file yet)" $null
  }
}

# Mod Configuration Menu, AnimationUnlocker, Dark and Gate: the paks.
$entries = @{}   # key -> load-order entry for the paks that end up in the Mods folder
$pakLabels = @{ mcm = 'Mod Configuration Menu'; animunlock = 'AnimationUnlocker'; dag = 'Dark and Gate (mod)' }
$pakPatterns = @{ mcm = '^(Mod Configuration Menu|BG3MCM)'; animunlock = '^AnimationUnlocker'; dag = '^DarkAndGate' }
foreach ($k in $orderKeys) {
  $c = $pick[$k]
  $link = $links[$(if ($k -eq 'dag') { 'dag' } else { $k })]
  if ($c) {
    $dest = Join-Path $modsDir $c.File.Name
    $st = Install-File $c.File.FullName $dest
    $moved = @(Remove-OtherCopies $pakPatterns[$k] $c.File.Name)
    $meta = $known[$k].Clone()
    if ($c.Meta) { foreach ($f in 'Name', 'UUID', 'Folder', 'Version64') { if ($c.Meta[$f]) { $meta[$f] = $c.Meta[$f] } } }
    $entries[$k] = $meta
    $detail = "version $(Convert-ModVersion $meta.Version64) -> Mods\$($c.File.Name)"
    if ($counts[$k] -gt 1) { $detail += " ($($counts[$k]) copies in the downloads; newest used)" }
    if ($moved.Count -gt 0) { $detail += "; other copies moved to the backup: $($moved -join ', ')" }
    Add-Row $pakLabels[$k] $st $detail $link
  } else {
    $there = @()
    if (Test-Path -LiteralPath $modsDir) { $there = @(Get-ChildItem -LiteralPath $modsDir -Filter '*.pak' -File | Where-Object { $_.BaseName -match $pakPatterns[$k] }) }
    if ($there.Count -gt 0) {
      $entries[$k] = $known[$k].Clone()
      Add-Row $pakLabels[$k] 'ALREADY THERE' "not in the downloads; Mods\$($there[0].Name) is already installed" $link
    } else {
      Add-Row $pakLabels[$k] 'MISSING' "not in the downloads and not installed" $link
    }
  }
}
[void](Install-Item 'dagdll' 'Dark and Gate (native DLL)' (Join-Path $nativeDir 'DarkAndGate.dll') $links.dag)

# Dark and Gate's recommended Native Camera Tweaks / WASD settings.
foreach ($m in @(@('recnct', 'BG3NativeCameraTweaks.toml', 'Recommended camera settings'), @('recwasd', 'BG3WASD.toml', 'Recommended WASD settings'))) {
  $c = $pick[$m[0]]
  $label = $m[2]
  if (-not $c) { Add-Row $label 'SKIPPED' "Dark and Gate's -recommended-settings download isn't in the folder (optional)" $null; continue }
  if ($KeepMySettings) { Add-Row $label 'KEPT' "your own $($m[1]) kept (-KeepMySettings)" $null; continue }
  $st = Install-File $c.File.FullName (Join-Path $nativeDir $m[1])
  $note = $(if ($st -eq 'INSTALLED') { '; your old one is in the backup' } else { '' })
  Add-Row $label $st "$($m[1]) as Dark and Gate is tested with$note" $null
}

# Script Extender console on (bin\ScriptExtenderSettings.json), other settings kept.
$seJson = Join-Path $bin 'ScriptExtenderSettings.json'
try {
  $cfg = $null
  if (Test-Path -LiteralPath $seJson) { $cfg = Get-Content -LiteralPath $seJson -Raw | ConvertFrom-Json }
  if ($cfg -and $cfg.PSObject.Properties['CreateConsole'] -and $cfg.CreateConsole -eq $true) {
    Add-Row 'Script Extender console' 'UP TO DATE' 'CreateConsole is already on' $null
  } elseif ($WhatIf) {
    Add-Row 'Script Extender console' 'WOULD SET' "CreateConsole = true in $seJson" $null
  } else {
    $backup = $null
    if (Test-Path -LiteralPath $seJson) { $backup = Backup-File $seJson }
    if (-not $cfg) { $cfg = New-Object psobject }
    if ($cfg.PSObject.Properties['CreateConsole']) { $cfg.CreateConsole = $true } else { $cfg | Add-Member -NotePropertyName CreateConsole -NotePropertyValue $true }
    Write-Utf8 $seJson ($cfg | ConvertTo-Json -Depth 8)
    $installed.Add([pscustomobject]@{ Dest = $seJson; Backup = $backup })
    Add-Row 'Script Extender console' 'SET' "CreateConsole = true in $seJson" $null
  }
} catch {
  Add-Row 'Script Extender console' 'FAILED' "could not update $seJson ($($_.Exception.Message)); set ""CreateConsole"": true in it by hand" $null
}

# Dark and Gate's play mode (what !dag_play remembers): on, unless you turned it off.
if (Test-Path -LiteralPath $playModeF) {
  Add-Row 'Dark and Gate play mode' 'KEPT' 'already chosen on this PC (!dag_play on|off changes it)' $null
} elseif ($WhatIf) {
  Add-Row 'Dark and Gate play mode' 'WOULD SET' 'on: first person and real-time fights start by themselves' $null
} else {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $playModeF) | Out-Null
  Write-Utf8 $playModeF "{`r`n    ""on"": true`r`n}"
  $installed.Add([pscustomobject]@{ Dest = $playModeF; Backup = $null })
  Add-Row 'Dark and Gate play mode' 'SET' 'on: first person and real-time fights start by themselves (no !dag_play needed)' $null
}

# ---------------------------------------------------------------- 5. load order

# modsettings.lsx: our three mods leave wherever they were and go to the end,
# Mod Configuration Menu > AnimationUnlocker > DarkAndGate. Everything else
# (the game's own module first, your other mods) stays as it is.
function New-ModNode([xml]$x, $m) {
  $n = $x.CreateElement('node'); $n.SetAttribute('id', 'ModuleShortDesc')
  foreach ($a in @(@('Folder', 'LSString', $m.Folder), @('MD5', 'LSString', ''), @('Name', 'LSString', $m.Name),
                   @('PublishHandle', 'uint64', '0'), @('UUID', 'guid', $m.UUID), @('Version64', 'int64', $m.Version64))) {
    $e = $x.CreateElement('attribute'); $e.SetAttribute('id', $a[0]); $e.SetAttribute('type', $a[1]); $e.SetAttribute('value', $a[2])
    [void]$n.AppendChild($e)
  }
  return $n
}

$orderNames = (@($orderKeys | ForEach-Object { $known[$_].Name }) -join ' > ')
if (-not (Test-Path -LiteralPath $loadOrderF)) {
  Add-Row 'Load order' 'MISSING' "no modsettings.lsx yet: start the game once to the main menu, quit, then run INSTALL.bat again" $null
} elseif ($entries.Count -eq 0) {
  Add-Row 'Load order' 'MISSING' "none of $orderNames is installed" $null
} else {
  try {
    [xml]$x = Get-Content -LiteralPath $loadOrderF -Raw
    $mods = $x.SelectSingleNode("//node[@id='Mods']/children")
    if (-not $mods) { throw "no Mods list in it" }
    $ids = @($orderKeys | ForEach-Object { $known[$_].UUID }) + @($entries.Values | ForEach-Object { $_.UUID })
    $before = @($mods.SelectNodes("node[@id='ModuleShortDesc']") | ForEach-Object { $_.SelectSingleNode("attribute[@id='UUID']").GetAttribute('value') })
    foreach ($n in @($mods.SelectNodes("node[@id='ModuleShortDesc']"))) {
      $u = $n.SelectSingleNode("attribute[@id='UUID']")
      if ($u -and $ids -contains $u.GetAttribute('value')) { [void]$mods.RemoveChild($n) }
    }
    foreach ($k in $orderKeys) { if ($entries[$k]) { [void]$mods.AppendChild((New-ModNode $x $entries[$k])) } }
    # Older load-order files also keep a ModOrder list.
    $orderList = $x.SelectSingleNode("//node[@id='ModOrder']/children")
    if ($orderList) {
      foreach ($n in @($orderList.SelectNodes("node[@id='Module']"))) {
        $u = $n.SelectSingleNode("attribute[@id='UUID']")
        if ($u -and $ids -contains $u.GetAttribute('value')) { [void]$orderList.RemoveChild($n) }
      }
      foreach ($k in $orderKeys) {
        if (-not $entries[$k]) { continue }
        $n = $x.CreateElement('node'); $n.SetAttribute('id', 'Module')
        $e = $x.CreateElement('attribute'); $e.SetAttribute('id', 'UUID'); $e.SetAttribute('type', 'FixedString'); $e.SetAttribute('value', $entries[$k].UUID)
        [void]$n.AppendChild($e); [void]$orderList.AppendChild($n)
      }
    }
    $after = @($mods.SelectNodes("node[@id='ModuleShortDesc']") | ForEach-Object { $_.SelectSingleNode("attribute[@id='UUID']").GetAttribute('value') })
    $names = (@($orderKeys | Where-Object { $entries[$_] } | ForEach-Object { $entries[$_].Name }) -join ' > ')
    if (($before -join ',') -eq ($after -join ',')) {
      Add-Row 'Load order' 'UP TO DATE' "$names at the end of the list" $null
    } elseif ($WhatIf) {
      Add-Row 'Load order' 'WOULD SET' "$names moved to the end of the list" $null
    } else {
      $backup = Backup-File $loadOrderF
      $item = Get-Item -LiteralPath $loadOrderF
      $ro = $item.IsReadOnly
      if ($ro) { $item.IsReadOnly = $false }
      $ws = New-Object System.Xml.XmlWriterSettings
      $ws.Indent = $true; $ws.IndentChars = '  '; $ws.Encoding = New-Object System.Text.UTF8Encoding $false
      $w = [System.Xml.XmlWriter]::Create($loadOrderF, $ws)
      try { $x.Save($w) } finally { $w.Close() }
      if ($ro) { (Get-Item -LiteralPath $loadOrderF).IsReadOnly = $true }   # it was read-only on purpose: keep it so
      $installed.Add([pscustomobject]@{ Dest = $loadOrderF; Backup = $backup })
      Add-Row 'Load order' 'SET' "$names at the end of the list (your other mods unchanged)" $null
    }
    $missingKeys = @($orderKeys | Where-Object { -not $entries[$_] })
    if ($missingKeys.Count -gt 0) { Add-Row '  load order is missing' 'MISSING' (@($missingKeys | ForEach-Object { $known[$_].Name }) -join ', ') $null }
  } catch {
    Add-Row 'Load order' 'FAILED' "could not update $loadOrderF ($($_.Exception.Message)); set it in BG3 Mod Manager: $orderNames, then Export Order to Game" $null
  }
}

# ---------------------------------------------------------------- 6. undo notes, clean up

if (-not $WhatIf) {
  $lines = @("Dark and Gate installer, $(Get-Date -Format 'yyyy-MM-dd HH:mm')", "Downloads: $Source", "Game: $GameRoot", "",
             "To undo: close the game, then for each line below copy the backup back, or delete the new file.", "")
  foreach ($it in $installed) {
    if ($it.PSObject.Properties['Removed'] -and $it.Removed) { $lines += "MOVED     $($it.Dest)`r`n          (an older copy; put it back from: $($it.Backup))" }
    elseif ($it.Backup) { $lines += "REPLACED  $($it.Dest)`r`n          restore it by copying back: $($it.Backup)" }
    else { $lines += "NEW       $($it.Dest)`r`n          (did not exist before: delete it)" }
  }
  if ($installed.Count -eq 0) { $lines += "(nothing was changed: everything was already up to date)" }
  Write-Utf8 (Join-Path $backupDir 'RESTORE.txt') ($lines -join "`r`n")
}
try { Remove-Item -LiteralPath $staging -Recurse -Force } catch { }

# Windows Security quarantines version.dll now and then (a false positive):
# only checked by whether the file is still there, never opened.
$loaderGone = $false
if (-not $WhatIf -and $pick['loader']) {
  Start-Sleep -Seconds 3
  $loaderGone = -not (Test-Path -LiteralPath $loaderDest)
  if ($loaderGone) { Add-Row "Ch4nKyy's Mod Loader" 'QUARANTINED?' "version.dll was copied but is gone again: Windows Security probably removed it (see below)" $links.loader }
}

# ---------------------------------------------------------------- 7. report

Write-Host ""
Write-Host "Result" -ForegroundColor Cyan
Write-Host ("  {0,-36} {1,-14} {2}" -f 'Item', 'Status', 'Details') -ForegroundColor DarkGray
$problems = New-Object System.Collections.Generic.List[object]
foreach ($r in $rows) {
  if ($goodStatus -contains $r.Status) { $color = 'Green' } elseif ($infoStatus -contains $r.Status) { $color = 'DarkGray' } else { $color = 'Red'; $problems.Add($r) }
  Write-Host ("  {0,-36} " -f $r.Name) -NoNewline
  Write-Host ("{0,-14}" -f $r.Status) -ForegroundColor $color -NoNewline
  Write-Host (" " + $r.Detail)
}
if ($otherPaks.Count -gt 0) { Write-Host ("  Not installed by this script (other mods): " + ($otherPaks -join ', ')) -ForegroundColor DarkGray }
foreach ($f in $failedArchives) {
  $problems.Add([pscustomobject]@{ Name = $f; Status = 'NOT UNPACKED'; Detail = 'right-click it > Extract All (or 7-Zip > Extract here) into this folder, then run INSTALL.bat again'; Link = $null })
}

if ($loaderGone -or $loaderBlocked) {
  Write-Host ""
  Write-Host "Windows Security and version.dll" -ForegroundColor Yellow
  Write-Host "  version.dll (Ch4nKyy's Mod Loader) is a known false positive (Trojan:Win32/Posilod.CA!cl)."
  Write-Host "  Start > type cmd > right-click Command Prompt > Run as administrator, then run these two lines"
  Write-Host "  (the first excludes only these files, the second lists what Windows Security quarantined),"
  Write-Host "  restore it if it is listed, then run INSTALL.bat again:"
  $paths = @($loaderDest, (Join-Path $nativeDir 'DarkAndGate.dll'))
  if ($loaderBlocked) { $paths += $loaderBlocked }
  $list = (@($paths | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',')
  Write-Host "powershell -NoProfile -Command ""Add-MpPreference -ExclusionPath $list""" -ForegroundColor White
  Write-Host """%ProgramFiles%\Windows Defender\MpCmdRun.exe"" -Restore -ListAll" -ForegroundColor White
  Write-Host "  If version.dll is listed, restore it:" -ForegroundColor Yellow
  Write-Host """%ProgramFiles%\Windows Defender\MpCmdRun.exe"" -Restore -Name ""Trojan:Win32/Posilod.CA!cl"" -All" -ForegroundColor White
  Write-Host "  This script never changes Windows Security itself."
}

Write-Host ""
Write-Host " DIRECTX 11 ONLY " -ForegroundColor Black -BackgroundColor Yellow
Write-Host "  Start the game in DirectX 11: in the Larian launcher, the box next to PLAY must say DirectX 11, not Vulkan." -ForegroundColor Yellow

Write-Host ""
if ($WhatIf) {
  Write-Host "Dry run finished: nothing in the game or your settings was changed." -ForegroundColor Magenta
} elseif ($installed.Count -gt 0) {
  Write-Host "Backup of everything replaced + how to undo it: $backupDir" -ForegroundColor DarkGray
} else {
  try { Remove-Item -LiteralPath $backupDir -Recurse -Force } catch { }
}
if ($problems.Count -eq 0) {
  Write-Host " READY " -ForegroundColor Black -BackgroundColor Green -NoNewline
  Write-Host "  Start Baldur's Gate 3 (DirectX 11) and load a game: Dark and Gate turns on by itself."
} else {
  Write-Host " NOT READY " -ForegroundColor White -BackgroundColor Red -NoNewline
  Write-Host "  Still to do:"
  foreach ($p in $problems) {
    Write-Host ("   - {0}: {1}" -f $p.Name.Trim(), $p.Detail) -ForegroundColor Red
    if ($p.Link) { Write-Host ("     download: {0} (put it in {1} and run INSTALL.bat again)" -f $p.Link, $Source) -ForegroundColor Cyan }
  }
  exit 1
}
