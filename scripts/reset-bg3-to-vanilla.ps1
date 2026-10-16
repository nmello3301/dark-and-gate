<#
.SYNOPSIS
  Puts Baldur's Gate 3 back to a clean, unmodded state.

.DESCRIPTION
  Nothing is deleted. Every leftover mod file is MOVED into a dated
  "BG3 mod backup" folder on your Desktop, and your saves are COPIED there first.

  Run it once without -Apply to preview what would move, then with -Apply.
  Afterwards, run Steam's "Verify integrity of game files" for Baldur's Gate 3.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\reset-bg3-to-vanilla.ps1
  powershell -ExecutionPolicy Bypass -File .\scripts\reset-bg3-to-vanilla.ps1 -Apply
#>
param(
  [switch]$Apply,
  [string]$GameDir = "C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3"
)

$ErrorActionPreference = 'Stop'
$larian = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3"
$bin    = Join-Path $GameDir 'bin'

if (-not (Test-Path -LiteralPath $GameDir)) { throw "Game folder not found: $GameDir (pass -GameDir if it's elsewhere)" }
if (Get-Process -Name bg3, bg3_dx11, Vortex -ErrorAction SilentlyContinue) {
  throw "Close Baldur's Gate 3 and Vortex first, then run this again."
}

$moves = [System.Collections.Generic.List[object]]::new()
function Add-Move([string]$Path, [string]$Label) {
  if (Test-Path -LiteralPath $Path) { $moves.Add([pscustomobject]@{ Path = $Path; Label = $Label }) }
}

# 1. Mod paks and load order (outside the game folder)
Get-ChildItem -LiteralPath (Join-Path $larian 'Mods') -Force -ErrorAction SilentlyContinue |
  ForEach-Object { Add-Move $_.FullName 'AppData\Mods' }
Add-Move (Join-Path $larian 'PlayerProfiles\Public\modsettings.lsx')        'AppData\PlayerProfiles'
Add-Move (Join-Path $larian 'PlayerProfiles\Public\modsettings.lsx.backup') 'AppData\PlayerProfiles'
Add-Move (Join-Path $larian 'Public\modsettings.lsx')                       'AppData\Public'
Add-Move (Join-Path $larian 'Script Extender')                              'AppData'

# 2. Files left in the game folder by Vortex, the old Script Extender and Native Mod Loader
Add-Move (Join-Path $GameDir 'vortex.deployment.dinput.json') 'Game'
Add-Move (Join-Path $GameDir 'Data\Mods')                     'Game\Data'
foreach ($name in 'DWrite.dll', 'version.dll', 'ScriptExtenderSettings.json', 'NativeMods', 'NativeModLoader.log',
                  'bink2w64_original.dll', 'bink2w64.dll.vortex_backup',
                  'bg3.exe.backup', 'bg3_dx11.exe.backup', 'steam_appid.txt') {
  Add-Move (Join-Path $bin $name) 'Game\bin'
}

if ($moves.Count -eq 0) { Write-Host "Nothing to clean: Baldur's Gate 3 already looks unmodded." -ForegroundColor Green; return }

$stamp  = Get-Date -Format 'yyyy-MM-dd_HHmm'
$backup = Join-Path ([Environment]::GetFolderPath('Desktop')) "BG3 mod backup $stamp"

Write-Host "`nThese $($moves.Count) items will be moved to:`n  $backup`n" -ForegroundColor Cyan
$moves | ForEach-Object { Write-Host ("  [{0}] {1}" -f $_.Label, $_.Path) }

if (-not $Apply) {
  Write-Host "`nPreview only. Nothing was changed. Run again with -Apply to move them." -ForegroundColor Yellow
  return
}

New-Item -ItemType Directory -Force -Path $backup | Out-Null

# Copy saves first, just in case
$saves = Join-Path $larian 'PlayerProfiles\Public\Savegames'
if (Test-Path -LiteralPath $saves) {
  Write-Host "`nCopying saves to the backup (this can take a minute)..."
  Copy-Item -LiteralPath $saves -Destination (Join-Path $backup 'Savegames (copy)') -Recurse
}

$failed = 0
foreach ($m in $moves) {
  $dest = Join-Path $backup $m.Label
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  try {
    Move-Item -LiteralPath $m.Path -Destination $dest
    Write-Host "  moved   $($m.Path)" -ForegroundColor DarkGray
  } catch {
    $failed++
    Write-Host "  FAILED  $($m.Path): $($_.Exception.Message)" -ForegroundColor Red
  }
}

if ($failed) {
  Write-Host "`n$failed item(s) could not be moved. If it says access denied, rerun PowerShell as administrator." -ForegroundColor Red
} else {
  Write-Host "`nDone. Everything is in: $backup" -ForegroundColor Green
}
Write-Host @"

Next:
  1. Steam > Baldur's Gate 3 > Properties > Installed Files > Verify integrity of game files.
  2. Launch the game once with no mods; you should reach the main menu with no error.
"@
