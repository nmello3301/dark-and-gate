# Audio cue + BG3 launch, for when Claude needs the human to playtest.
# Call once per playtest request; never in a loop.
#
# Behaviour:
#   1. Play scripts\notify.mp3.
#   2. Launch BG3 via the Steam URL (just opens the Larian launcher, no clicks).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\notify.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\notify.ps1 -Message "spike ready"
#   powershell -ExecutionPolicy Bypass -File scripts\notify.ps1 -NoLaunch   # chime only

param(
    [string]$Message = "Playtest ready.",
    [switch]$NoLaunch
)

$sound = Join-Path $PSScriptRoot "notify.mp3"

if (Test-Path $sound) {
    try {
        Add-Type -AssemblyName PresentationCore -ErrorAction Stop
        $player = New-Object System.Windows.Media.MediaPlayer
        $player.Open([Uri]::new($sound))
        Start-Sleep -Milliseconds 150
        $player.Play()
        $dur = 1.5
        if ($player.NaturalDuration.HasTimeSpan) {
            $dur = $player.NaturalDuration.TimeSpan.TotalSeconds
        }
        Start-Sleep -Seconds ([Math]::Min($dur + 0.2, 5))
        $player.Stop()
        $player.Close()
    } catch {
        [System.Media.SystemSounds]::Exclamation.Play()
        Start-Sleep -Milliseconds 300
    }
} else {
    [System.Media.SystemSounds]::Exclamation.Play()
    Start-Sleep -Milliseconds 300
}

Write-Host "[notify] $Message"

if (-not $NoLaunch) {
    Write-Host "[notify] Launching BG3 via steam://rungameid/1086940"
    Start-Process "steam://rungameid/1086940"
}
