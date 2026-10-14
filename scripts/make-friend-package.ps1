<#
.SYNOPSIS
  Build the zip a friend needs to join a Dark and Gate co-op playtest.

.DESCRIPTION
  Reads the repo and the host's own install (read-only) and writes
    <Desktop>\DarkAndGate-friend-<git sha>[-dirty].zip
  containing:
    DarkAndGate.pak                    build\DarkAndGate.pak (scripts\deploy.ps1)
    NativeMods\DarkAndGate.dll         tools\native\out\build\Release\DarkAndGate.dll
    NativeMods\BG3WASD.toml            the host's bin\NativeMods copy (our movement config)
    NativeMods\BG3NativeCameraTweaks.toml  the host's copy (scripts\install-camera-config.ps1)
    ScriptExtenderSettings.json        the host's bin copy (console + logging on); install.ps1
                                       puts it in the friend's bin after a backup
    host-modsettings.lsx               the host's load order file; install.ps1 copies it over
                                       the friend's (after a backup) when the orders differ
    INSTALL.bat, install.ps1           scripts\friend\
    COLLECT-LOGS.bat, mp-collect-logs.ps1
    FRIEND-README.md                   scripts\friend\, with the host's live load order filled in
    manifest.json                      git sha, build stamps, hashes, expected third-party
                                       versions, the host's active mods

  No third-party DLL or pak is ever bundled: the manifest only records their
  versions / fingerprints so install.ps1 can check the friend's copies.

  The friend must run exactly the host's build (the MP version handshake
  compares mod_build and dll_build), so this script warns when the built
  pak / DLL differ from what the host's game has installed.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\make-friend-package.ps1
#>
param(
  [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
  [string]$BG3Install  = "C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3",
  [string]$OutDir      = [Environment]::GetFolderPath('Desktop')
)

$ErrorActionPreference = 'Stop'

$larian      = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3"
$bin         = Join-Path $BG3Install 'bin'
$hostNative  = Join-Path $bin 'NativeMods'
$hostMods    = Join-Path $larian 'Mods'
$hostLoad    = Join-Path $larian 'PlayerProfiles\Public\modsettings.lsx'
$pak         = Join-Path $ProjectRoot 'build\DarkAndGate.pak'
$dll         = Join-Path $ProjectRoot 'tools\native\out\build\Release\DarkAndGate.dll'
$friendDir   = Join-Path $ProjectRoot 'scripts\friend'
$collector   = Join-Path $ProjectRoot 'scripts\mp-collect-logs.ps1'
$buildInfo   = Join-Path $ProjectRoot 'mod\DarkAndGate\Mods\DarkAndGate\ScriptExtender\Lua\Shared\BuildInfo.lua'
$repoConfig  = Join-Path $ProjectRoot 'config\native'

$warnings = New-Object System.Collections.Generic.List[string]
function Warn([string]$msg) { $warnings.Add($msg); Write-Host "WARNING: $msg" -ForegroundColor Yellow }

# ---------------------------------------------------------------- helpers

function Get-Sha([string]$path) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }

function Get-Ver3([string]$v) {
  if (-not $v) { return $null }
  $parts = @(($v -replace '[^\d\.]', '').Split('.') | Where-Object { $_ -ne '' })
  if ($parts.Count -eq 0) { return $null }
  return (($parts | Select-Object -First 3) -join '.')
}

# Size + version info (+ SHA256) of one file, or $null when it isn't there.
#   -SizeOnly: never open the file. Windows Defender's cloud check flags
#     Ch4nKyy's loader (version.dll) as "Trojan:Win32/Posilod.CA!cl" the
#     moment a script reads it (seen 2026-10-13), so we only stat it.
#   DLLs are hashed only when they have no version info (the fallback
#   fingerprint); paks are always hashed.
function Get-Fingerprint([string]$path, [switch]$SizeOnly) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  $item = Get-Item -LiteralPath $path
  $fp = [ordered]@{ file = $item.Name; size = $item.Length; sha256 = $null; product_name = $null; file_version = $null; product_version = $null }
  if ($SizeOnly) { return $fp }
  $vi = $null
  if ($item.Extension -eq '.dll') { try { $vi = $item.VersionInfo } catch { } }
  if ($vi) {
    if ($vi.ProductName)    { $fp.product_name    = $vi.ProductName.Trim() }
    if ($vi.FileVersion)    { $fp.file_version    = $vi.FileVersion.Trim() }
    if ($vi.ProductVersion) { $fp.product_version = $vi.ProductVersion.Trim() }
  }
  if ($item.Extension -ne '.dll' -or -not $fp.file_version) {
    try { $fp.sha256 = Get-Sha $path } catch { $fp.sha256 = $null; Warn "Could not read $path ($($_.Exception.Message)). If Windows Security flagged it, see Protection history." }
  }
  return $fp
}

