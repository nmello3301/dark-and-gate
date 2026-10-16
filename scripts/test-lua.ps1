# Offline Lua checks (no game needed): every mod Lua file compiles under
# Lua 5.4, and the pure-logic self-tests pass (Meta-Points curves against the
# signed-off table, config merge, melee cooldown / swing rate).
# tools/luatest/run.py; needs Python 3 and lupa (pip install lupa).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-lua.ps1

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
& python -I (Join-Path $root "tools\luatest\run.py")
exit $LASTEXITCODE
