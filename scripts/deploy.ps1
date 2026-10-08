<#
.SYNOPSIS
  Pack the DarkAndGate mod with divine.exe and install the .pak into BG3's
  Mods folder.

.DESCRIPTION
  Packs   mod\DarkAndGate\  into   build\DarkAndGate.pak   using LSLib's divine.exe,
  then copies the result into:
    %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods\DarkAndGate.pak

  Afterwards, the mod still needs to be enabled once in BG3 Mod Manager and the
  load order exported. Re-running deploy.ps1 only replaces the .pak, so you do
  this just once.

  Lua changes require re-running this script and reloading, because SE reads
  mod Lua out of the installed .pak via the mod GUID. Loose files in
  <GameDir>\Data\Mods\<Folder>\ do NOT override the pak once the mod is
  registered through modsettings.lsx -- verified 2026-10-08. See the note
  in docs\se-api-notes.md.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\deploy.ps1
#>
param(
  [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
  # -NoWait: fail immediately if BG3 is running (old behaviour, keep for CI).
  # Default: poll every 2s, up to 5 minutes, until BG3 exits. The pak is
  # file-locked while BG3 holds it open, so there's no point in doing anything
  # else -- waiting is strictly nicer than throwing and asking the dev to rerun.
  [switch]$NoWait
)

$ErrorActionPreference = 'Stop'

$modSource = Join-Path $ProjectRoot "mod\DarkAndGate"
$buildDir  = Join-Path $ProjectRoot "build"
$pakOut    = Join-Path $buildDir "DarkAndGate.pak"
$divine    = Join-Path $ProjectRoot "tools\lslib\Packed\Tools\Divine.exe"

$modsFolder = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Mods"
$installedPak = Join-Path $modsFolder "DarkAndGate.pak"

if (-not (Test-Path -LiteralPath $divine))    { throw "divine.exe not found at: $divine" }
if (-not (Test-Path -LiteralPath $modSource)) { throw "Mod source folder not found: $modSource" }

$bg3Running = { Get-Process -Name bg3, bg3_dx11 -ErrorAction SilentlyContinue }
if (& $bg3Running) {
  if ($NoWait) {
    throw "Close Baldur's Gate 3 before deploying. (-NoWait set.)"
  }
  Write-Host "Baldur's Gate 3 is running. Waiting for it to close (Ctrl-C to abort)..." -ForegroundColor Yellow
  $deadline = (Get-Date).AddMinutes(5)
  while (& $bg3Running) {
    if ((Get-Date) -gt $deadline) {
      throw "BG3 still running after 5 min. Giving up -- close it and retry."
    }
    Start-Sleep -Seconds 2
  }
  Write-Host "BG3 closed. Packing now." -ForegroundColor Green
}

New-Item -ItemType Directory -Force -Path $buildDir   | Out-Null
New-Item -ItemType Directory -Force -Path $modsFolder | Out-Null

Write-Host "Packing $modSource -> $pakOut" -ForegroundColor Cyan
& $divine --game bg3 --action create-package --source $modSource --destination $pakOut --loglevel warn
if ($LASTEXITCODE -ne 0) { throw "divine.exe exited with code $LASTEXITCODE" }

Write-Host "Installing to $installedPak" -ForegroundColor Cyan
Copy-Item -LiteralPath $pakOut -Destination $installedPak -Force

Write-Host "`nDone." -ForegroundColor Green
Write-Host @"

First run only:
  1. Open BG3 Mod Manager (BG3ModManager_Latest\BG3ModManager.exe).
  2. Refresh. "DarkAndGate" should appear in the Inactive list.
  3. Drag it into the Active list.
  4. File > Save Load Order to File  (or press the Export button).
  5. Launch Baldur's Gate 3.

Already active? You are done - just launch the game.
"@
