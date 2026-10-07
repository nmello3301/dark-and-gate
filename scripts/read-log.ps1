<#
.SYNOPSIS
  Print DarkAndGate's session log, written by the mod through Ext.IO.

.DESCRIPTION
  Ext.IO.SaveFile writes to:
    %LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\DarkAndGate\session.log
  This script prints that file. Use -Tail N to see only the last N lines, or
  -Follow to stream new lines as the game writes them.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\scripts\read-log.ps1
  powershell -ExecutionPolicy Bypass -File .\scripts\read-log.ps1 -Tail 50
  powershell -ExecutionPolicy Bypass -File .\scripts\read-log.ps1 -Follow
#>
param(
  [int]$Tail,
  [switch]$Follow
)

$dir  = Join-Path $env:LOCALAPPDATA "Larian Studios\Baldur's Gate 3\Script Extender\DarkAndGate"
$srv  = Join-Path $dir "server.log"
$cli  = Join-Path $dir "client.log"

$files = @($srv, $cli) | Where-Object { Test-Path -LiteralPath $_ }
if ($files.Count -eq 0) {
  Write-Host "No logs yet under: $dir" -ForegroundColor Yellow
  Write-Host "Launch BG3 with the mod enabled and the files will appear." -ForegroundColor Yellow
  return
}

if ($Follow) {
  # One tail stream per existing file. Ctrl+C to stop.
  $jobs = foreach ($f in $files) {
    Start-Job -ArgumentList $f -ScriptBlock {
      param($path)
      Get-Content -LiteralPath $path -Wait -Tail 20
    }
  }
  try { Wait-Job -Any $jobs | Receive-Job -Keep } finally { $jobs | Remove-Job -Force }
  return
}

# Merge both logs and sort by the "+SSS.mmms" timestamp at the start of each
# line. Lines without a timestamp sort to the end.
$all = foreach ($f in $files) { Get-Content -LiteralPath $f }
$sorted = $all | Sort-Object -Property @{ Expression = {
  if ($_ -match '^\[\+(\d+\.\d+)s\]') { [double]$Matches[1] } else { [double]::PositiveInfinity }
} }

if ($Tail -gt 0) { $sorted | Select-Object -Last $Tail } else { $sorted }
