# Dark and Gate - M1b fix1: copy the patched Lua files into the repo, then
# rebuild + deploy + launch via scripts\pov-build-deploy.ps1.
# Safety: a target is only overwritten if it is byte-identical to the
# version this patch was written against (git blob SHA from the index).
# If someone edited it since, the script stops and changes nothing.
# Result line: patches\m1b-fix1\apply.result

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
    @{ src = "Input.lua";      dst = "Client\Combat\Input.lua"; base = "6ea99a082daaa9176df1a554c4e479c2141a6969" },
    @{ src = "State.lua";      dst = "Client\Combat\State.lua"; base = "1533153d803b9563a9f5b7fce3c29946e3a0b6c2" },
    @{ src = "Aim.lua";        dst = "Client\Combat\Aim.lua";   base = "43c954cf1e6bc2aa4fe6863cb2fe06869efac165" },
    @{ src = "Server_Net.lua"; dst = "Server\Net.lua";          base = "c9f49cd3cfe0625d2569f1b102708939d8652b05" }
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
        throw "$($p.dst) was changed since this patch was written - NOT overwriting anything. Ask Claude Code to merge patches\m1b-fix1 by hand."
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