# modsettings.lsx Version64 (or the old 32-bit Version) -> "major.minor.revision.build"
function Convert-ModVersion([string]$v64, [string]$v32) {
  if ($v64) {
    $v = [int64]$v64
    return "{0}.{1}.{2}.{3}" -f ($v -shr 55), (($v -shr 47) -band 0xFF), (($v -shr 31) -band 0xFFFF), ($v -band 0x7FFFFFFF)
  }
  if ($v32) {
    $v = [int64]$v32
    return "{0}.{1}.{2}.{3}" -f ($v -shr 28), (($v -shr 24) -band 0xF), (($v -shr 16) -band 0xFF), ($v -band 0xFFFF)
  }
  return $null
}

# Active mods from a modsettings.lsx, in load order, without the base game.
function Read-LoadOrder([string]$path) {
  $out = @()
  if (-not (Test-Path -LiteralPath $path)) { return $out }
  [xml]$x = Get-Content -LiteralPath $path -Raw
  $i = 0
  foreach ($n in $x.SelectNodes("//node[@id='Mods']/children/node[@id='ModuleShortDesc']")) {
    $a = @{}
    foreach ($att in $n.SelectNodes("attribute")) { $a[$att.GetAttribute('id')] = $att.GetAttribute('value') }
    if ($a['Folder'] -match '^Gustav(X|Dev)?$') { continue }   # the base game, not a mod
    $i++
    $out += [ordered]@{ order = $i; name = $a['Name']; folder = $a['Folder']; uuid = $a['UUID']; version = (Convert-ModVersion $a['Version64'] $a['Version']) }
  }
  return $out
}

function Invoke-Git([string[]]$gitArgs) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & git -C $ProjectRoot @gitArgs 2>$null } finally { $ErrorActionPreference = $old }
  return $o
}

function Write-Ascii([string]$path, [string]$text) {
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

# ---------------------------------------------------------------- 1. required inputs

if (-not (Test-Path -LiteralPath $pak)) {
  throw "build\DarkAndGate.pak is missing ($pak). Pack it first: scripts\deploy.ps1 (or scripts\pov-build-deploy.ps1)."
}
if (-not (Test-Path -LiteralPath $dll)) {
  throw "DarkAndGate.dll is missing ($dll). Build it first: cmake --build tools\native\out\build --config Release (or scripts\pov-build-deploy.ps1)."
}
foreach ($f in 'INSTALL.bat', 'install.ps1', 'COLLECT-LOGS.bat', 'FRIEND-README.md') {
  if (-not (Test-Path -LiteralPath (Join-Path $friendDir $f))) { throw "Missing package source file: scripts\friend\$f" }
}
if (-not (Test-Path -LiteralPath $collector)) { throw "Missing package source file: scripts\mp-collect-logs.ps1" }

# ---------------------------------------------------------------- 2. git + build stamps

$gitSha = "nogit"; $gitDirty = $false
if (Get-Command git -ErrorAction SilentlyContinue) {
  $h = Invoke-Git @('rev-parse', '--short', 'HEAD')
  if ($h) { $gitSha = "$h".Trim() }
  $st = Invoke-Git @('status', '--porcelain', '--untracked-files=no')   # same rule as deploy.ps1's "+dirty"
  $gitDirty = [bool]$st
} else {
  Warn "git not found; the package is named 'nogit'."
}
$tag = $gitSha + $(if ($gitDirty) { '-dirty' } else { '' })

$modBuild = $null
if (Test-Path -LiteralPath $buildInfo) {
  $m = [regex]::Match((Get-Content -LiteralPath $buildInfo -Raw), 'mod_build\s*=\s*"([^"]+)"')
  if ($m.Success) { $modBuild = $m.Groups[1].Value }
  $biAge = ((Get-Item -LiteralPath $buildInfo).LastWriteTime - (Get-Item -LiteralPath $pak).LastWriteTime).TotalMinutes
  if ($biAge -gt 2) { Warn "Shared\BuildInfo.lua is newer than the pak by $([int]$biAge) min: the pak may carry an older mod_build than $modBuild." }
} else {
  Warn "Shared\BuildInfo.lua not found: mod_build unknown (deploy.ps1 writes it when it packs)."
}

# The DLL's compiled-in stamp (cmake\BuildInfo.cmake: "<git>[+dirty]-<UTC>").
$dllBuild = $null
$dllText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($dll))
$m = [regex]::Match($dllText, '(nogit|[0-9a-f]{7,12})(\+dirty)?-\d{8}T\d{6}Z')
if ($m.Success) { $dllBuild = $m.Value }

