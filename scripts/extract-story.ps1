# Pulls the game's compiled Osiris story out of Shared.pak so we have a raw
# copy to open in LSLib's Osiris Debugger. Divine.exe's CLI can't decompile
# an .osi directly, but it can extract one file from a pak, which is enough
# to seed docs/osiris-functions.md.
#
# Usage:
#   .\scripts\extract-story.ps1
#
# Output: tools/extracted-story/Mods/Shared/Story/story.div.osi
#         plus docs/osiris-functions.md if LSLib's console tool is available.

$ErrorActionPreference = "Stop"

$Root    = Split-Path $PSScriptRoot -Parent
$Divine  = Join-Path $Root "tools\lslib\Packed\Tools\Divine.exe"
$Shared  = "C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3\Data\Shared.pak"
$OutDir  = Join-Path $Root "tools\extracted-story"
$DocFile = Join-Path $Root "docs\osiris-functions.md"

if (-not (Test-Path $Divine)) { throw "Divine.exe not at $Divine" }
if (-not (Test-Path $Shared)) { throw "Shared.pak not at $Shared" }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host "Extracting story.div.osi from Shared.pak ..."
& $Divine -g bg3 -a extract-single-file `
    -s $Shared `
    -d (Join-Path $OutDir "story.div.osi") `
    -f "Mods/Shared/Story/story.div.osi"

if ($LASTEXITCODE -ne 0) {
    Write-Warning "extract-single-file failed; try extract-package into $OutDir and search for story.div.osi"
    exit $LASTEXITCODE
}

Write-Host "OK. Open the result in LSLib's Osiris Debugger to see the full function list."
Write-Host "Runtime list via SE: load DEV-SAVE, console 'server' then '!dag_osidump'."
Write-Host "Live list ends up at %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\DarkAndGate\osiris-functions.txt."
