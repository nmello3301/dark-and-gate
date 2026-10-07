<#
.SYNOPSIS
  Replay a macro recorded by macro-record.ps1.

.DESCRIPTION
  Reads a macro JSON, waits StartDelaySeconds, then replays every event at
  its original timing (no speed up).

  Keyboard: SendInput with KEYEVENTF_SCANCODE so keystrokes behave the same
  as physical ones (works in games, Start menu, etc.).
  Mouse: SendInput with absolute coords mapped to the virtual screen so
  playback hits the same screen position even on multi-monitor setups.

.PARAMETER Name
  Name of the macro file (without .json), looked up in scripts\macros\.

.PARAMETER Path
  Explicit path to the macro JSON. Overrides -Name.

.PARAMETER StartDelaySeconds
  Seconds to wait before playback starts. Default 3.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\macro-play.ps1 -Name launch-bg3
#>

param(
    [string]$Name,
    [string]$Path,
    [int]$StartDelaySeconds = 3
)

$ErrorActionPreference = 'Stop'

if (-not $Path) {
    if (-not $Name) { throw "Pass either -Name <macro> or -Path <file>." }
    $Path = Join-Path (Join-Path $PSScriptRoot "macros") "$Name.json"
}
if (-not (Test-Path -LiteralPath $Path)) { throw "Macro not found: $Path" }

$macro = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class MacroPlay {
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }

    // Union: largest member decides size. Keep a padded blob.
    [StructLayout(LayoutKind.Explicit)]
    public struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public INPUTUNION u; }

    public const uint INPUT_MOUSE = 0;
    public const uint INPUT_KEYBOARD = 1;

    public const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
    public const uint KEYEVENTF_KEYUP       = 0x0002;
    public const uint KEYEVENTF_SCANCODE    = 0x0008;
    public const uint KEYEVENTF_UNICODE     = 0x0004;

    public const uint MOUSEEVENTF_MOVE       = 0x0001;
    public const uint MOUSEEVENTF_LEFTDOWN   = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP     = 0x0004;
    public const uint MOUSEEVENTF_RIGHTDOWN  = 0x0008;
    public const uint MOUSEEVENTF_RIGHTUP    = 0x0010;
    public const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
    public const uint MOUSEEVENTF_MIDDLEUP   = 0x0040;
    public const uint MOUSEEVENTF_ABSOLUTE   = 0x8000;
    public const uint MOUSEEVENTF_VIRTUALDESK= 0x4000;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    public static extern uint MapVirtualKey(uint uCode, uint uMapType);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);
}
'@
# Match recorder: per-monitor DPI awareness so physical pixels line up.
[void][MacroPlay]::SetProcessDpiAwarenessContext([IntPtr]::new(-4))

function Send-Key([uint16]$vk, [bool]$down) {
    $scan = [MacroPlay]::MapVirtualKey([uint32]$vk, 0)
    $flags = [MacroPlay]::KEYEVENTF_SCANCODE
    if (-not $down) { $flags = $flags -bor [MacroPlay]::KEYEVENTF_KEYUP }

    # Extended-key set (arrows, nav keys, right alt/ctrl, etc.) must set the
    # extended flag so games/UI see the correct scancode.
    $extended = @(0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x28,0x2D,0x2E,0x5B,0x5C,0x5D,0xA3,0xA5)
    if ($extended -contains $vk) { $flags = $flags -bor [MacroPlay]::KEYEVENTF_EXTENDEDKEY }

    $input = New-Object MacroPlay+INPUT
    $input.type = [MacroPlay]::INPUT_KEYBOARD
    $input.u.ki.wVk = [uint16]$vk
    $input.u.ki.wScan = [uint16]$scan
    $input.u.ki.dwFlags = $flags
    $input.u.ki.time = 0
    $input.u.ki.dwExtraInfo = [IntPtr]::Zero

    [void][MacroPlay]::SendInput(1, @($input), [System.Runtime.InteropServices.Marshal]::SizeOf($input))
}

