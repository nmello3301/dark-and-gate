<#
.SYNOPSIS
  Launch BG3 through its Steam URL, then optionally play a click macro
  for the Larian launcher dialog.

.DESCRIPTION
  Skips the Start-menu / typing dance by invoking Steam's rungameid URL
  for BG3 (app ID 1086940). After WaitSeconds (default 10) it plays the
  macro named by -ClicksMacro, which should contain just the clicks
  needed on the Vulkan/DX11 launcher dialog -- not the Win-key opening,
  which this script replaces.

.PARAMETER WaitSeconds
  How long to wait after kicking the Steam URL before the clicks start.
  Set this to roughly how long it takes for the Larian launcher dialog
  to appear on your machine.

.PARAMETER ClicksMacro
  Macro name (without .json) to run after the wait. Optional -- if
  omitted the script just launches BG3 and exits.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\launch-bg3.ps1 -ClicksMacro bg3-dialog
#>

param(
    [int]$WaitSeconds = 10,
    [string]$ClicksMacro
)

Write-Host "Launching BG3 via steam://rungameid/1086940"
Start-Process "steam://rungameid/1086940"

if ($ClicksMacro) {
    Write-Host "Waiting $WaitSeconds seconds for the Larian launcher dialog..."
    Start-Sleep -Seconds $WaitSeconds

    # Steam launches the Larian launcher in the background. Bring it to the
    # foreground so our click macro lands on the right window.
    Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class WinFg {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    public const int SW_RESTORE = 9;
}
'@
    $targetTitles = @("Baldur's Gate 3", "Larian", "Baldur")
    $found = [IntPtr]::Zero
    $cb = [WinFg+EnumWindowsProc]{
        param($hWnd, $lParam)
        if (-not [WinFg]::IsWindowVisible($hWnd)) { return $true }
        $sb = New-Object System.Text.StringBuilder 256
        [void][WinFg]::GetWindowText($hWnd, $sb, 256)
        $title = $sb.ToString()
        foreach ($t in $script:targetTitles) {
            if ($title -like "*$t*") {
                $script:found = $hWnd
                return $false  # stop enumerating
            }
        }
        return $true
    }
    [void][WinFg]::EnumWindows($cb, [IntPtr]::Zero)

    if ($found -ne [IntPtr]::Zero) {
        Write-Host "Bringing launcher window to foreground."
        [void][WinFg]::ShowWindow($found, [WinFg]::SW_RESTORE)
        # SetForegroundWindow is denied unless the calling process just received
        # input. Simulating an Alt key press is a documented trick that unlocks
        # the restriction for this call.
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.SendKeys]::SendWait("%")
        [void][WinFg]::SetForegroundWindow($found)
        Start-Sleep -Milliseconds 400
    } else {
        Write-Warning "Didn't find a Larian launcher window; macro may click behind."
    }

    & (Join-Path $PSScriptRoot "macro-play.ps1") -Name $ClicksMacro -StartDelaySeconds 0
}
