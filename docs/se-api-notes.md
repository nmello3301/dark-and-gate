# Script Extender API notes

Confirmed in-game, with the SE version each note was verified against. Add every API we touch here. See `reference/bg3se/Docs/API.md` for the full reference.

## SE v32 (built 2026-06-21)

### Lua sandbox omissions

The SE Lua state has **no `os` library**. Any call to `os.time`, `os.date`, `os.clock`, `os.getenv`, etc. raises `attempt to index a nil value (global 'os')` at the first use. Verified on 2026-10-07 by the M0 scaffold trying `os.date("%Y-%m-%d %H:%M:%S")` from `Shared/Log.lua`.

Assume the same for `io` (standard file handles) and `debug.getregistry`-style introspection. Use SE equivalents instead.

### Time

- `Ext.Timer.MonotonicTime(): int64` — milliseconds since engine start, monotonic. Not wall-clock, not synced between peers. **Confirmed working** from both server and client bootstrap on 2026-10-07.
- `Ext.Timer.GameTime(): number` — in-game time; still pending verification.
- Wall-clock timestamps: no first-class SE API found yet; if we need them, serialize `Ext.Timer.MonotonicTime()` deltas against a per-session timestamp sampled some other way, or ship a tiny native helper later.

### File I/O (`Ext.IO`)

- `Ext.IO.SaveFile(path, content): boolean` — writes to `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\<path>`. Creates missing parent directories. **Confirmed working** on 2026-10-07 writing `DarkAndGate/session.log`.
- `Ext.IO.LoadFile(path, [context]): string?` — unverified.

### Logging

- `Ext.Utils.Print(...)` goes to the SE debug console (when `CreateConsole: true` in `ScriptExtenderSettings.json`) and to the SE runtime log (when `EnableLogging: true` and `LogRuntime: true`). Default SE settings in release builds have `CreateConsole: false`; we rely on an explicit settings file.
- SE runtime log location (verified 2026-10-07): `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender Logs\Extender Runtime <timestamp>.log` — note the trailing *` Logs`* on the folder, which is a sibling of the SE data folder, not inside it.
