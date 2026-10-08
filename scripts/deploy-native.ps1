<#
.SYNOPSIS
  Deploy DarkAndGate.dll into BG3's NativeMods folder, verifying the
  installed DLL's SHA-256 matches the build output.

.DESCRIPTION
  Copies tools\native\out\build\Release\DarkAndGate.dll into
  <BG3 install>\bin\NativeMods\DarkAndGate.dll and verifies the hashes
  match after the copy. Fails loudly if the installed file is older or
  different — catches the "built but forgot to copy" and "copied the
  wrong build" classes of mistake.

  Does NOT build. Run cmake --build out\build --config Release in
  tools\native first (or use VS).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\deploy-native.ps1
#>
param(
  [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
  [string]$BG3Install  = "C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3"
)

$ErrorActionPreference = 'Stop'

$built     = Join-Path $ProjectRoot "tools\native\out\build\Release\DarkAndGate.dll"
$nativeDir = Join-Path $BG3Install  "bin\NativeMods"
$installed = Join-Path $nativeDir   "DarkAndGate.dll"

if (-not (Test-Path -LiteralPath $built)) {
  throw "Build output not found at: $built`nBuild first: cmake --build tools\native\out\build --config Release"
}
if (-not (Test-Path -LiteralPath $nativeDir)) {
  throw "NativeMods folder not found at: $nativeDir`nIs Ch4nKyy's Mod Loader installed (bin\version.dll)?"
}

# Refuse to clobber while BG3 is running — the OS will error anyway, but
# the message is nicer here.
if (Get-Process -Name bg3, bg3_dx11 -ErrorAction SilentlyContinue) {
  throw "Baldur's Gate 3 is running. Close it before deploying the DLL."
}

$builtHash = (Get-FileHash -LiteralPath $built -Algorithm SHA256).Hash
Write-Host "Build  : $built"
Write-Host "  SHA256: $builtHash"

if (Test-Path -LiteralPath $installed) {
  $preHash = (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash
  Write-Host "Pre    : $installed"
  Write-Host "  SHA256: $preHash"
  if ($preHash -eq $builtHash) {
    Write-Host "Already up to date." -ForegroundColor Green
    exit 0
  }
}

Copy-Item -LiteralPath $built -Destination $installed -Force

$postHash = (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash
Write-Host "Post   : $installed"
Write-Host "  SHA256: $postHash"

if ($postHash -ne $builtHash) {
  throw "Hash mismatch after copy: expected $builtHash, got $postHash. Copy failed or the file was replaced mid-operation."
}

Write-Host "Deployed DarkAndGate.dll (hashes match)." -ForegroundColor Green