# ---------------------------------------------------------------- 3. freshness checks

$pakItem = Get-Item -LiteralPath $pak
$newestSrc = Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'mod') -Recurse -File |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($newestSrc -and $newestSrc.LastWriteTime -gt $pakItem.LastWriteTime.AddSeconds(5)) {
  Warn ("The pak is older than mod source: {0} changed {1:yyyy-MM-dd HH:mm} (pak packed {2:yyyy-MM-dd HH:mm}). Run scripts\deploy.ps1 first if that change should ship." -f
        $newestSrc.FullName.Substring($ProjectRoot.Length + 1), $newestSrc.LastWriteTime, $pakItem.LastWriteTime)
}
$dllItem = Get-Item -LiteralPath $dll
$nativeSrc = Join-Path $ProjectRoot 'tools\native\src'
if (Test-Path -LiteralPath $nativeSrc) {
  $newestCpp = Get-ChildItem -LiteralPath $nativeSrc -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($newestCpp -and $newestCpp.LastWriteTime -gt $dllItem.LastWriteTime.AddSeconds(5)) {
    Warn ("The DLL is older than native source: {0} changed {1:yyyy-MM-dd HH:mm} (DLL built {2:yyyy-MM-dd HH:mm})." -f
          $newestCpp.FullName.Substring($ProjectRoot.Length + 1), $newestCpp.LastWriteTime, $dllItem.LastWriteTime)
  }
}

$pakSha = Get-Sha $pak
$dllSha = Get-Sha $dll
$installedPak = Join-Path $hostMods 'DarkAndGate.pak'
$installedDll = Join-Path $hostNative 'DarkAndGate.dll'
if (-not (Test-Path -LiteralPath $installedPak)) { Warn "The host has no Mods\DarkAndGate.pak installed." }
elseif ((Get-Sha $installedPak) -ne $pakSha) { Warn "The host's installed Mods\DarkAndGate.pak differs from build\DarkAndGate.pak: host and friend would run different builds. Run scripts\deploy.ps1." }
if (-not (Test-Path -LiteralPath $installedDll)) { Warn "The host has no bin\NativeMods\DarkAndGate.dll installed." }
elseif ((Get-Sha $installedDll) -ne $dllSha) { Warn "The host's installed bin\NativeMods\DarkAndGate.dll differs from the build output: host and friend would run different DLLs. Run scripts\deploy-native.ps1." }

# ---------------------------------------------------------------- 4. stage

