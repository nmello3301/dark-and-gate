# Dark and Gate - M1b fix5 (one double-click: patch + build + deploy + commit + chime)
#
#  1. Copies files\ over mod\...\ScriptExtender\Lua\ -- but only files that are
#     still byte-identical to the version this patch was written against
#     (git blob SHA in manifest.txt). If any target changed, NOTHING is
#     copied and the reason is printed + written to apply.result.
#  2. Runs scripts\pov-build-deploy.ps1 (waits for BG3 to close, builds,
#     deploys DLL + pak, plays the chime, launches BG3).
#  3. git commit of exactly the patched files + this folder (local only, no push).
#  4. Plays the chime on failure too, and keeps the window open.

$ErrorActionPreference = 'Stop'
$here   = $PSScriptRoot
$root   = (Resolve-Path (Join-Path $here "..\..")).Path
$lua    = Join-Path $root "mod\DarkAndGate\Mods\DarkAndGate\ScriptExtender\Lua"
$result = Join-Path $here "apply.result"
$notify = Join-Path $root "scripts\notify.ps1"

function Get-BlobSha([byte[]]$bytes) {
    $hdr = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
    $all = New-Object byte[] ($hdr.Length + $bytes.Length)
    [Buffer]::BlockCopy($hdr, 0, $all, 0, $hdr.Length)
    [Buffer]::BlockCopy($bytes, 0, $all, $hdr.Length, $bytes.Length)
    $sha = [Security.Cryptography.SHA1]::Create()
    return (($sha.ComputeHash($all) | ForEach-Object { $_.ToString('x2') }) -join '')
}
function Get-Shas([string]$path) {
    $raw = [IO.File]::ReadAllBytes($path)
    $lf  = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt $raw.Length; $i++) {
        if ($raw[$i] -eq 13 -and $i + 1 -lt $raw.Length -and $raw[$i + 1] -eq 10) { continue }
        $lf.Add($raw[$i])
    }
    return @((Get-BlobSha $raw), (Get-BlobSha $lf.ToArray()))
}
function Chime { try { & powershell -NoProfile -ExecutionPolicy Bypass -File $notify -NoLaunch -Message "fix5 FAILED - see window" } catch {} }

$log = New-Object System.Collections.Generic.List[string]
function Say([string]$s, [string]$color = "Gray") { Write-Host $s -ForegroundColor $color; $log.Add($s) }

try {
    $plan = @()
    foreach ($line in Get-Content -LiteralPath (Join-Path $here "manifest.txt")) {
        if (-not $line.Trim()) { continue }
        $rel, $base = $line.Trim().Split('|')
        $plan += [pscustomobject]@{ rel = $rel; base = $base; state = "" }
    }
    # Pass 1: verify everything before touching anything.
    $bad = @()
    foreach ($p in $plan) {
        $dst = Join-Path $lua $p.rel
        $src = Join-Path $here ("files\" + $p.rel)
        $new = Get-Shas $src
        if (-not (Test-Path -LiteralPath $dst)) {
            if ($p.base -eq "NEW") { $p.state = "apply"; continue }
            $bad += "$($p.rel): missing in repo"; continue
        }
        $cur = Get-Shas $dst
        if ($cur -contains $new[0] -or $cur -contains $new[1]) { $p.state = "already"; continue }
        if ($cur -contains $p.base) { $p.state = "apply"; continue }
        $bad += "$($p.rel): repo has $($cur[0]) (lf $($cur[1])), patch expects $($p.base)"
    }
    if ($bad.Count -gt 0) {
        Say "NOT APPLIED - these files changed since the patch was written:" "Red"
        foreach ($b in $bad) { Say "  $b" "Red" }
        throw "hash guard"
    }
    foreach ($p in $plan) {
        if ($p.state -eq "apply") {
            $dst = Join-Path $lua $p.rel
            New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
            Copy-Item -LiteralPath (Join-Path $here ("files\" + $p.rel)) -Destination $dst -Force
            Say "patched  $($p.rel)" "Green"
        } else { Say "already  $($p.rel)" }
    }

    Say "== Build + deploy (waits for BG3 to close; chimes + launches BG3 when ready)" "Cyan"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\pov-build-deploy.ps1")
    $br = Get-Content -LiteralPath (Join-Path $root "build\pov-build.result") -ErrorAction SilentlyContinue
    Say "Build result: $br"
    if ("$br" -notmatch '^OK') { throw "build/deploy failed: $br (see build\pov-build.log)" }

    Say "== git commit (local)" "Cyan"
    try {
        Push-Location $root
        $paths = @("patches/m1b-fix5") + ($plan | ForEach-Object { "mod/DarkAndGate/Mods/DarkAndGate/ScriptExtender/Lua/" + $_.rel.Replace('\', '/') })
        & git add -- $paths
        $msg = @"
M1b fix5: real melee attack clip, no stuck Gale in turn-based, !dag_unstick

- Anims v3: only HUM_M_Rig_*_CMBT_*_Attack clips (v2 picked a _Cancel phase
  and a zombie-rig clip); interim picks from the v2 cache while v3 scans
- Server PlayAnim: skipped while Osi.IsInCombat (turn-based) -- a scripted
  PlayAnimation outside your turn left Gale unable to walk
- !dag_unstick: PurgeOsirisQueue / FlushOsirisQueue / StopAnimation

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_0115QAwFfnmoEkKt9rPMeuW5
"@
        $tmp = Join-Path $here "commit-msg.txt"
        [IO.File]::WriteAllText($tmp, $msg, (New-Object System.Text.UTF8Encoding($false)))
        & git commit -F $tmp -- $paths
        if ($LASTEXITCODE -eq 0) { Say "committed" "Green" } else { Say "git commit returned $LASTEXITCODE (build is deployed anyway)" "Yellow" }
        Pop-Location
    } catch { Say "git commit skipped: $_ (build is deployed anyway)" "Yellow"; try { Pop-Location } catch {} }

    $log.Insert(0, "OK $(Get-Date -Format o)")
    Set-Content -LiteralPath $result -Value $log
    Say "DONE - BG3 is launching. Leave this window or close it." "Green"
}
catch {
    Say "FAILED: $_" "Red"
    $log.Insert(0, "FAIL $(Get-Date -Format o) $_")
    Set-Content -LiteralPath $result -Value $log
    Chime
    exit 1
}
