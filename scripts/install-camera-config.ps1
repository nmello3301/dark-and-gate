<#
.SYNOPSIS
  Install Dark and Gate's Native Camera Tweaks config into the game.

.DESCRIPTION
  Copies config\native\BG3NativeCameraTweaks.toml to
  <BG3 install>\bin\NativeMods\BG3NativeCameraTweaks.toml, backing up the
  previous file to .bak so we never permanently clobber a custom config.

  NCT ships with WatchForConfigChanges = true, so if the game is running,
  the camera reloads the new settings as soon as the file lands. No restart.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\install-camera-config.ps1
#>

param(
    [string]$BG3Install = "C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3"
)

$ErrorActionPreference = 'Stop'

$src = Join-Path $PSScriptRoot "..\config\native\BG3NativeCameraTweaks.toml"
$src = (Resolve-Path -LiteralPath $src).Path
$dstDir = Join-Path $BG3Install "bin\NativeMods"
$dst = Join-Path $dstDir "BG3NativeCameraTweaks.toml"

if (-not (Test-Path -LiteralPath $src))    { throw "Source not found: $src" }
if (-not (Test-Path -LiteralPath $dstDir)) { throw "NativeMods folder not found: $dstDir (is Native Camera Tweaks installed?)" }

if (Test-Path -LiteralPath $dst) {
    $bak = "$dst.bak"
    Write-Host "Backing up existing config to $bak" -ForegroundColor DarkGray
    Copy-Item -LiteralPath $dst -Destination $bak -Force
}

Copy-Item -LiteralPath $src -Destination $dst -Force
Write-Host "Installed camera config:" -ForegroundColor Green
Write-Host "  $src -> $dst"
Write-Host "If BG3 is running with WatchForConfigChanges = true, it has already picked up the new values."