$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("dag-friend-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'NativeMods') | Out-Null
try {
  Copy-Item -LiteralPath $pak -Destination (Join-Path $stage 'DarkAndGate.pak')
  Copy-Item -LiteralPath $dll -Destination (Join-Path $stage 'NativeMods\DarkAndGate.dll')

  # Our configs for third-party native mods: the host's live copy (what the
  # host plays with); the repo's config\native copy only as a fallback.
  $configs = [ordered]@{}
  foreach ($name in 'BG3WASD.toml', 'BG3NativeCameraTweaks.toml') {
    $live = Join-Path $hostNative $name
    $repo = Join-Path $repoConfig $name
    $src = $null
    if (Test-Path -LiteralPath $live) { $src = $live }
    elseif (Test-Path -LiteralPath $repo) { $src = $repo; Warn "Host has no bin\NativeMods\$name; shipping the repo's config\native\$name instead." }
    else { Warn "No $name on the host or in config\native; not shipped."; continue }
    if ($src -eq $live -and (Test-Path -LiteralPath $repo) -and (Get-Sha $repo) -ne (Get-Sha $live)) {
      Write-Host "note: shipping the host's live $name (it differs from config\native\$name)." -ForegroundColor DarkGray
    }
    Copy-Item -LiteralPath $src -Destination (Join-Path $stage "NativeMods\$name")
    $configs[$name] = $src
  }

  # Script Extender settings (console + logging): the host's own file.
  $seLive = Join-Path $bin 'ScriptExtenderSettings.json'
  $seStage = Join-Path $stage 'ScriptExtenderSettings.json'
  if (Test-Path -LiteralPath $seLive) {
    Copy-Item -LiteralPath $seLive -Destination $seStage
    try {
      $sj = Get-Content -LiteralPath $seLive -Raw | ConvertFrom-Json
      if ($sj.CreateConsole -ne $true -or $sj.EnableLogging -ne $true) { Warn "The host's ScriptExtenderSettings.json has CreateConsole or EnableLogging off; the friend gets the same." }
    } catch { Warn "The host's ScriptExtenderSettings.json is not valid JSON: $($_.Exception.Message)" }
  } else {
    Warn "Host has no bin\ScriptExtenderSettings.json; shipping a default one (console + logging on)."
    Write-Ascii $seStage "{`r`n    ""CreateConsole"": true,`r`n    ""EnableLogging"": true,`r`n    ""LogRuntime"": true`r`n}`r`n"
  }

  # The host's load order, for install.ps1's load-order fix.
  if (Test-Path -LiteralPath $hostLoad) { Copy-Item -LiteralPath $hostLoad -Destination (Join-Path $stage 'host-modsettings.lsx') }
  else { Warn "No host modsettings.lsx ($hostLoad): the friend's installer can't fix the load order, only explain it." }

  # Scripts. .bat files get CRLF line endings whatever git did to them.
  foreach ($f in 'INSTALL.bat', 'COLLECT-LOGS.bat') {
    $t = (Get-Content -LiteralPath (Join-Path $friendDir $f) -Raw) -replace "`r?`n", "`r`n"
    Write-Ascii (Join-Path $stage $f) $t
  }
  Copy-Item -LiteralPath (Join-Path $friendDir 'install.ps1') -Destination (Join-Path $stage 'install.ps1')
  Copy-Item -LiteralPath $collector -Destination (Join-Path $stage 'mp-collect-logs.ps1')

  # ------------------------------------------------------------ 5. manifest

  $loadOrder = @(Read-LoadOrder $hostLoad)
  if ($loadOrder.Count -eq 0) { Warn "Could not read the host's load order ($hostLoad)." }
  function Find-ModVersion([string]$uuid) {
    foreach ($m in $loadOrder) { if ($m.uuid -eq $uuid) { return $m.version } }
    return $null
  }
  function Find-HostPak([string[]]$patterns) {
    if (-not (Test-Path -LiteralPath $hostMods)) { return $null }
    foreach ($p in $patterns) {
      $hit = Get-ChildItem -LiteralPath $hostMods -Filter $p -File -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($hit) { return $hit.FullName }
    }
    return $null
  }

  $seVersion = $null
  $clientLog = Join-Path $larian 'Script Extender\DarkAndGate\client.log'
  if (Test-Path -LiteralPath $clientLog) {
    $m = Select-String -LiteralPath $clientLog -Pattern 'SE v(\d+)' | Select-Object -First 1
    if ($m) { $seVersion = 'v' + $m.Matches[0].Groups[1].Value }
  }

  $tp = @()
  $nexus = 'https://www.nexusmods.com/baldursgate3/mods/'

  $fp = Get-Fingerprint (Join-Path $bin 'DWrite.dll')
  $tp += [ordered]@{ key = 'se'; name = 'Script Extender (updater, DWrite.dll)'; required = $true; kind = 'dll'
    location = 'bin\DWrite.dll'; url = 'https://github.com/Norbyte/bg3se/releases'; expect_product = 'Script Extender'
    expected_version = $null; host_se_version = $seVersion; host = $fp
    note = 'The updater downloads the newest Script Extender when the game starts; the version handshake only warns on a different SE.' }

  # version.dll is only stat'ed (see Get-Fingerprint). 1.0.0 = Nexus 25474's
  # file version, read from the host's copy on 2026-10-13 before Defender
  # started blocking it.
  $fp = Get-Fingerprint (Join-Path $bin 'version.dll') -SizeOnly
  if (-not $fp) {
    Warn "Host has no bin\version.dll (Ch4nKyy's Mod Loader): no native mod loads on this PC. If Windows Security removed it, restore it from Protection history. Using its known 1.0.0 size."
    $fp = [ordered]@{ file = 'version.dll'; size = 492544; sha256 = $null; product_name = 'Ch4nKyys Mod Loader'; file_version = '1.0.0'; product_version = '1.0.0' }
  }
  $tp += [ordered]@{ key = 'loader'; name = "Ch4nKyy's Mod Loader"; required = $true; kind = 'dll'
    location = 'bin\version.dll'; url = $nexus + '25474'; expect_product = 'Ch4nKyy'
    expected_version = '1.0.0'; host = $fp
    note = 'Loads every DLL in bin\NativeMods. Never install Native Mod Loader as well. Windows Defender may flag it as Trojan:Win32/Posilod.CA!cl (a cloud heuristic).' }

  foreach ($d in @(
      @{ key = 'wasd'; name = 'WASD Character Movement (BG3WASD)'; file = 'BG3WASD.dll'; id = '781'; fallback = '1.9.9' },
      @{ key = 'nct'; name = 'Native Camera Tweaks'; file = 'BG3NativeCameraTweaks.dll'; id = '945'; fallback = '2.4.5' })) {
    $fp = Get-Fingerprint (Join-Path $hostNative $d.file)
    $ev = $null
    if ($fp) { $ev = Get-Ver3 $fp.file_version } else { $ev = $d.fallback; Warn "Host has no bin\NativeMods\$($d.file); expecting $($d.fallback) by default." }
    if ($fp -and -not $ev) { Write-Host "note: $($d.file) has no version info; install.ps1 will compare size + SHA256 instead." -ForegroundColor DarkGray }
    $tp += [ordered]@{ key = $d.key; name = $d.name; required = $true; kind = 'dll'
      location = "bin\NativeMods\$($d.file)"; url = $nexus + $d.id; expect_product = $null
      expected_version = $ev; host = $fp; note = $null }
  }

  foreach ($p in @(
      @{ key = 'mcm'; name = 'Mod Configuration Menu'; uuid = '755a8a72-407f-4f0d-9a33-274ac0f0b53d'; id = '9162'; patterns = @('Mod Configuration Menu*.pak', '*MCM*.pak') },
      @{ key = 'animunlock'; name = 'AnimationUnlocker'; uuid = '7131033f-821a-3993-dad4-5bc235cbeb3b'; id = '16058'; patterns = @('AnimationUnlocker*.pak') })) {
    $path = Find-HostPak $p.patterns
    $fp = $null
    if ($path) { $fp = Get-Fingerprint $path } else { Warn "Host has no $($p.name) pak in the Mods folder." }
    $tp += [ordered]@{ key = $p.key; name = $p.name; required = $true; kind = 'pak'; uuid = $p.uuid
      location = 'Mods\' + $(if ($fp) { $fp.file } else { $p.patterns[0] }); patterns = $p.patterns; url = $nexus + $p.id
      expected_version = (Find-ModVersion $p.uuid); host = $fp; note = $null }
  }

  $plbPath = Find-HostPak @('*PartyLimitBegone*.pak', '*Party Limit Begone*.pak', '*PartyLimit*.pak')
  $plbFp = $null; if ($plbPath) { $plbFp = Get-Fingerprint $plbPath }
  $tp += [ordered]@{ key = 'plb'; name = 'Party Limit Begone (SE version)'; required = [bool]$plbFp; kind = 'pak'
    location = 'Mods\PartyLimitBegone*.pak'; patterns = @('*PartyLimitBegone*.pak', '*Party Limit Begone*.pak', '*PartyLimit*.pak'); url = $nexus + '327'
    expected_version = $null; host = $plbFp
    note = 'Only for 5+ players, and then every player needs it plus its multiplayer exe patch. Use the SE version pak, never the standalone (it writes into the game''s Data folder).' }

  $exeFp = $null
  $exe = Join-Path $bin 'bg3_dx11.exe'
  if (Test-Path -LiteralPath $exe) {
    $ei = Get-Item -LiteralPath $exe
    # ProductVersion is the game build ("4.1.1.7631656"); FileVersion is just "1.0.0.0".
    $exeFp = [ordered]@{ file = $ei.Name; size = $ei.Length; sha256 = (Get-Sha $exe)
      product_version = $(if ($ei.VersionInfo.ProductVersion) { $ei.VersionInfo.ProductVersion.Trim() } else { $null })
      file_version = $(if ($ei.VersionInfo.FileVersion) { $ei.VersionInfo.FileVersion.Trim() } else { $null }) }
    if (-not $exeFp.product_version) { Warn "bg3_dx11.exe has no ProductVersion: install.ps1 falls back to its built-in game version." }
  } else {
    Warn "No bin\bg3_dx11.exe on the host: the friend's game version can't be checked against it."
  }

  $files = [ordered]@{}
  foreach ($f in (Get-ChildItem -LiteralPath $stage -Recurse -File)) {
    $rel = $f.FullName.Substring((Get-Item -LiteralPath $stage).FullName.TrimEnd('\').Length + 1)
    if ($rel -notmatch '\.(pak|dll|toml)$' -and $rel -ne 'ScriptExtenderSettings.json') { continue }
    $dest = $(if ($rel -like '*.pak') { 'Mods\' + $f.Name } else { 'bin\' + $rel })
    $files[$rel] = [ordered]@{ installs_to = $dest; size = $f.Length; sha256 = (Get-Sha $f.FullName) }
  }

  $manifest = [ordered]@{
    package          = "DarkAndGate-friend-$tag"
    created_local    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
    created_utc      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    git_sha          = $gitSha
    git_dirty        = $gitDirty
    mod_build        = $modBuild
    dll_build        = $dllBuild
    mod_uuid         = 'd5d298fd-ba29-4dc1-8346-6ac96b8c2cd7'
    files            = $files
    third_party      = $tp
    host_game_exe    = $exeFp
    host_load_order  = $loadOrder
    host_script_extender = $seVersion
  }
  Write-Ascii (Join-Path $stage 'manifest.json') ($manifest | ConvertTo-Json -Depth 8)

  # ------------------------------------------------------------ 6. README with the live load order

  $readme = Get-Content -LiteralPath (Join-Path $friendDir 'FRIEND-README.md') -Raw
  if ($loadOrder.Count -gt 0) {
    $lines = @()
    foreach ($m in $loadOrder) { $lines += ("{0}. **{1}** (version {2})" -f $m.order, $m.name, $m.version) }
    $block = "<!-- HOST-LOAD-ORDER:BEGIN -->`r`n" + ($lines -join "`r`n") + "`r`n<!-- HOST-LOAD-ORDER:END -->"
    $readme = [regex]::Replace($readme, '(?s)<!-- HOST-LOAD-ORDER:BEGIN -->.*?<!-- HOST-LOAD-ORDER:END -->', { param($x) $block })
  }
  $buildLine = "<!-- BUILD:BEGIN -->Build: ``$tag`` (mod $modBuild, DLL $dllBuild)<!-- BUILD:END -->"
  $readme = [regex]::Replace($readme, '(?s)<!-- BUILD:BEGIN -->.*?<!-- BUILD:END -->', { param($x) $buildLine })
  Write-Ascii (Join-Path $stage 'FRIEND-README.md') $readme

  # ------------------------------------------------------------ 7. zip

  if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
  $zipPath = Join-Path $OutDir "DarkAndGate-friend-$tag.zip"
  New-ZipFromFolder $stage $zipPath
} finally {
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- 8. report

Write-Host ""
Write-Host "Friend package: $zipPath" -ForegroundColor Green
Write-Host ("  DarkAndGate.pak  SHA256 {0}  ({1:N0} bytes)" -f $pakSha, $pakItem.Length)
Write-Host ("  DarkAndGate.dll  SHA256 {0}  ({1:N0} bytes)" -f $dllSha, $dllItem.Length)
Write-Host "  mod_build $modBuild   dll_build $dllBuild"
Write-Host "  Third-party versions the friend needs:"
foreach ($t in $tp) {
  $hv = '(not installed on host)'
  if ($t.host) {
    if ($t.expected_version) { $hv = $t.expected_version } elseif ($t.host.file_version) { $hv = "file $($t.host.file_version)" }
    elseif ($t.host.sha256) { $hv = "size $($t.host.size), sha256 $($t.host.sha256.Substring(0, 12))..." } else { $hv = "size $($t.host.size)" }
    if ($t.key -eq 'se' -and $t.host_se_version) { $hv += " (SE $($t.host_se_version))" }
  }
  Write-Host ("    {0,-38} {1}" -f $t.name, $hv)
}
Write-Host "  Host load order: $((@($loadOrder | ForEach-Object { $_.name })) -join ' > ')"
if ($exeFp) { Write-Host "  Game: bg3_dx11.exe $($exeFp.product_version)" }
Write-Host "  Configs shipped: $((@($configs.Keys) + 'ScriptExtenderSettings.json') -join ', ')$(if (Test-Path -LiteralPath $hostLoad) { ', host-modsettings.lsx' })"
if ($warnings.Count -gt 0) {
  Write-Host "`n$($warnings.Count) warning(s) above." -ForegroundColor Yellow
}
