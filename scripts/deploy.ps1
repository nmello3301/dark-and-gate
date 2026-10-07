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

  For pure Lua changes, you do not need to redeploy: open the SE console in
  game and type "reset" to reload the Lua VM.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\deploy.ps1
#>
param(
  [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
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
if (Get-Process -Name bg3, bg3_dx11 -ErrorAction SilentlyContinue) {
  throw "Close Baldur's Gate 3 before deploying."
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

Already active? You are done — just launch the game.

For Lua-only changes you do not need to redeploy; open the SE console in game
and type:  reset
"@
