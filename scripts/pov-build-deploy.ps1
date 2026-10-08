# Build the native DLL, deploy it and the mod pak, then ping for a playtest.
# Writes a full log to build\pov-build.log and a one-line result to
# build\pov-build.result (OK / FAIL <reason>), so a remote helper can check it.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\pov-build-deploy.ps1

$ErrorActionPreference = 'Stop'
$root    = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$buildD  = Join-Path $root "build"
New-Item -ItemType Directory -Force -Path $buildD | Out-Null
$log     = Join-Path $buildD "pov-build.log"
$result  = Join-Path $buildD "pov-build.result"
Set-Content -LiteralPath $result -Value "RUNNING $(Get-Date -Format o)"
Start-Transcript -LiteralPath $log -Force | Out-Null

try {
    $cmake = "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
    if (-not (Test-Path -LiteralPath $cmake)) { $cmake = "cmake" }

    $deadline = (Get-Date).AddMinutes(5)
    while (Get-Process -Name bg3, bg3_dx11 -ErrorAction SilentlyContinue) {
        if ((Get-Date) -gt $deadline) { throw "BG3 still running after 5 min" }
        Write-Host "Waiting for BG3 to close..."
        Start-Sleep -Seconds 2
    }

    Write-Host "== Configure + build DLL"
    Push-Location (Join-Path $root "tools\native")
    & $cmake -S . -B out\build
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed ($LASTEXITCODE)" }
    & $cmake --build out\build --config Release
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed ($LASTEXITCODE)" }
    Pop-Location

    Write-Host "== Deploy DLL"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\deploy-native.ps1")
    if ($LASTEXITCODE -ne 0) { throw "deploy-native failed ($LASTEXITCODE)" }

    Write-Host "== Pack + deploy mod"
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\deploy.ps1")
    if ($LASTEXITCODE -ne 0) { throw "deploy (pak) failed ($LASTEXITCODE)" }

    Set-Content -LiteralPath $result -Value "OK $(Get-Date -Format o)"
    Stop-Transcript | Out-Null
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts\notify.ps1") -Message "Full POV build ready"
}
catch {
    Write-Host "FAILED: $_"
    Set-Content -LiteralPath $result -Value "FAIL $_"
    try { Stop-Transcript | Out-Null } catch {}
}