function Send-Mouse([int]$x, [int]$y, [uint32]$flags) {
    # Move with SetCursorPos first for reliability on multi-monitor; SendInput
    # with ABSOLUTE normalises to [0..65535] on the virtual desktop which is
    # fiddly with mixed DPI. SetCursorPos uses raw pixels on the primary.
    if (($flags -band [MacroPlay]::MOUSEEVENTF_MOVE) -ne 0) {
        [void][MacroPlay]::SetCursorPos($x, $y)
        $flags = $flags -band (-bnot [uint32][MacroPlay]::MOUSEEVENTF_MOVE)
        if ($flags -eq 0) { return }
    }
    $input = New-Object MacroPlay+INPUT
    $input.type = [MacroPlay]::INPUT_MOUSE
    $input.u.mi.dx = 0
    $input.u.mi.dy = 0
    $input.u.mi.mouseData = 0
    $input.u.mi.dwFlags = $flags
    $input.u.mi.time = 0
    $input.u.mi.dwExtraInfo = [IntPtr]::Zero
    [void][MacroPlay]::SendInput(1, @($input), [System.Runtime.InteropServices.Marshal]::SizeOf($input))
}

$mouseVks = @{ 0x01 = "L"; 0x02 = "R"; 0x04 = "M" }
$mouseDownFlags = @{
    0x01 = [MacroPlay]::MOUSEEVENTF_LEFTDOWN
    0x02 = [MacroPlay]::MOUSEEVENTF_RIGHTDOWN
    0x04 = [MacroPlay]::MOUSEEVENTF_MIDDLEDOWN
}
$mouseUpFlags = @{
    0x01 = [MacroPlay]::MOUSEEVENTF_LEFTUP
    0x02 = [MacroPlay]::MOUSEEVENTF_RIGHTUP
    0x04 = [MacroPlay]::MOUSEEVENTF_MIDDLEUP
}

Write-Host "Playing macro: $($macro.name) ($($macro.events.Count) events, $($macro.durationMs)ms)"
Write-Host "Starting in $StartDelaySeconds seconds."
Start-Sleep -Seconds $StartDelaySeconds

$sw = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($e in $macro.events) {
    $wait = [int]$e.t - [int]$sw.Elapsed.TotalMilliseconds
    if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }

    # Windows filters some synthesised LWIN/RWIN presses so the Start menu
    # never opens. Substitute with Ctrl+Esc, Windows' documented shortcut for
    # opening Start. Only applies to standalone Win presses; combos like
    # Win+L would need special handling but we don't record those here.
    if (([int]$e.vk -eq 0x5B -or [int]$e.vk -eq 0x5C) -and
        ($e.type -eq "kdown" -or $e.type -eq "kup")) {
        $down = ($e.type -eq "kdown")
        Send-Key ([uint16]0x11) $down   # VK_CONTROL
        Send-Key ([uint16]0x1B) $down   # VK_ESCAPE
        continue
    }

    switch ($e.type) {
        "move"  { Send-Mouse ([int]$e.x) ([int]$e.y) ([MacroPlay]::MOUSEEVENTF_MOVE) }
        "mdown" {
            # Teleport to the exact click pixel before firing, in case any move
            # samples between here and the previous teleport were skipped.
            if ($e.PSObject.Properties.Name -contains "x") {
                [void][MacroPlay]::SetCursorPos([int]$e.x, [int]$e.y)
            }
            Send-Mouse 0 0 ($mouseDownFlags[[int]$e.vk])
        }
        "mup"   {
            if ($e.PSObject.Properties.Name -contains "x") {
                [void][MacroPlay]::SetCursorPos([int]$e.x, [int]$e.y)
            }
            Send-Mouse 0 0 ($mouseUpFlags[[int]$e.vk])
        }
        "kdown" { Send-Key ([uint16][int]$e.vk) $true }
        "kup"   { Send-Key ([uint16][int]$e.vk) $false }
    }
}

$sw.Stop()
Write-Host "Done in $([int]$sw.Elapsed.TotalMilliseconds)ms."
