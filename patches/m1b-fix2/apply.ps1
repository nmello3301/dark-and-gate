# Dark and Gate - M1b fix2: copy the patched Lua files into the repo, then
# rebuild + deploy + launch via scripts\pov-build-deploy.ps1.
# Safety: a target is only overwritten if it is byte-identical to the
# version this patch was written against (git blob SHA from the index).
# If someone edited it since, the script stops and changes nothing.
# Result line: patches\m1b-fix2\apply.result

$ErrorActionPreference = 'Stop'
$here   = $PSScriptRoot
$root   = (Resolve-Path (Join-Path $here "..\..")).Path
$lua    = Join-Path $root "mod\DarkAndGate\Mods\DarkAndGate\ScriptExtender\Lua"
$result = Join-Path $here "apply.result"

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
    $txt = [Text.Encoding]::UTF8.GetString($raw)
    $lf  = [Text.Encoding]::UTF8.GetBytes($txt.Replace("`r`n", "`n"))
    return @((Get-BlobSha $raw), (Get-BlobSha $lf))
}

$plan = @(
    @{ src = "Aim.lua";    dst = "Client\Combat\Aim.lua";    base = "3cf80c76425fcf869a761942970eeb741ab18d74" },
    @{ src = "Swing.lua";  dst = "Client\Combat\Swing.lua";  base = "5eae3d7c9ae3ab04126c6a3f30cbde0a0667930f" },
    @{ src = "Spells.lua"; dst = "Client\Combat\Spells.lua"; base = "ec5b9493c7984b42e609750e46618cef52019b19" },
    @{ src = "HUD.lua";    dst = "Client\Combat\HUD.lua";    base = "798d91780a4e3ee872bcbe0056371e4977240da5" },
    @{ src = "Debug.lua";  dst = "Client\Combat\Debug.lua";  base = "2afccb45e3bb5f401b7f843062669ae06b2ace04" },
    @{ src = "Dummy.lua";  dst = "Server\Combat\Dummy.lua";  base = "2ec8cf1b7213c9415bbdda3cceac82c9e3bc7d98" }
)

try {
    Set-Content -LiteralPath $result -Value "RUNNING $(Get-Date -Format o)"
    # Pass 1: verify everything before touching anything.
    foreach ($p in $plan) {
        $dst = Join-Path $lua $p.dst
        $src = Join-Path $here $p.src
        if (-not (Test-Path -LiteralPath $dst)) { throw "missing target $($p.dst)" }
        $cur = Get-Shas $dst
        $new = Get-Shas $src
        if ($cur -contains $new[1] -or $cur -contains $new[0]) { $p.state = "already"; continue }
        if ($cur -contains $p.base) { $p.state = "apply"; continue }
        throw "$($p.dst) was changed since this patch was written - NOT overwriting anything. Ask Claude Code to merge patches\m1b-fix2 by hand."
    }
    # Pass 2: copy.
    foreach ($p in $plan) {
        if ($p.state -eq "apply") {
            Copy-Item -LiteralPath (Join-Path $here $p.src) -Destination (Join-Path $lua $p.dst) -Force
            Write-Host "patched  $($p.dst)"
        } else {
            Write-Host "already  $($p.dst)"
        }
    }
    Set-Content -LiteralPath $result -Value "PATCHED $(Get-Date -Format o)"
}
catch {
    Write-Host "FAILED: $_" -ForegroundColor Red
    Set-Content -LiteralPath $result -Value "FAIL $_"
    exit 1
}

Write-Host "== Build + deploy (waits for BG3 to close, then launches it)"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\pov-build-deploy.ps1")
$br = Get-Content -LiteralPath (Join-Path $root "build\pov-build.result") -ErrorAction SilentlyContinue
Add-Content -LiteralPath $result -Value "BUILD $br"
Write-Host "Build result: $br"
if ($br -notmatch '^OK') { exit 1 }
