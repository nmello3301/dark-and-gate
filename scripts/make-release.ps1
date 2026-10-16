<#
.SYNOPSIS
  Build the public release files for Nexus Mods (docs/nexus/upload-sheet.md).

.DESCRIPTION
  Reads the repo (and, read-only, the host's install for a settings check) and
  writes to build\release\:

    DarkAndGate-<ver>-mod.zip                   main file 1: BG3 Mod Manager / Vortex
      DarkAndGate.pak                           build\DarkAndGate.pak (scripts\deploy.ps1)
      info.json                                 generated from meta.lsx + the pak's MD5
      README.md, CHANGELOG.md, LICENSE, NOTICE

    DarkAndGate-<ver>-native.zip                main file 2: extract into the game folder
      bin/NativeMods/DarkAndGate.dll            tools\native\out\build\Release\DarkAndGate.dll
      bin/NativeMods/DarkAndGate-README.md, -LICENSE.txt, -NOTICE.txt

    DarkAndGate-<ver>-recommended-settings.zip  optional file: extract into the game folder
      bin/NativeMods/BG3NativeCameraTweaks.toml config\native\
      bin/NativeMods/BG3WASD.toml               config\native\

    DarkAndGate-<ver>-installer.zip             optional file: INSTALL.bat + install.ps1 +
                                                README.txt; installs the prerequisites and the
                                                mod from a folder of downloads

    DarkAndGate-<ver>-SHA256.txt                hashes for the release notes and the
                                                Microsoft submission (docs/release.md)

  <ver> is meta.lsx's version. Unlike scripts\make-friend-package.ps1, nothing
  from the host's own setup ships (load order, Script Extender settings), and
  no installer: players install by hand (DECISIONS 2026-10-15).

  Stops when the release wouldn't match a commit: uncommitted changes, a pak
  or DLL older than its source, or a pak / DLL stamped "+dirty" or built from
  a commit whose mod/ or tools/native/ differs from HEAD.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\make-release.ps1
#>
param(
  [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
  [string]$BG3Install  = "C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3",
  [string]$OutDir      = "",
  # Package anyway when a check fails (for a dry run; never upload the result).
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (-not $OutDir) { $OutDir = Join-Path $ProjectRoot 'build\release' }
$meta       = Join-Path $ProjectRoot 'mod\DarkAndGate\Mods\DarkAndGate\meta.lsx'
$pak        = Join-Path $ProjectRoot 'build\DarkAndGate.pak'
$dll        = Join-Path $ProjectRoot 'tools\native\out\build\Release\DarkAndGate.dll'
$buildInfo  = Join-Path $ProjectRoot 'mod\DarkAndGate\Mods\DarkAndGate\ScriptExtender\Lua\Shared\BuildInfo.lua'
$readmeSrc  = Join-Path $ProjectRoot 'scripts\release\README.md'
$repoConfig = Join-Path $ProjectRoot 'config\native'
$hostNative = Join-Path $BG3Install 'bin\NativeMods'

$problems = New-Object System.Collections.Generic.List[string]
function Problem([string]$msg) { $problems.Add($msg); Write-Host "PROBLEM: $msg" -ForegroundColor Red }
function Warn([string]$msg) { Write-Host "WARNING: $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------- helpers

function Get-Sha([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }

function Invoke-Git([string[]]$gitArgs) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & git -C $ProjectRoot @gitArgs 2>$null } finally { $ErrorActionPreference = $old }
  return $o
}

# True when <path> differs between <sha> and HEAD (or the sha is unknown).
function Test-ChangedSince([string]$sha, [string]$path) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & git -C $ProjectRoot diff --quiet $sha HEAD -- $path 2>$null; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $old }
  return $code -ne 0
}

function Write-Utf8([string]$path, [string]$text) {
  [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
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

# ---------------------------------------------------------------- 1. inputs + version

foreach ($p in @($meta, $pak, $dll, $readmeSrc, (Join-Path $ProjectRoot 'LICENSE'), (Join-Path $ProjectRoot 'NOTICE'), (Join-Path $ProjectRoot 'CHANGELOG.md'))) {
  if (-not (Test-Path -LiteralPath $p)) { throw "Missing: $p. Pack the mod with scripts\deploy.ps1 and build the DLL with scripts\pov-build-deploy.ps1 first." }
}

[xml]$mx = Get-Content -LiteralPath $meta -Raw
function Get-MetaAttr([string]$id) {
  $n = $mx.SelectSingleNode("//node[@id='ModuleInfo']/attribute[@id='$id']")
  if ($n) { return $n.GetAttribute('value') } else { return $null }
}
$v64 = [int64](Get-MetaAttr 'Version64')
$verParts = @(($v64 -shr 55), (($v64 -shr 47) -band 0xFF), (($v64 -shr 31) -band 0xFFFF), ($v64 -band 0x7FFFFFFF))
$version = "{0}.{1}.{2}" -f $verParts[0], $verParts[1], $verParts[2]
if ($verParts[3] -ne 0) { $version += ".$($verParts[3])" }
$modName = Get-MetaAttr 'Name'
$folder  = Get-MetaAttr 'Folder'
$uuid    = Get-MetaAttr 'UUID'
$author  = Get-MetaAttr 'Author'
$desc    = Get-MetaAttr 'Description'
Write-Host "Release $modName $version ($uuid)"

# ---------------------------------------------------------------- 2. the build matches a commit

$head = "$(Invoke-Git @('rev-parse', '--short', 'HEAD'))".Trim()
if (-not $head) { throw "git rev-parse failed: is $ProjectRoot a git repo?" }
if (Invoke-Git @('status', '--porcelain', '--untracked-files=no')) {
  Problem "Uncommitted changes. Commit them, re-pack (scripts\deploy.ps1) and run this again."
}

$modBuild = $null; $modSha = $null
if (Test-Path -LiteralPath $buildInfo) {
  $m = [regex]::Match((Get-Content -LiteralPath $buildInfo -Raw), 'mod_build\s*=\s*"(([0-9a-f]{7,12}|nogit)(\+dirty)?-[^"]+)"')
  if ($m.Success) { $modBuild = $m.Groups[1].Value; $modSha = $m.Groups[2].Value }
}
if (-not $modBuild) { Problem "Shared\BuildInfo.lua has no mod_build stamp: re-pack with scripts\deploy.ps1." }
elseif ($modBuild -match '\+dirty') { Problem "The pak was packed from uncommitted changes ($modBuild): commit, then re-pack." }
elseif (Test-ChangedSince $modSha 'mod') { Problem "The pak was packed at $modSha, but mod\ changed since: re-pack with scripts\deploy.ps1." }

$pakItem = Get-Item -LiteralPath $pak
$newestSrc = Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'mod') -Recurse -File |
  Where-Object { $_.Name -ne 'BuildInfo.lua' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($newestSrc -and $newestSrc.LastWriteTime -gt $pakItem.LastWriteTime.AddSeconds(5)) {
  Problem ("The pak is older than {0} (pak {1:yyyy-MM-dd HH:mm}, file {2:yyyy-MM-dd HH:mm}): re-pack with scripts\deploy.ps1." -f
           $newestSrc.FullName.Substring($ProjectRoot.Length + 1), $pakItem.LastWriteTime, $newestSrc.LastWriteTime)
}

# The DLL's compiled-in stamp (cmake\BuildInfo.cmake: "<git>[+dirty]-<UTC>").
$dllItem = Get-Item -LiteralPath $dll
$dllText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($dll))
$m = [regex]::Match($dllText, '(nogit|[0-9a-f]{7,12})(\+dirty)?-\d{8}T\d{6}Z')
$dllBuild = $null
if (-not $m.Success) { Problem "No build stamp found in DarkAndGate.dll: rebuild it." }
else {
  $dllBuild = $m.Value
  if ($m.Groups[2].Success) { Problem "The DLL was built from uncommitted changes ($dllBuild): commit, then rebuild." }
  elseif (Test-ChangedSince $m.Groups[1].Value 'tools/native') { Problem "The DLL was built at $($m.Groups[1].Value), but tools\native changed since: rebuild it." }
}
$nativeSrc = Join-Path $ProjectRoot 'tools\native\src'
$newestCpp = Get-ChildItem -LiteralPath $nativeSrc -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($newestCpp -and $newestCpp.LastWriteTime -gt $dllItem.LastWriteTime.AddSeconds(5)) {
  Problem ("The DLL is older than {0}: rebuild it." -f $newestCpp.FullName.Substring($ProjectRoot.Length + 1))
}
$dllVer = $dllItem.VersionInfo.ProductVersion
if ($dllVer -and -not $dllVer.StartsWith($version)) {
  Problem "DarkAndGate.dll says version $dllVer, meta.lsx says ${version}: set project(VERSION) in tools\native\CMakeLists.txt to match and rebuild."
}

if ($problems.Count -gt 0) {
  if (-not $Force) { throw "$($problems.Count) problem(s) above: nothing packaged." }
  Warn "-Force: packaging anyway. Don't upload these files."
}

# The settings we test with: config\native is the source; warn when the
# developer's live copies have drifted from it.
foreach ($name in 'BG3NativeCameraTweaks.toml', 'BG3WASD.toml') {
  $repo = Join-Path $repoConfig $name
  $live = Join-Path $hostNative $name
  if (-not (Test-Path -LiteralPath $repo)) { throw "Missing config\native\$name" }
  if ((Test-Path -LiteralPath $live) -and (Get-Sha $live) -ne (Get-Sha $repo)) {
    Warn "Your installed bin\NativeMods\$name differs from config\native\$name; the release ships the repo copy. Copy yours into config\native and commit if yours is the one to ship."
  }
}

# ---------------------------------------------------------------- 3. stage + zip

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$readme = (Get-Content -LiteralPath $readmeSrc -Raw) -replace '\{\{VERSION\}\}', $version
$base = "DarkAndGate-$version"
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("dag-release-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$zips = @()
try {
  # Main file 1: the pak, with the info.json BG3 Mod Manager reads on import.
  $s = Join-Path $tmp 'mod'
  New-Item -ItemType Directory -Force -Path $s | Out-Null
  Copy-Item -LiteralPath $pak -Destination (Join-Path $s 'DarkAndGate.pak')
  $md5 = (Get-FileHash -LiteralPath $pak -Algorithm MD5).Hash.ToLowerInvariant()
  $info = [ordered]@{
    Mods = @([ordered]@{
      Author = $author; Name = $modName; Folder = $folder; Version = "$v64"; Description = $desc
      UUID = $uuid; Created = $pakItem.LastWriteTime.ToString('o'); Dependencies = @(); Group = $uuid
    })
    MD5 = $md5
  }
  Write-Utf8 (Join-Path $s 'info.json') ($info | ConvertTo-Json -Depth 5 -Compress)
  Write-Utf8 (Join-Path $s 'README.md') $readme
  foreach ($f in 'CHANGELOG.md', 'LICENSE', 'NOTICE') { Copy-Item -LiteralPath (Join-Path $ProjectRoot $f) -Destination (Join-Path $s $f) }
  $zips += Join-Path $OutDir "$base-mod.zip"
  New-ZipFromFolder $s $zips[-1]

  # Main file 2: the DLL, laid out from the game folder. Its texts carry a
  # DarkAndGate- prefix because they land in bin\NativeMods beside other mods.
  $s = Join-Path $tmp 'native'
  $nm = Join-Path $s 'bin\NativeMods'
  New-Item -ItemType Directory -Force -Path $nm | Out-Null
  Copy-Item -LiteralPath $dll -Destination (Join-Path $nm 'DarkAndGate.dll')
  Write-Utf8 (Join-Path $nm 'DarkAndGate-README.md') $readme
  Copy-Item -LiteralPath (Join-Path $ProjectRoot 'LICENSE') -Destination (Join-Path $nm 'DarkAndGate-LICENSE.txt')
  Copy-Item -LiteralPath (Join-Path $ProjectRoot 'NOTICE') -Destination (Join-Path $nm 'DarkAndGate-NOTICE.txt')
  $zips += Join-Path $OutDir "$base-native.zip"
  New-ZipFromFolder $s $zips[-1]

  # Optional file: our Native Camera Tweaks + WASD settings.
  $s = Join-Path $tmp 'settings'
  $nm = Join-Path $s 'bin\NativeMods'
  New-Item -ItemType Directory -Force -Path $nm | Out-Null
  foreach ($name in 'BG3NativeCameraTweaks.toml', 'BG3WASD.toml') { Copy-Item -LiteralPath (Join-Path $repoConfig $name) -Destination (Join-Path $nm $name) }
  $zips += Join-Path $OutDir "$base-recommended-settings.zip"
  New-ZipFromFolder $s $zips[-1]

  # Optional file: the one-click installer (scripts\release\installer): put
  # it next to the downloads, run INSTALL.bat (developer 2026-10-16).
  $s = Join-Path $tmp 'installer'
  New-Item -ItemType Directory -Force -Path $s | Out-Null
  foreach ($name in 'INSTALL.bat', 'install.ps1', 'README.txt') { Copy-Item -LiteralPath (Join-Path $ProjectRoot "scripts\release\installer\$name") -Destination (Join-Path $s $name) }
  $zips += Join-Path $OutDir "$base-installer.zip"
  New-ZipFromFolder $s $zips[-1]
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 4. hashes + report

$lines = @("$modName $version  (git $head, mod_build $modBuild, dll_build $dllBuild)", "")
foreach ($f in @($pak, $dll) + $zips) {
  $lines += "{0}  {1}" -f (Get-Sha $f), (Split-Path -Leaf $f)
}
$shaFile = Join-Path $OutDir "$base-SHA256.txt"
Write-Utf8 $shaFile (($lines -join "`r`n") + "`r`n")

Write-Host ""
Write-Host "Release files in ${OutDir}:" -ForegroundColor Green
foreach ($z in $zips) { Write-Host ("  {0}  ({1:N0} bytes)" -f (Split-Path -Leaf $z), (Get-Item -LiteralPath $z).Length) }
Write-Host "  $(Split-Path -Leaf $shaFile)"
Write-Host "  mod_build $modBuild   dll_build $dllBuild"
Write-Host "Next: docs/nexus/upload-sheet.md"
