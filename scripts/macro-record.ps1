<#
.SYNOPSIS
  Record a keyboard + mouse macro to a JSON file.

.DESCRIPTION
  Polls Windows input state at ~120 Hz, capturing:
    * key-down and key-up transitions on virtual keys 1..254,
    * mouse-down and mouse-up transitions on left/right/middle,
    * cursor position samples every frame.

  Timings are stored in milliseconds from the start of recording so playback
  runs at the exact original pace (no speed-up).

  Press Ctrl+T at any time to stop recording. The macro file is written to
  scripts\macros\<name>.json by default; you can override with -OutPath.

.PARAMETER Name
  Short name for the macro, e.g. "launch-bg3". Final file is
  scripts\macros\<name>.json unless -OutPath overrides.

.PARAMETER StartDelaySeconds
  Seconds to wait after pressing Enter before recording actually begins.
  Lets you alt-tab to the right window.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\macro-record.ps1 -Name launch-bg3
#>

param(
    [Parameter(Mandatory=$true)][string]$Name,
    [int]$StartDelaySeconds = 3,
    [string]$OutPath
)

$ErrorActionPreference = 'Stop'

if (-not $OutPath) {
    $macroDir = Join-Path $PSScriptRoot "macros"
    if (-not (Test-Path $macroDir)) { New-Item -ItemType Directory -Path $macroDir | Out-Null }
    $OutPath = Join-Path $macroDir "$Name.json"
}

# Native API: GetAsyncKeyState for key/mouse state, GetCursorPos for position.
# All polled -- no low-level hook, so no DLL injection and no admin needed.
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class MacroNative {
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);
}
'@
# Make this process per-monitor DPI aware so cursor coordinates are physical
# pixels, matching whatever the playback script sees. Without this, PowerShell
# runs non-DPI-aware and GetCursorPos returns virtualised coordinates that
# don't match physical pixel click targets after display scaling.
[void][MacroNative]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))

# VK codes we care about: 0x01=LBUTTON, 0x02=RBUTTON, 0x04=MBUTTON, plus every
# keyboard key 0x08..0xFE. We skip 0x03 (CANCEL) and 0x07 (undefined).
$VK_LBUTTON = 0x01; $VK_RBUTTON = 0x02; $VK_MBUTTON = 0x04
$VK_CONTROL = 0x11; $VK_T = 0x54

$prev = @{}
# Pre-populate so the first poll doesn't fire spurious up-events for keys that
# are already held when recording starts.
for ($vk = 0x01; $vk -le 0xFE; $vk++) {
    if ($vk -eq 0x03 -or $vk -eq 0x07) { continue }
    $state = [MacroNative]::GetAsyncKeyState($vk)
    $prev[$vk] = (($state -band 0x8000) -ne 0)
}

Write-Host "Macro: $Name"
Write-Host "Output: $OutPath"
Write-Host "Starting in $StartDelaySeconds seconds. Press Ctrl+T to stop."
Write-Host "Any input you do during this countdown is NOT recorded."
Start-Sleep -Seconds $StartDelaySeconds

$events = New-Object System.Collections.Generic.List[object]
$sw = [System.Diagnostics.Stopwatch]::StartNew()

$lastCursor = $null
$pollIntervalMs = 8  # ~125 Hz
$lastMovePushMs = -1

while ($true) {
    $tMs = [int]$sw.Elapsed.TotalMilliseconds

    # Ctrl+T stops recording. Check first so we don't record it as part of the macro.
    $ctrl = [MacroNative]::GetAsyncKeyState($VK_CONTROL)
    $t    = [MacroNative]::GetAsyncKeyState($VK_T)
    if ((($ctrl -band 0x8000) -ne 0) -and (($t -band 0x8000) -ne 0)) { break }

    # Sample cursor position once per tick so we can stamp it on every event
    # fired this iteration -- clicks land at the exact pixel the mouse was on,
    # not the position of the previous move sample.
    $pt = New-Object MacroNative+POINT
    [void][MacroNative]::GetCursorPos([ref]$pt)

    for ($vk = 0x01; $vk -le 0xFE; $vk++) {
        if ($vk -eq 0x03 -or $vk -eq 0x07) { continue }
        $state = [MacroNative]::GetAsyncKeyState($vk)
        $down = (($state -band 0x8000) -ne 0)
        if ($down -ne $prev[$vk]) {
            if ($vk -in @($VK_LBUTTON, $VK_RBUTTON, $VK_MBUTTON)) {
                $kind = if ($down) { "mdown" } else { "mup" }
                # Attach cursor position to every click event so playback
                # teleports before firing, independent of move-sample timing.
                $events.Add([pscustomobject]@{ t = $tMs; type = $kind; vk = $vk; x = $pt.X; y = $pt.Y })
            } else {
                $kind = if ($down) { "kdown" } else { "kup" }
                $events.Add([pscustomobject]@{ t = $tMs; type = $kind; vk = $vk })
            }
            $prev[$vk] = $down
        }
    }

    # Cursor position: record on change, at most once per ~16ms to keep the file small.
    if ($lastCursor -eq $null -or $pt.X -ne $lastCursor.X -or $pt.Y -ne $lastCursor.Y) {
        if ($tMs - $lastMovePushMs -ge 16) {
            $events.Add([pscustomobject]@{ t = $tMs; type = "move"; x = $pt.X; y = $pt.Y })
            $lastCursor = $pt
            $lastMovePushMs = $tMs
        }
    }

    Start-Sleep -Milliseconds $pollIntervalMs
}

$sw.Stop()
$totalMs = [int]$sw.Elapsed.TotalMilliseconds

# Scrub trailing Ctrl/T events: the user had to press both to stop recording,
# and because the top-of-loop check breaks on the iteration AFTER the keys go
# down, we almost always captured at least a Ctrl-down with no matching kup.
# Walk from the end and drop any Ctrl/T transitions until we see a non-Ctrl/T
# event, then force-emit kup for both so playback leaves the modifier clean.
for ($i = $events.Count - 1; $i -ge 0; $i--) {
    $vk = [int]$events[$i].vk
    if (($events[$i].type -eq "kdown" -or $events[$i].type -eq "kup") -and
        ($vk -eq $VK_CONTROL -or $vk -eq $VK_T)) {
        $events.RemoveAt($i)
    } else {
        break
    }
}
# Synthetic releases so playback never leaves Ctrl stuck.
$events.Add([pscustomobject]@{ t = $totalMs; type = "kup"; vk = $VK_T })
$events.Add([pscustomobject]@{ t = $totalMs; type = "kup"; vk = $VK_CONTROL })

# Resolve the primary monitor size so playback can tolerate different DPI /
# virtual-screen configurations. We store absolute pixel coords plus the
# recording-time screen size as metadata.
Add-Type -AssemblyName System.Windows.Forms
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

$macro = [pscustomobject]@{
    name = $Name
    recordedAt = (Get-Date).ToString("o")
    durationMs = $totalMs
    screen = [pscustomobject]@{ width = $screen.Width; height = $screen.Height }
    events = $events
}

$macro | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutPath -Encoding utf8
Write-Host "Saved $($events.Count) events in $($totalMs)ms to $OutPath"
